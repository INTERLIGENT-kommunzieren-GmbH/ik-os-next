#!/bin/bash
# dracut module for the persistent package overlay on /usr (ADR 0024).
# Requested explicitly in config/boot/dracut-ik-os.conf.
# dracut sources this file and supplies moddir, initdir and systemdsystemunitdir.
# shellcheck disable=SC2154

check() {
    return 255
}

depends() {
    echo bootc
}

installkernel() {
    instmods overlay
}

install() {
    local service=ik-os-usr-overlay.service
    inst_multiple mount mkdir cat
    inst_simple "${moddir}/ik-os-usr-overlay-initrd" /usr/libexec/ik-os/usr-overlay-initrd
    inst_simple "${moddir}/${service}" "${systemdsystemunitdir}/${service}"
    mkdir -p "${initdir}${systemdsystemunitdir}/initrd-root-fs.target.wants"
    ln_r "${systemdsystemunitdir}/${service}" \
        "${systemdsystemunitdir}/initrd-root-fs.target.wants/${service}"
}
