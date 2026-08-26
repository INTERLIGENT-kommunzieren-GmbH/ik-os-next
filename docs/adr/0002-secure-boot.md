# ADR 0002 — Secure Boot with systemd-boot signed by a company MOK

**Status:** accepted
**SDD:** §5, §50; Rules 15, 18

## Context

SDD §5 requires *both* systemd-boot and Secure Boot.

On Debian these two requirements do not compose out of the box:

- Debian ships `shim-signed` and `grub-efi-amd64-signed`, both signed by
  Microsoft's UEFI CA via Debian's shim.
- Debian ships `systemd-boot` and `systemd-boot-efi` **unsigned**. There is no
  `systemd-boot-signed` package.

So an unmodified Debian systemd-boot will not start on a machine with Secure
Boot enabled. Rule 18 forbids silently swapping in GRUB and calling §5 done.

## Decision

ik-os signs `systemd-bootx64.efi` at build time with a company Machine Owner
Key. `shim-signed` stays in the image so the chain is:

    firmware -> shim (Microsoft-signed) -> systemd-boot (ik-os MOK) -> kernel

The key never exists on a developer workstation (SDD §45): it is held as the
`SECURE_BOOT_MOK_KEY` / `SECURE_BOOT_MOK_CERT` CI secrets and mounted into the
build.

`config/boot/secure-boot.env` controls the policy:

- `SECURE_BOOT_SIGNING=required` — the build **fails** without a key. CI sets
  this for the testing and stable channels.
- `SECURE_BOOT_SIGNING=optional` — an unsigned bootloader is produced. Local
  developer builds only; the resulting image will not Secure Boot.

The MOK is enrolled per machine, either by IT placing it in the firmware `db`
during provisioning, or via `mokutil --import` at install time.

## Alternatives rejected

- **Use Debian's signed GRUB instead.** Meets Secure Boot, violates §5's
  systemd-boot requirement. If the company later decides GRUB is acceptable,
  that is an SDD change, not an implementation decision.
- **Ship unsigned and tell users to disable Secure Boot.** Violates §50.

## Related

The bootloader *installation* mechanism is a separate decision: systemd-boot is
only installable through bootc's composefs backend. See
[ADR 0005](0005-composefs-backend.md).

## Consequences

- Machines need the ik-os MOK enrolled once. `ik-os-migrate check` reports
  Secure Boot state so this surfaces before migration, not after.
- `tests/boot/test-boot.sh` fails on a machine with Secure Boot disabled, which
  is deliberate: acceptance criterion 2 is not satisfied by a machine that
  merely *could* Secure Boot.
