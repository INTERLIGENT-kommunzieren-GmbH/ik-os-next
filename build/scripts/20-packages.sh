#!/bin/bash
# SDD §56 — install the OS package inventory, group by group.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Installing base system"
# dracut must land before the kernel so that apt satisfies the kernel's
# initramfs dependency with dracut rather than initramfs-tools.
apt_install_lists "${CTX}/packages/base/packages.list"

log "Installing desktop, development, docker, hardware and printing groups"
apt_install_lists \
    "${CTX}/packages/desktop/packages.list" \
    "${CTX}/packages/desktop/extensions.list" \
    "${CTX}/packages/development/packages.list" \
    "${CTX}/packages/docker/packages.list" \
    "${CTX}/packages/hardware/packages.list" \
    "${CTX}/packages/printing/packages.list"

log "Configuring locales"
sed -i 's/^# *\(en_US.UTF-8\|de_DE.UTF-8\)/\1/' /etc/locale.gen
locale-gen
