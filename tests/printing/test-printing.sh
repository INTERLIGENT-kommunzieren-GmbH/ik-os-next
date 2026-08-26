#!/bin/bash
# SDD §20-§23, §52 and acceptance criteria 19-20.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
echo "== printing =="

check "CUPS is reachable"          lpstat -r
check "cups-browsed is running"    systemctl is-active --quiet cups-browsed
check "avahi is running"           systemctl is-active --quiet avahi-daemon
check "ipp-usb is enabled"         systemctl is-enabled --quiet ipp-usb

echo "-- SDD §52: no LAN exposure --"
check "CUPS does not listen on a non-loopback address" \
    bash -c '! ss -tlnp 2>/dev/null | grep ":631" | grep -vE "127\.0\.0\.1|\[::1\]"'
check "queues are not shared"      bash -c '! lpstat -v 2>/dev/null | grep -q "shared"'

echo "-- SDD §21: driverless discovery --"
found=$(avahi-browse -rtp _ipp._tcp 2>/dev/null | grep -c '^=' || true)
if [[ "${found:-0}" -gt 0 ]]; then
    ok "discovered ${found} IPP printer(s) via DNS-SD"
else
    skip "IPP discovery" "no printer on this network"
fi

echo "-- SDD §22 Level 3: vendored drivers --"
# The image ships the tree in /usr/lib/opt and relies on systemd-tmpfiles to
# restore /opt/brother on boot (ADR 0008). That only ever runs on a real system,
# so this is the first place it can actually be observed.
if [[ -s /usr/share/ik-os/printer-drivers.list ]]; then
    while IFS= read -r model; do
        [[ "$model" == \#* || -z "$model" ]] && continue
        base="/opt/brother/Printers/${model}"
        check "${model}: /opt tree restored by tmpfiles" test -d "$base"
        check "${model}: CUPS filter resolves" \
            test -x "/usr/lib/cups/filter/brother_lpdwrapper_${model}"
        check "${model}: PPD offered by cupsd" \
            bash -c "lpinfo -m 2>/dev/null | grep -qi '${model}'"
        check "${model}: brprintconf runs" \
            bash -c "command -v brprintconf_${model} >/dev/null"
    done < /usr/share/ik-os/printer-drivers.list
else
    skip "vendored printer drivers" "none in this image"
fi

echo "-- SDD §23: queues are machine state --"
check "no queue shipped in the image" \
    bash -c '! test -s /usr/share/factory/etc/cups/printers.conf'

manual "GNOME Settings -> Printers -> Add: a network printer appears without installing a driver (SDD §23)"
manual "print a test page to a driverless queue (acceptance criterion 20)"
manual "connect a USB printer and confirm ipp-usb creates a queue"
manual "add the Brother MFC-L3740CDWE with its vendored PPD and print a duplex colour page"

summary
