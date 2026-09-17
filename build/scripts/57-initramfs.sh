#!/bin/bash
# Build the bootc-aware initramfs (SDD §4).
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

KVER=$(installed_kver)
log "Generating initramfs for ${KVER}"

mkdir -p /usr/lib/dracut/dracut.conf.d
# dracut on Debian defaults to /etc paths that the bootc dracut module does not
# expect; pin them explicitly or the module is silently dropped.
cat > /usr/lib/dracut/dracut.conf.d/30-ik-os-systemd-paths.conf <<'EOF'
systemdsystemconfdir=/etc/systemd/system
systemdsystemunitdir=/usr/lib/systemd/system
EOF
install -Dm0644 "${CTX}/config/boot/dracut-ik-os.conf" /usr/lib/dracut/dracut.conf.d/50-ik-os.conf

dracut --force --no-hostonly --kver "${KVER}" --reproducible --zstd -v \
       "/usr/lib/modules/${KVER}/initramfs.img"
chmod 0600 "/usr/lib/modules/${KVER}/initramfs.img"

[[ -s "/usr/lib/modules/${KVER}/initramfs.img" ]] || die "initramfs generation produced no output"

# The bootc dracut module must actually be present, otherwise the system boots
# into a plain Debian root and silently loses the immutable model (Rule 18).
# The watermark is installed by 55-branding.sh, which must run first. If the
# ordering is ever swapped back, the splash silently reverts to stock Debian.
output_matches 'watermark' lsinitrd "/usr/lib/modules/${KVER}/initramfs.img" \
    || die "the Plymouth watermark is not in the initramfs.
       55-branding.sh must run before this script (see the Containerfile)."

if ! output_matches 'bootc\|ostree' lsinitrd "/usr/lib/modules/${KVER}/initramfs.img"; then
    die "the generated initramfs contains neither the bootc nor the ostree dracut module"
fi

# Every install is encrypted (ADR 0022), so an initramfs that cannot open a
# LUKS container does not boot at all -- it stops at an emergency shell with
# the root filesystem it was asked for nowhere to be found. dracut drops the
# crypt module quietly when cryptsetup is missing from the image, and the
# module list in dracut-ik-os.conf asking for it is not evidence that it
# landed, so check for the binary itself.
#
# Verified to be a real check rather than a tautology: the initramfs built
# before the crypt modules were added contains no cryptsetup at all.
if ! output_matches 'cryptsetup' lsinitrd "/usr/lib/modules/${KVER}/initramfs.img"; then
    die "the generated initramfs cannot unlock LUKS: no cryptsetup inside it.
       Every ik-os install is encrypted (ADR 0022), so this image would
       install and then fail to boot. Check that the crypt and
       systemd-cryptsetup modules are in config/boot/dracut-ik-os.conf and
       that cryptsetup is in packages/base/packages.list."
fi
