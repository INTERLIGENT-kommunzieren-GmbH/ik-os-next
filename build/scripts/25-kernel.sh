#!/bin/bash
# SDD §9 — pinned Backports kernel, installed as a Debian package.
# Rule 3: never compiled from upstream source.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Installing kernel ${KERNEL_PACKAGE}=${KERNEL_VERSION} from ${KERNEL_SUITE}"

if ! output_matches_fixed "${KERNEL_VERSION}" apt-cache madison "${KERNEL_PACKAGE}"; then
    info "available versions:"
    apt-cache madison "${KERNEL_PACKAGE}" || true
    die "kernel ${KERNEL_PACKAGE}=${KERNEL_VERSION} is not available in ${KERNEL_SUITE}.
       SDD §9 requires an explicit validated version; the build must not fall back
       to whatever Backports currently offers. Validate a new version on the
       hardware matrix and update KERNEL_VERSION in config/image.env."
fi

apt_install "${KERNEL_PACKAGE}=${KERNEL_VERSION}"
apt-mark hold "${KERNEL_PACKAGE}"

KVER=$(installed_kver)
info "installed kernel: ${KVER}"

# ostree expects the kernel next to its modules, not in /boot.
if [[ -f "/boot/vmlinuz-${KVER}" ]]; then
    install -Dm0644 "/boot/vmlinuz-${KVER}" "/usr/lib/modules/${KVER}/vmlinuz"
fi
[[ -f "/usr/lib/modules/${KVER}/vmlinuz" ]] || die "kernel image missing for ${KVER}"

# Record the resolved kernel for the release manifest (SDD §41, §46).
mkdir -p /usr/share/ik-os
cat > /usr/share/ik-os/build-kernel.env <<EOF
KERNEL_PACKAGE="${KERNEL_PACKAGE}"
KERNEL_VERSION="${KERNEL_VERSION}"
KERNEL_SUITE="${KERNEL_SUITE}"
KERNEL_RELEASE="${KVER}"
EOF

rm -f /boot/vmlinuz-* /boot/initrd.img-* /boot/System.map-* /boot/config-*
