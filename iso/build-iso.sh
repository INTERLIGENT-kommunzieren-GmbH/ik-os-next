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
wanted = {"/usr/bin/bootc", "usr/bin/bootc"}
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
if [[ -x "${WORK}/payload-extract/usr/bin/bootc" ]]; then
    cp -a "${WORK}/payload-extract/usr/." "${WORK}/rootfs/usr/"
else
    echo "FATAL: could not extract bootc from the payload image." >&2
    echo "The installer cannot run without it; refusing to build an ISO that" >&2
    echo "would fail at install time." >&2
    exit 1
fi

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
# Live session is passwordless root on tty1 only; it never reaches an installed
# system, and the ISO carries no company secrets.
sed -i 's|^root:[^:]*:|root::|' "${WORK}/rootfs/etc/shadow"

log "Staging the ik-os payload on the medium"
cp "$PAYLOAD" "${WORK}/iso/ik-os/payload.oci"
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
xorriso -as mkisofs \
    -iso-level 3 \
    -volid "IK-OS-INSTALL" \
    -output "$ISO_PATH" \
    -eltorito-alt-boot \
    -e efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -append_partition 2 0xef "$ESP" \
    "${WORK}/iso"

sha256sum "$ISO_PATH" > "${ISO_PATH}.sha256"
log "ISO: ${ISO_PATH} ($(du -h "$ISO_PATH" | cut -f1))"
