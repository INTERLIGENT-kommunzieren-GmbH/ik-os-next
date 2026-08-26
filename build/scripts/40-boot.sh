#!/bin/bash
# SDD §5 — UEFI + Secure Boot + systemd-boot.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env
# shellcheck disable=SC1091
set -a; . "${CTX}/config/boot/secure-boot.env"; set +a

log "Configuring the boot stack"

install -Dm0644 "${CTX}/config/boot/loader.conf" /usr/lib/ik-os/boot/loader.conf

BOOTEFI=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
[[ -f "$BOOTEFI" ]] || die "systemd-boot EFI binary not found at ${BOOTEFI}"

if [[ -r "${SECURE_BOOT_KEY:-}" && -r "${SECURE_BOOT_CERT:-}" ]]; then
    info "signing systemd-boot with the company Machine Owner Key"
    sbsign --key "$SECURE_BOOT_KEY" --cert "$SECURE_BOOT_CERT" \
           --output "${BOOTEFI}.signed" "$BOOTEFI"
    mv "${BOOTEFI}.signed" "$BOOTEFI"
    sbverify --cert "$SECURE_BOOT_CERT" "$BOOTEFI" \
        || die "signature verification of systemd-boot failed"
    echo "SECURE_BOOT_SIGNED=yes" > /usr/share/ik-os/build-secureboot.env
elif [[ "${SECURE_BOOT_SIGNING}" == "required" ]]; then
    die "SECURE_BOOT_SIGNING=required but no usable key/cert was mounted at
       ${SECURE_BOOT_KEY} / ${SECURE_BOOT_CERT}.
       Rule 18: refusing to silently ship an image that cannot Secure Boot."
else
    info "no signing key provided; producing an UNSIGNED systemd-boot (developer build)"
    echo "SECURE_BOOT_SIGNED=no" > /usr/share/ik-os/build-secureboot.env
fi

# bootc installs and updates the bootloader itself; make sure Debian's
# grub/initramfs hooks never fight it on the immutable host.
systemctl mask initrd-cleanup.service 2>/dev/null || true
rm -f /etc/kernel/postinst.d/zz-update-grub 2>/dev/null || true
