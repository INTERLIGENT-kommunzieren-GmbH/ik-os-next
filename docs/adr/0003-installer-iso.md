# ADR 0003 — the installer ISO is built with Debian tooling, not bootc-image-builder

**Status:** accepted
**SDD:** §36, §61; Rule 18

## Context

The Bluefin-based `ik-os` built its ISO with
`quay.io/centos-bootc/bootc-image-builder` using the `anaconda-iso` type. That
path is RPM-native: it composes a Fedora/CentOS Anaconda installer runtime with
`dnf` and osbuild stages that assume an RPM package manager. Pointed at a
Debian bootc image it has no installer to compose.

`bootc install to-disk` itself is distribution-agnostic and works fine for
Debian images, so only the *ISO* needs replacing, not the disk-image path.

## Decision

Two separate mechanisms:

- **Disk images (raw, qcow2).** `bootc install to-disk --via-loopback`, run
  from the ik-os image itself. No external image builder involved.
- **Installer ISO.** `iso/build-iso.sh` builds a UEFI live ISO with Debian
  tooling: `mmdebstrap` for the live root, `mksquashfs`, `grub-mkstandalone`
  for the EFI binary, and `xorriso` for the image. The ik-os OCI image travels
  on the medium as an OCI archive, and `iso/installer/ik-os-installer` runs
  `bootc install to-disk --source-imgref oci-archive:...`.

The live environment takes its `bootc` binary out of the payload image rather
than from a separate download, so the installer and the installed system are
always the same version.

## Consequences

- Installation works with no network connection (the image is on the medium).
- Legacy BIOS is not supported by the ISO. SDD §5 puts it out of scope, and the
  installer says so rather than failing obscurely.
- The installer is intentionally minimal — disk selection and confirmation. It
  does not create users; `gnome-initial-setup` does that on first boot.
- Preserving an existing `/home` is **not** offered by the ISO. That path is
  `ik-os-migrate`, which is built for it (SDD §30). The installer says so at the
  confirmation prompt so nobody reaches for the wrong tool.
