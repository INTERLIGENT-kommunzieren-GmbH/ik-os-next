#!/bin/bash
# SDD §20-§23, §52 — driverless-first printing.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Configuring CUPS"

install -Dm0644 "${CTX}/config/cups/cupsd.conf"        /usr/lib/ik-os/cups/cupsd.conf
install -Dm0644 "${CTX}/config/cups/cups-browsed.conf" /usr/lib/ik-os/cups/cups-browsed.conf

cat > /usr/lib/tmpfiles.d/ik-os-cups.conf <<'EOF'
d /etc/cups 0755 root lp -
C /etc/cups/cupsd.conf        0640 root lp - /usr/lib/ik-os/cups/cupsd.conf
C /etc/cups/cups-browsed.conf 0644 root lp - /usr/lib/ik-os/cups/cups-browsed.conf
EOF

# SDD §21 — discovery over DNS-SD/mDNS, and .local resolution for IPP.
sed -i 's/^hosts:.*/hosts:          files mdns4_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] dns myhostname/' \
    /etc/nsswitch.conf

systemctl enable cups.service cups-browsed.service avahi-daemon.service ipp-usb.service 2>/dev/null || true
# CUPS socket activation keeps the daemon off until something prints.
systemctl enable cups.socket 2>/dev/null || true

# SDD §23 — adding a driverless printer must not require root. The polkit rule
# grants printer administration to the local desktop session.
install -Dm0644 "${CTX}/config/cups/49-ik-os-printers.rules" \
    /usr/share/polkit-1/rules.d/49-ik-os-printers.rules

info "printing configured: driverless IPP, DNS-SD discovery, IPP-over-USB"
