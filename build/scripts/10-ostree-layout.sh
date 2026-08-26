#!/bin/bash
# SDD §4 — make the Debian filesystem layout ostree/composefs compatible.
#
# The layout rules below follow the established Debian/Ubuntu bootc work
# (bootcrew/mono, frostyard/debian-bootc-core). See docs/adr/0001-bootc-from-source.md.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Applying the ostree filesystem layout"

# New users get their home under the persistent /var/home (SDD §26).
sed -i 's|^HOME=.*|HOME=/var/home|' /etc/default/useradd

# ostree requires a stateless machine-id: it is generated per installation.
: > /etc/machine-id

# systemd-resolved owns resolv.conf on the deployed system.
printf 'L! /etc/resolv.conf - - - - ../run/systemd/resolve/stub-resolv.conf\n' \
    > /usr/lib/tmpfiles.d/ik-os-resolv-conf.conf

log "Enabling the composefs backend"
mkdir -p /usr/lib/ostree
cat > /usr/lib/ostree/prepare-root.conf <<'EOF'
# SDD §4 — OCI image -> bootc -> OSTree/composefs -> bootable system.
[composefs]
enabled = yes

[sysroot]
readonly = true
EOF
