# Touch Bar Evidence — Research Index
# MacBookPro14,2 (T1) → Linux Touch Bar project
# Date: 2026-08-25

## Research Documents (start here)

| Document | What it contains |
|----------|-----------------|
| **architecture-map.md** | ASCII architecture maps for macOS and Linux, USB interface map, display protocol detail, rendering pipeline comparison. The "how it works" document. |
| **nstouchbar-widget-vocabulary.md** | Complete list of macOS Touch Bar UI capabilities: 10 NSTouchBarItem subclasses, NSScrubber, 11 standard identifiers, ~60+ template images, custom capabilities. The "what macOS can do" document. |
| **linux-stack-gap-analysis.md** | Current Linux stack (appletbdrm, apple-ib-drv, tiny-dfr), feature parity matrix, the three gaps (widgets, per-app context, dynamic images). The "what Linux has vs what's missing" document. |
| **sources-and-references.md** | All sources (Apple docs, Linux drivers, GitHub repos, local evidence files), DTrace probe discovery, research methodology. The "where did this come from" document. |
| **brainstorming-preparation.md** | Options for each gap (renderer, per-app context, image pipeline), cross-cutting decisions (language, widget model, testing), open questions. The "what to brainstorm" document. |

## Evidence Files (checklist captures)

| File | Checklist item | Status |
|------|---------------|--------|
| macos-version.txt | Setup | macOS 13.7.8 (22H730) |
| hardware.txt | Setup | MacBookPro14,2, i7, 16GB |
| esp-firmware-paths.txt | ESP | Needs manual mount (sudo) |
| 9.1.2-refresh-rate.txt | 9.1.2 [MED] | Deferred (DTrace option available) |
| 9.1.7-usb-interfaces-macos.txt | 9.1.7 [HIGH] | [CONFIRMED] interface 7 = SEP |
| 9.2.3-protocol-headers.txt | 9.2.3 [MED] | Deferred (DTrace option available) |
| 9.2.5-framebuffer-batching.txt | 9.2.5 [MED] | Deferred (DTrace option available) |
| 9.3.1-kextstat.txt | 9.3.1 [MED] | [CONFIRMED] + [REFUTED] |
| 9.3.1-kextstat-full.txt | 9.3.1 | Full kextstat dump |
| 9.3.2-iodt.txt | 9.3.2 [LOW] | [CONFIRMED] ASOC/APP7777 |
| 9.3.2-iodt-full.txt | 9.3.2 | Full IOPlatformDevice dump |
| 9.3.3-ioreg-asoc.txt | 9.3.3 [MED] | [CONFIRMED] ASOC device |
| 9.3.3-acpi-ioreg.txt | 9.3.3 | ACPI plane dump |
| 9.3.3-socw-log.txt | 9.3.3 | No SOCW events in window |
| 9.3.4-hid-descriptor.txt | 9.3.4 [MED] | Partial (ioreg report descriptors) |
| 9.4.1-daemons-summary.txt | 9.4.1 [HIGH] | [CONFIRMED] TouchBarServer + ControlStrip |
| 9.4.1-ps.txt | 9.4.1 | Process list |
| 9.4.1-launchctl.txt | 9.4.1 | launchd labels |
| 9.4.1-launchd-details.txt | 9.4.1 | Service details |
| 9.4.2-fn-timing-notes.txt | 9.4.2 [MED] | Defaults + manual obs pending |
| 9.4.2-touchbar-defaults.txt | 9.4.2 | touchbar.agent defaults |
| 9.4.2-keyboard-defaults.txt | 9.4.2 | keyboard domain (absent) |
| 9.4.2-controlstrip-defaults.txt | 9.4.2 | controlstrip defaults |
| 9.4.3-touchbar-agent-defaults.txt | 9.4.3 [MED] | 2 keys confirmed + 1 new |
| 9.4.3-all-defaults.txt | 9.4.3 | Full defaults dump |
| 9.4.3-touchbar-related-defaults.txt | 9.4.3 | Grep for touchbar/dfr |
| 9.5.1-support-url.txt | 9.5.1 [LOW] | [CONFIRMED] canonical URLs |
| 9.5.2-restart-cmd.txt | 9.5.2 [LOW] | [CONFIRMED] kickstart command |
| raw-ioreg-ioservice.txt | raw | Full ioreg IOService plane (3 MB) |
| raw-ioreg-iusb.txt | raw | Full ioreg IOUSB plane |
| tb-monitor.sh | Phase 5 | DTrace monitoring script |

## Quick answers

**Are icons in the embeddedOS or sent by the OS?**
Sent by the OS (host). The T1 is a dumb pixel sink — it receives raw BGR888
pixel rectangles via USB interface 3. All icons/text/UI are rendered on the
host (TouchBarServer on macOS, tiny-dfr on Linux). See architecture-map.md §2.

**Can Linux reproduce macOS Touch Bar features?**
Yes. The display substrate (appletbdrm) is at parity with macOS. cairo can
render sliders, color pickers, tabs, images — anything macOS can show.
The gap is in the intelligence layer (widget vocabulary + per-app context +
dynamic images), not the display. See linux-stack-gap-analysis.md.

**What can macOS Touch Bar render?**
10 widget classes + NSScrubber + arbitrary NSView: buttons, sliders, color
pickers, tabs/pickers, popovers, steppers, scrubbers, candidate lists,
sharing pickers, custom views. ~60+ system template images. See
nstouchbar-widget-vocabulary.md.