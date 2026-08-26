#!/bin/bash
# SDD §9 hardware validation matrix. Everything a script can see is checked;
# the rest is an explicit manual checklist, because "suspend/resume works" is
# not something a test can honestly assert on its own.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

echo "== hardware: $(ik-os hardware | awk '/Profile/{print $2}') =="
ik-os hardware | sed 's/^/  /'

echo
echo "-- automatic --"
check "Wi-Fi device present"      bash -c 'nmcli -t -f TYPE device | grep -q wifi'
check "Bluetooth controller"      bash -c 'bluetoothctl list | grep -q Controller'
check "audio devices"             bash -c 'wpctl status | grep -q Sinks'
check "webcam"                    bash -c 'ls /dev/video* >/dev/null'
check "battery reported"          bash -c 'ls /sys/class/power_supply/BAT* >/dev/null'
check "charging state readable"   bash -c 'cat /sys/class/power_supply/BAT*/status >/dev/null'
check "touchpad"                  bash -c 'libinput list-devices 2>/dev/null | grep -qi touchpad'
check "fingerprint reader"        bash -c 'fprintd-list root 2>&1 | grep -qv "No devices"'
check "firmware updates available via fwupd" fwupdmgr get-devices
check "no firmware load failures" bash -c '! dmesg | grep -qi "firmware.*failed"'

echo
echo "-- manual (SDD §9) --"
for item in "suspend and resume (systemctl suspend, then wake)" \
            "USB-A device enumerates" \
            "USB-C device enumerates" \
            "external display over USB-C" \
            "docking station: display, network, USB" \
            "keyboard backlight and function keys" \
            "battery charges and reports correctly on AC"; do
    manual "$item"
done

summary
