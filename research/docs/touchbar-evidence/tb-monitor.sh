#!/bin/bash
# tb-monitor.sh — DTrace-based Touch Bar USB transfer monitor
# Captures DFRDisplay draw_request/draw_completion events from TouchBarServer (PID 313)
# for refresh-rate (9.1.2) and batching (9.2.5) analysis.
#
# Usage:  sudo ./tb-monitor.sh <scenario-name> [duration-seconds]
#   e.g.  sudo ./tb-monitor.sh app-switching 30
#         sudo ./tb-monitor.sh idle-baseline 10
#   If duration is omitted, runs for 30 seconds (or until Ctrl-C).
#
# Output: ~/touchbar-evidence/track-<scenario>-<timestamp>.txt
#         (self-contained track record with system context, capture log, summary, and your note)

set -u

EVIDENCE_DIR="$HOME/touchbar-evidence"
mkdir -p "$EVIDENCE_DIR"

# ----- Phase A: Pre-flight checks -----
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: run with sudo (need DTrace privileges)"
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: sudo $0 <scenario-name> [duration-seconds]"
    echo "  e.g. sudo $0 app-switching 30"
    echo "       sudo $0 idle-baseline 10"
    exit 1
fi

SCENARIO="$1"
DURATION="${2:-30}"
SCRATCH=$(mktemp -d /tmp/tb-monitor.XXXXXX)
CAPTURE_LOG="$SCRATCH/capture.log"
DTRACE_ERR="$SCRATCH/dtrace.err"
PROBE_LIST="$SCRATCH/probes.txt"

# Find TouchBarServer PID (may not be 313 after reboot)
TBSPID=$(pgrep -x TouchBarServer | head -1)
if [ -z "$TBSPID" ]; then
    echo "WARNING: TouchBarServer not running — capture will be empty."
    echo "Proceeding anyway (a probe-discovery check will follow)."
else
    echo "TouchBarServer PID: $TBSPID"
fi

# Verify DTrace available
DTRACE_BIN=$(command -v dtrace || echo "/usr/sbin/dtrace")
if [ ! -x "$DTRACE_BIN" ]; then
    echo "ERROR: dtrace binary not found"
    exit 1
fi

# ----- Phase B: Collect system context -----
echo "Collecting system context..."
CTX_MACOS=$(sw_vers 2>/dev/null | tr '\n' '|')
CTX_HW=$(system_profiler SPHardwareDataType 2>/dev/null | grep -E "Model|Processor|Memory|Firmware|SMC" | tr '\n' '|')
CTX_SIP=$(csrutil status 2>&1 | head -1)
CTX_BOOTARGS=$(nvram boot-args 2>&1 | head -1)
CTX_KEXTS=$(kextstat 2>/dev/null | grep -iE "IOUSBHostFamily|AppleUSBXHCI|AppleUSBiBridge|AppleMultitouchDriver|AppleSEPManager|AppleEmbeddedOSSupportHost" | tr '\n' '|')
CTX_TBSPROC=$(ps -axo pid,comm,command | grep -iE "TouchBarServer|ControlStrip" | grep -v grep | tr '\n' '|')
CTX_T1=$(ioreg -p IOUSB -l 2>/dev/null | awk '/Apple T1 Controller/,/^$/' | tr '\n' '|')
CTX_DTRACE_VER=$(sudo -n "$DTRACE_BIN" -V 2>&1 | head -1)
START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_S=$(date +%s)

# ----- Phase C: Probe discovery -----
echo "Discovering DTrace probes..."
sudo -n "$DTRACE_BIN" -l > "$PROBE_LIST" 2>&1

# dtrace -l output is space-aligned columns: ID PROVIDER MODULE FUNCTION NAME
# The TouchBarServer registers a custom provider named "DFRDisplay<PID>"
# (e.g. DFRDisplay313) with probes draw_request / draw_completion.
# We search for both the custom provider AND the pid<PID> provider (fallback).
DRAW_REQ_PROBE=""
DRAW_COMP_PROBE=""
if [ -n "$TBSPID" ]; then
    # Custom provider: DFRDisplay<PID>:DFRDisplay:_DFRDisplayDrawRectsRequest:draw_request
    if grep -qE "DFRDisplay${TBSPID}[[:space:]]+DFRDisplay[[:space:]]+_DFRDisplayDrawRectsRequest[[:space:]]+draw_request" "$PROBE_LIST"; then
        DRAW_REQ_PROBE="DFRDisplay${TBSPID}:DFRDisplay:_DFRDisplayDrawRectsRequest:draw_request"
    elif grep -qE "pid${TBSPID}[[:space:]]+DFRDisplay[[:space:]]+_DFRDisplayDrawRectsRequest[[:space:]]+entry" "$PROBE_LIST"; then
        DRAW_REQ_PROBE="pid${TBSPID}:DFRDisplay:_DFRDisplayDrawRectsRequest:entry"
    fi
    if grep -qE "DFRDisplay${TBSPID}[[:space:]]+DFRDisplay[[:space:]]+_DFRDisplayUsbRecvComplete[[:space:]]+draw_completion" "$PROBE_LIST"; then
        DRAW_COMP_PROBE="DFRDisplay${TBSPID}:DFRDisplay:_DFRDisplayUsbRecvComplete:draw_completion"
    elif grep -qE "pid${TBSPID}[[:space:]]+DFRDisplay[[:space:]]+_DFRDisplayUsbRecvComplete[[:space:]]+entry" "$PROBE_LIST"; then
        DRAW_COMP_PROBE="pid${TBSPID}:DFRDisplay:_DFRDisplayUsbRecvComplete:entry"
    fi
fi

if [ -z "$DRAW_REQ_PROBE" ] && [ -z "$DRAW_COMP_PROBE" ]; then
    echo "ERROR: DFRDisplay probes not found for TouchBarServer (PID ${TBSPID:-none})"
    echo "Probe list excerpt (DFRDisplay lines):"
    grep "DFRDisplay" "$PROBE_LIST" | head -20 || echo "(no DFRDisplay probes found)"
    echo ""
    echo "Full probe list saved at: $PROBE_LIST"
    echo "Send the grep output above to the agent for adjustment."
    rm -rf "$SCRATCH"
    exit 2
fi

echo "Discovered probes:"
[ -n "$DRAW_REQ_PROBE" ]   && echo "  $DRAW_REQ_PROBE   (framebuffer OUT to T1 — refresh-rate signal)"
[ -n "$DRAW_COMP_PROBE" ]  && echo "  $DRAW_COMP_PROBE  (T1 ACK IN — completion signal)"

# ----- Phase D: Build DTrace script and start live capture -----
DTRACE_SCRIPT="$SCRATCH/tb.d"
# The DTrace script captures draw_req/draw_comp events and prints them live.
# A timer probe (profile:::tick-1s) prints a heartbeat so you know it's running.
# A second timer (profile:::tick-<DURATION>s) calls exit(0) to stop cleanly.
cat > "$DTRACE_SCRIPT" <<DTRACE_EOF
#pragma D option quiet
#pragma D option bufsize=16m
#pragma D option flowindent=off

self int hb;
int hb;

$( [ -n "$DRAW_REQ_PROBE" ]  && echo "$DRAW_REQ_PROBE  { printf(\"%u draw_req\n\", timestamp); }" )
$( [ -n "$DRAW_COMP_PROBE" ] && echo "$DRAW_COMP_PROBE { printf(\"%u draw_comp\n\", timestamp); }" )

profile:::tick-1s
{
    printf("# heartbeat %d\n", ++hb);
}

profile:::tick-${DURATION}s
{
    printf("# capture complete after ${DURATION}s\n");
    exit(0);
}
DTRACE_EOF

echo ""
echo "=== Monitoring started (scenario: $SCENARIO, duration: ${DURATION}s) ==="
echo "Exercise the Touch Bar now. The script will stop automatically after ${DURATION}s."
echo "(You can also press Ctrl-C to stop early.)"
echo "Live transfer events (timestamp_ns event_type, # = heartbeat):"
echo ""

# Run DTrace in the foreground. It exits after DURATION seconds via tick probe.
# Ctrl-C also works (DTrace handles SIGINT by flushing and exiting).
# stdout goes to the terminal (live) AND we tee to the capture log.
sudo -n "$DTRACE_BIN" -s "$DTRACE_SCRIPT" 2> "$DTRACE_ERR" | tee "$CAPTURE_LOG"
DTRACE_EXIT=${PIPESTATUS[0]}

echo ""
echo "DTrace exited (status: $DTRACE_EXIT)."
if [ -s "$DTRACE_ERR" ]; then
    echo "DTrace stderr:"
    cat "$DTRACE_ERR"
fi

# ----- Phase E: End-note prompt -----
STOP_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STOP_S=$(date +%s)
DURATION_ACTUAL=$(( STOP_S - START_S ))

echo ""
echo "=== Capture stopped ==="
echo "Scenario:   $SCENARIO"
echo "Duration:   ${DURATION_ACTUAL}s (actual)"
echo "Events:     $(wc -l < "$CAPTURE_LOG" 2>/dev/null || echo 0)"
echo ""
echo "Enter a note describing what you did during this capture."
echo "Multi-line allowed. Type EOF on a blank line to finish:"
echo ""

NOTE=""
while IFS= read -r line; do
    [ "$line" = "EOF" ] && break
    NOTE="${NOTE}${line}
"
done

# ----- Phase F: Compute summary and write track record -----
EVENTS=$(wc -l < "$CAPTURE_LOG" 2>/dev/null || echo 0)
DRAW_REQ_COUNT=$(grep -c "draw_req" "$CAPTURE_LOG" 2>/dev/null || echo 0)
DRAW_COMP_COUNT=$(grep -c "draw_comp" "$CAPTURE_LOG" 2>/dev/null || echo 0)

# Compute inter-draw_req intervals (the 9.1.2 refresh-rate signal)
# Output: min/max/mean/median in milliseconds
INTERVALS_FILE="$SCRATCH/intervals.txt"
awk '/draw_req/ { if (prev) print ($1 - prev)/1000000.0; prev = $1 }' "$CAPTURE_LOG" > "$INTERVALS_FILE" 2>/dev/null
INTERVAL_STATS=$(awk '
    { v[NR] = $1; sum += $1 }
    END {
        if (NR == 0) { print "N/A (no draw_req events)"; exit }
        # min, max, mean
        min = v[1]; max = v[1]
        for (i=1; i<=NR; i++) { if (v[i] < min) min = v[i]; if (v[i] > max) max = v[i] }
        mean = sum / NR
        # median
        for (i=1; i<=NR-1; i++) for (j=i+1; j<=NR; j++) if (v[j] < v[i]) { t=v[i]; v[i]=v[j]; v[j]=t }
        if (NR % 2) med = v[(NR+1)/2]; else med = (v[NR/2] + v[NR/2+1]) / 2
        printf "min=%.3f max=%.3f mean=%.3f median=%.3f (ms), n=%d", min, max, mean, med, NR
    }
' "$INTERVALS_FILE" 2>/dev/null)

# Compute batching: draw_comp count per draw_req (9.2.5 batching signal)
BATCH_STATS=$(awk '
    BEGIN { req = 0; comp_per_req = 0; burst = 0; max_burst = 0; sum_burst = 0 }
    /draw_req/ {
        if (burst > 0) { sum_burst += burst; if (burst > max_burst) max_burst = burst; n++ }
        burst = 0; req++
    }
    /draw_comp/ { burst++ }
    END {
        if (burst > 0) { sum_burst += burst; if (burst > max_burst) max_burst = burst; n++ }
        if (req == 0) { print "N/A (no draw_req events)"; exit }
        printf "draw_req=%d draw_comp=%d  avg_comp_per_req=%.2f  max_comp_burst=%d", req, comp_per_req + 0, (n ? sum_burst/n : 0), max_burst
    }
' "$CAPTURE_LOG" 2>/dev/null)

# Write the track record
TRACK_FILE="$EVIDENCE_DIR/track-${SCENARIO}-$(date +%Y%m%d-%H%M%S).txt"
cat > "$TRACK_FILE" <<TRACK_EOF
=================== TRACK RECORD ===================
Scenario:        $SCENARIO
Start (UTC):     $START_TS
Stop (UTC):      $STOP_TS
Duration:        ${DURATION_ACTUAL}s (actual, requested ${DURATION}s)
Events captured: $EVENTS
User note:
$NOTE

------------------- SYSTEM CONTEXT -------------------
macOS:           $CTX_MACOS
Hardware:        $CTX_HW
SIP:             $CTX_SIP
boot-args:       $CTX_BOOTARGS
DTrace:          $CTX_DTRACE_VER
Kexts (USB/T1):  $CTX_KEXTS
Processes:       $CTX_TBSPROC
T1 device:       $CTX_T1

------------------- DTRACE PROBES -------------------
$( [ -n "$DRAW_REQ_PROBE" ]  && echo "  $DRAW_REQ_PROBE   (framebuffer OUT to T1)" )
$( [ -n "$DRAW_COMP_PROBE" ] && echo "  $DRAW_COMP_PROBE  (T1 completion ACK)" )
DTrace stderr (if any):
$(cat "$DTRACE_ERR" 2>/dev/null)

------------------- CAPTURE SUMMARY -------------------
Total events:          $EVENTS
draw_req events:       $DRAW_REQ_COUNT   (framebuffer update requests — OUT to T1 display)
draw_comp events:      $DRAW_COMP_COUNT  (completion callbacks — IN from T1)

9.1.2 refresh-rate signal (inter-draw_req intervals):
  $INTERVAL_STATS

9.2.5 batching signal (draw_comp per draw_req burst):
  $BATCH_STATS

------------------- RAW CAPTURE LOG -------------------
Format: <timestamp_ns> <event_type>
(event_type: draw_req = framebuffer update OUT; draw_comp = T1 completion ACK IN)
TRACK_EOF

cat "$CAPTURE_LOG" >> "$TRACK_FILE"
echo "" >> "$TRACK_FILE"
echo "=================== END TRACK RECORD ===================" >> "$TRACK_FILE"

# ----- Phase G: Done -----
# Fix ownership (script runs as root, but the evidence dir belongs to the user)
REAL_USER="${SUDO_USER:-user}"
sudo chown "$REAL_USER" "$TRACK_FILE" 2>/dev/null

echo ""
echo "=== Track record written ==="
echo "  $TRACK_FILE"
echo ""
echo "Summary:"
echo "  Events:       $EVENTS ($DRAW_REQ_COUNT draw_req / $DRAW_COMP_COUNT draw_comp)"
echo "  Refresh rate: $INTERVAL_STATS"
echo "  Batching:     $BATCH_STATS"

rm -rf "$SCRATCH"
exit 0