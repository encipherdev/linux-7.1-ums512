#!/bin/bash

echo "Starting Device Watcher..."
while true; do
    # Check ADB
    ADB_DEV=$(adb devices 2>/dev/null | grep -E "device$|recovery$|unauthorized$" || true)
    if [ -n "$ADB_DEV" ]; then
        echo "WATCHER: ADB device detected: $ADB_DEV"
        exit 0
    fi

    # Check Fastboot
    FB_DEV=$(fastboot devices 2>/dev/null || true)
    if [ -n "$FB_DEV" ]; then
        echo "WATCHER: Fastboot device detected: $FB_DEV"
        exit 0
    fi

    # Check Heimdall / Download mode
    if echo '418418' | sudo -S heimdall detect 2>/dev/null | grep -q "Device detected"; then
        echo "WATCHER: Heimdall Download Mode detected!"
        exit 0
    fi

    # Check dmesg for new USB on 6-1
    if lsusb 2>/dev/null | grep -i -E "samsung|google|unisoc|spreadtrum"; then
        echo "WATCHER: USB device found in lsusb!"
        exit 0
    fi

    sleep 3
done
