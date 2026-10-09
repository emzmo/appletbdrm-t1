#!/bin/sh
# Switch the Apple T1 iBridge (05ac:8600) from USB config 1 (keyboard)
# to config 2 (DRM display + multitouch).  Without this the Touch Bar
# stays dark — appletbdrm only finds the display interface in config 2.
#
# The device path (e.g. 1-3) is not hardcoded; we resolve it by
# VID:PID so this survives USB bus renumbering.

set -e

BRIDGE=""
for dev in /sys/bus/usb/devices/*/idVendor; do
    if [ "$(cat "$dev" 2>/dev/null)" = "05ac" ] && \
       [ "$(cat "$(dirname "$dev")/idProduct" 2>/dev/null)" = "8600" ]; then
        BRIDGE="$(dirname "$dev")"
        break
    fi
done

if [ -z "$BRIDGE" ]; then
    echo "ibridge-config: device 05ac:8600 not found"
    exit 1
fi

current="$(cat "$BRIDGE/bConfigurationValue" 2>/dev/null)"
if [ "$current" = "2" ]; then
    echo "ibridge-config: already in config 2, skipping"
    exit 0
fi

echo "ibridge-config: switching $BRIDGE from config $current to 2"
echo 2 > "$BRIDGE/bConfigurationValue"

# Wait for the DRM card to appear (appletbdrm probes after re-enumeration)
for i in 1 2 3 4 5 6 7 8 9 10; do
    if ls /sys/class/drm/card*/device/driver 2>/dev/null | grep -q appletbdrm; then
        echo "ibridge-config: appletbdrm DRM card appeared"
        exit 0
    fi
    sleep 1
done

echo "ibridge-config: DRM card did not appear within 10s"
exit 1