#!/bin/bash
# Build a UEFI live installer ISO for ik-os.
#
# The ik-os image itself is carried on the ISO as an OCI archive; the installer
# runs `bootc install to-disk --source-imgref` against it, so installation works
# with no network connection (SDD §36).
set -euo pipefail

ISO_SRC="${ISO_SRC:-/iso}"
OUT="${OUT:-/output}"
WORK="${WORK:-/work}"
PAYLOAD="${PAYLOAD:?PAYLOAD (oci-archive of the ik-os image) must be set}"
TARGET_REF="${TARGET_REF:-ik-os:testing}"

# The live environment must be bootstrapped from the same Debian suite as the
# image. bootc is built from source against that suite's libostree and
# libcomposefs (ADR 0001), so a live system from a different suite cannot run
# the binary at all -- it dies with "libostree-1.so.1: cannot open shared
# object file" before it reaches the first partition.
if [[ -r "${ISO_SRC}/image.env" ]]; then
    # shellcheck disable=SC1091
    . "${ISO_SRC}/image.env"
fi
SUITE="${SUITE:-${DEBIAN_SUITE:-stable}}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

rm -rf "$WORK"; mkdir -p "$WORK/rootfs" "$WORK/iso/live" "$WORK/iso/ik-os"

log "Bootstrapping the live environment (Debian ${SUITE})"
mapfile -t LIVE_PKGS < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' \
    "${ISO_SRC}/config/live-packages.list" | grep -v '^$' | grep -v bootc-placeholder)

mmdebstrap \
    --variant=important \
    --include="$(IFS=,; echo "${LIVE_PKGS[*]}")" \
    --components="main contrib non-free-firmware" \
    "$SUITE" "$WORK/rootfs" \
    "deb http://deb.debian.org/debian ${SUITE} main contrib non-free-firmware"

log "Adding bootc to the live environment"
# The live system needs the same bootc as the payload; take it straight out of
# the ik-os image rather than rebuilding or trusting a third-party repository.
mkdir -p "$WORK/payload-extract"
skopeo copy "oci-archive:${PAYLOAD}" "dir:${WORK}/payload-dir"
python3 - "$WORK/payload-dir" "$WORK/payload-extract" <<'PY'
import json, os, sys, tarfile
src, dest = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(src, "manifest.json")))
# Only bootc: Debian does not package it. Its ~55-library dependency closure
# (libostree, libcomposefs, glib, gpgme, curl, krb5, ...) is NOT copied here --
# live-packages.list installs ostree and composefs from the same suite instead,
# which is the only way the versions can be guaranteed to match.
# bootc reads ostree/prepare-root.conf from the filesystem it is *running on*,
# not from the source image, so the live system needs the image's copy or
# `bootc install` aborts with "Failed to find ostree/prepare-root.conf".
wanted = {"/usr/bin/bootc", "usr/bin/bootc",
          "/usr/lib/ostree/prepare-root.conf", "usr/lib/ostree/prepare-root.conf"}
for layer in manifest["layers"]:
    digest = layer["digest"].split(":")[1]
    path = os.path.join(src, digest)
    if not os.path.exists(path):
        continue
    try:
        with tarfile.open(path) as t:
            for m in t.getmembers():
                if m.name.lstrip("./") in {w.lstrip("/") for w in wanted}:
                    t.extract(m, dest)
                    print("extracted", m.name)
    except tarfile.ReadError:
        continue
PY
if [[ ! -x "${WORK}/payload-extract/usr/bin/bootc" ]]; then
    echo "FATAL: could not extract bootc from the payload image." >&2
    echo "The installer cannot run without it; refusing to build an ISO that" >&2
    echo "would fail at install time." >&2
    exit 1
fi
# Checked here, not at install time: a silently missing prepare-root.conf only
# surfaces after the user has typed ERASE and bootc has started partitioning.
if [[ ! -r "${WORK}/payload-extract/usr/lib/ostree/prepare-root.conf" ]]; then
    echo "FATAL: prepare-root.conf was not found in the payload image." >&2
    echo "bootc install would abort part-way through. Check that" >&2
    echo "build/scripts/10-ostree-layout.sh still writes it." >&2
    exit 1
fi
cp -a "${WORK}/payload-extract/usr/." "${WORK}/rootfs/usr/"

log "Installing the installer"
# The installer must use exactly the backend and bootloader that
# config/image.env declares, or an ISO install and a `just build-qcow2` install
# would produce differently-booting systems.
if [[ -r "${ISO_SRC}/image.env" ]]; then
    install -Dm0644 "${ISO_SRC}/image.env" "${WORK}/rootfs/usr/lib/ik-os/image.env"
else
    echo "FATAL: ${ISO_SRC}/image.env not staged; refusing to guess install flags." >&2
    exit 1
fi
install -Dm0755 "${ISO_SRC}/installer/ik-os-installer" \
    "${WORK}/rootfs/usr/bin/ik-os-installer"
install -Dm0644 "${ISO_SRC}/installer/ik-os-installer.service" \
    "${WORK}/rootfs/usr/lib/systemd/system/ik-os-installer.service"
ln -sf ../ik-os-installer.service \
    "${WORK}/rootfs/usr/lib/systemd/system/multi-user.target.wants/ik-os-installer.service"
echo "ik-os-live" > "${WORK}/rootfs/etc/hostname"

# The installer owns tty1, exclusively. It must, and this is not a preference:
# getty@tty1.service is enabled by Debian's preset, it sets Restart=always with
# RestartSec=0, and its unit carries TTYReset and TTYVTDisallocate. So agetty
# and the installer both open /dev/tty1, and the consequences are the two bugs
# this masking fixes:
#
#   * Keystrokes are split between agetty and whiptail, so the installer
#     responds to roughly half of what is typed -- or to none of it, once
#     agetty wins and the console shows a login prompt over the running
#     installer. Reproduced in a VM: `systemctl restart getty@tty1` replaces
#     the disk-selection dialog with "ik-os-live login:" while the installer is
#     still sitting there waiting for an answer.
#   * Two processes writing one TTY interleave mid-escape-sequence. whiptail
#     draws with CSI sequences (the terminfo `linux` acsc is an identity map
#     drawn under Shift Out), so a sequence cut in half by agetty's output
#     leaves its tail on screen as literal text -- which is where stray
#     characters in the window borders come from.
#
# Masking is the fix rather than Conflicts= in the installer unit: with
# Restart=always, a conflicted getty is restarted and stopped in a loop.
# Masking getty@tty1 also covers autovt@tty1, which is an alias for it.
ln -sf /dev/null "${WORK}/rootfs/etc/systemd/system/getty@tty1.service"
rm -f "${WORK}/rootfs/etc/systemd/system/getty.target.wants/getty@tty1.service"
[[ -L "${WORK}/rootfs/etc/systemd/system/getty@tty1.service" ]] \
    || { echo "FATAL: could not mask getty@tty1 in the live system." >&2; exit 1; }

# Live session is passwordless root; it never reaches an installed system, and
# the ISO carries no company secrets. tty1 belongs to the installer (masked
# above), so the shell is on tty2 and up -- Alt+F2 from the installer -- which
# logind spawns on demand through autovt@.
sed -i 's|^root:[^:]*:|root::|' "${WORK}/rootfs/etc/shadow"

log "Staging the ik-os payload on the medium"
# An OCI *layout directory*, not an oci-archive tarball. bootc reads a layout
# in place; the archive transport first untars ~1.4 GB into /var/tmp, which on
# a live system is a RAM-backed tmpfs -- so the install died with "no space
# left on device" on any machine under roughly 8 GB of RAM.
skopeo copy "oci-archive:${PAYLOAD}" "oci:${WORK}/iso/ik-os/payload:ik-os"
printf '%s\n' "$TARGET_REF" > "${WORK}/iso/ik-os/target-ref"

log "Extracting the live kernel"
KVER=$(basename "$(find "${WORK}/rootfs/usr/lib/modules" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1)")
cp "${WORK}/rootfs/boot/vmlinuz-${KVER}" "${WORK}/iso/live/vmlinuz"
cp "${WORK}/rootfs/boot/initrd.img-${KVER}" "${WORK}/iso/live/initrd.img"

log "Building the squashfs"
mksquashfs "${WORK}/rootfs" "${WORK}/iso/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 15 -b 1M -noappend -e boot

log "Building the EFI boot image"
mkdir -p "${WORK}/efi/EFI/BOOT"
cp "${ISO_SRC}/config/grub.cfg" "${WORK}/grub-embedded.cfg"
grub-mkstandalone \
    --format=x86_64-efi \
    --output="${WORK}/efi/EFI/BOOT/BOOTX64.EFI" \
    --modules="part_gpt part_msdos fat iso9660 all_video normal linux echo configfile search search_label search_fs_uuid search_fs_file" \
    "boot/grub/grub.cfg=${WORK}/grub-embedded.cfg"

ESP="${WORK}/esp.img"
# Size the ESP to its contents plus slack rather than hardcoding a number.
ESP_KB=$(( $(du -sk "${WORK}/efi" | cut -f1) + 2048 ))
mkfs.vfat -C "$ESP" "$ESP_KB" >/dev/null
mcopy -s -i "$ESP" "${WORK}/efi/EFI" ::
mkdir -p "${WORK}/iso/EFI/BOOT"
cp "${WORK}/efi/EFI/BOOT/BOOTX64.EFI" "${WORK}/iso/EFI/BOOT/BOOTX64.EFI"
cp "$ESP" "${WORK}/iso/efi.img"

log "Assembling the ISO"
mkdir -p "$OUT"
VERSION=$(date -u +%Y%m%d)
ISO_PATH="${OUT}/ik-os-installer-${VERSION}.iso"
# The volume id uses d-characters only (A-Z 0-9 _); hyphens make xorriso warn
# that it does not comply with ISO 9660 / ECMA 119. Nothing looks the medium up
# by label -- grub.cfg searches by file -- so it is free to be compliant.
xorriso -as mkisofs \
    -iso-level 3 \
    -volid "IK_OS_INSTALL" \
    -output "$ISO_PATH" \
    -eltorito-alt-boot \
    -e efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -append_partition 2 0xef "$ESP" \
    "${WORK}/iso"

# Record the bare filename, not the in-container /output path, so
# `sha256sum -c` works next to the ISO on the host.
( cd "$OUT" && sha256sum "$(basename "$ISO_PATH")" > "$(basename "$ISO_PATH").sha256" )
log "ISO: ${ISO_PATH} ($(du -h "$ISO_PATH" | cut -f1))"
