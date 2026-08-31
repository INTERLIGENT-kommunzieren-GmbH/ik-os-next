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

# Both the intent and the outcome are recorded, not just the outcome. The image
# is the only artefact that reaches verify-image.sh and the running machine, so
# without the intent nothing downstream can tell "unsigned developer build" from
# "signing was required and something went wrong".
record_state() {
    cat > /usr/share/ik-os/build-secureboot.env <<EOF
# Written by build/scripts/40-boot.sh. SECURE_BOOT_SIGNING is what the build was
# asked for, SECURE_BOOT_SIGNED is what it achieved. required+no must not exist.
SECURE_BOOT_SIGNING=${SECURE_BOOT_SIGNING}
SECURE_BOOT_SIGNED=$1
EOF
}

case "${SECURE_BOOT_SIGNING}" in
    required|optional) ;;
    *) die "SECURE_BOOT_SIGNING=${SECURE_BOOT_SIGNING:-<unset>} is not a valid
       policy; config/boot/secure-boot.env must say required or optional." ;;
esac

if [[ -r "${SECURE_BOOT_KEY:-}" && -r "${SECURE_BOOT_CERT:-}" ]]; then
    info "signing systemd-boot with the company Machine Owner Key"
    sbsign --key "$SECURE_BOOT_KEY" --cert "$SECURE_BOOT_CERT" \
           --output "${BOOTEFI}.signed" "$BOOTEFI"
    mv "${BOOTEFI}.signed" "$BOOTEFI"
    sbverify --cert "$SECURE_BOOT_CERT" "$BOOTEFI" \
        || die "signature verification of systemd-boot failed"

    # The cert is the public half, so it belongs in the image: a machine cannot
    # enrol a key it was never given, and asking an operator to fetch it out of
    # band is how fleets end up with Secure Boot disabled instead. SDD §50.
    install -Dm0644 "$SECURE_BOOT_CERT" /usr/share/ik-os/ik-os-mok.crt
    # mokutil --import takes DER, not PEM, and says nothing useful when handed
    # the wrong one. Ship both so the enrolment step cannot pick wrong.
    openssl x509 -in "$SECURE_BOOT_CERT" -outform DER \
        -out /usr/share/ik-os/ik-os-mok.der \
        || die "could not convert the MOK certificate to DER"
    chmod 0644 /usr/share/ik-os/ik-os-mok.der

    record_state yes
elif [[ "${SECURE_BOOT_SIGNING}" == "required" ]]; then
    die "SECURE_BOOT_SIGNING=required but no usable key/cert was mounted at
       ${SECURE_BOOT_KEY} / ${SECURE_BOOT_CERT}.
       Rule 18: refusing to silently ship an image that cannot Secure Boot."
else
    info "no signing key provided; producing an UNSIGNED systemd-boot (developer build)"
    record_state no
fi

# bootc installs and updates the bootloader itself; make sure Debian's
# grub/initramfs hooks never fight it on the immutable host.
systemctl mask initrd-cleanup.service 2>/dev/null || true
rm -f /etc/kernel/postinst.d/zz-update-grub 2>/dev/null || true
