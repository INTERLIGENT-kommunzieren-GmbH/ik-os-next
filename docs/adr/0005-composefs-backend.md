# ADR 0005 — the composefs backend, because systemd-boot requires it

**Status:** accepted
**SDD:** §4, §5; Rules 15, 18

## Context

SDD §5 requires systemd-boot. SDD §4 names the stack as
`OCI image -> bootc -> OSTree / composefs -> bootable system`.

bootc 1.16.9 has two install backends, and they do not support the same
bootloaders:

| Backend | grub | grub-cc | systemd-boot |
| --- | --- | --- | --- |
| ostree (default) | via bootupd | — | **hard error** |
| composefs (`--composefs-backend`) | yes | yes | **yes** |

On the ostree backend, `crates/lib/src/install.rs` bails outright:

    Bootloader::Systemd | Bootloader::GrubCC => {
        anyhow::bail!("bootupd is required for ostree-based installs");
    }

Bootloader detection is `--bootloader` > bootupd present > systemd-boot
fallback. With no bootupd in the image it fell back to systemd-boot, which the
ostree backend then refused.

`bootupd` is not a way out. It is not packaged by Debian, and its README states
it supports GRUB and shim for UEFI — systemd-boot support is unimplemented and
speculative ("this project would probably just proxy that if we detect
systemd-boot is in use").

## Options considered

1. **Build bootupd from source and switch to GRUB.** Rejected: it violates SDD
   §5. Rule 18 forbids silently substituting a different technology, and this
   would be exactly that — the image would boot, and nobody would notice the
   specification had been abandoned.
2. **`--bootloader none` and install systemd-boot ourselves.** Rejected: ik-os
   would then own bootloader installation *and* its update path across every
   deployment, which is precisely the work bootc exists to do.
3. **Use the composefs backend.** Chosen.

## Decision

Installs use `--composefs-backend --bootloader systemd`, declared once in
`config/image.env`:

    BOOTC_BACKEND=composefs
    BOOTC_BOOTLOADER=systemd
    BOOTC_ALLOW_MISSING_VERITY=false

Both install paths read those values — `just build-qcow2` sources the file
directly, and `iso/build-iso.sh` stages it into the live installer — so an ISO
install and a disk-image install cannot drift apart.

This also matches SDD §4 more closely than the ostree backend does: the
specification names composefs explicitly, and this backend is composefs-native
rather than composefs-under-ostree.

## Consequences

- **The composefs backend is newer and less exercised than the ostree one.**
  This is the least-proven load-bearing choice in the project. It needs a real
  boot on real hardware before M1 can be signed off, not just a passing install.
- `bootc status`, `bootc upgrade` and rollback all run through the composefs
  code path, so `ik-os update` / `ik-os rollback` must be tested against it
  specifically (`tests/boot/test-boot.sh`).
- fs-verity is required by default. A target filesystem that cannot provide it
  fails the install rather than quietly dropping the integrity guarantee. If
  that happens, diagnose it — do not set `BOOTC_ALLOW_MISSING_VERITY=true` and
  move on.
- If bootc later supports systemd-boot on the ostree backend, or bootupd grows
  systemd-boot support, revisit this. Neither changes the SDD requirement.
