# ik-os

Company-managed immutable Linux desktop for Interligent developers.

Debian Stable, GNOME, delivered as a bootable OCI image over `bootc`. A
reimplementation of the previous Bluefin-based `ik-os` on a Debian base, built
to the specification in [`docs/SDD.md`](docs/SDD.md).

    Debian Stable + Backports kernel
        -> OCI image -> bootc -> OSTree/composefs -> bootable system

| | |
| --- | --- |
| Base | Debian 14 (forky), tracked by codename — testing until release, stable after |
| Kernel | pinned to an explicit validated version from the target release |
| Desktop | GNOME with ArcMenu (`Super+Space`), Bluefin-style extensions |
| Containers | Docker Engine, Compose v2, Buildx |
| Applications | Flatpak/Flathub (GUI), Homebrew (CLI), OCI containers (project deps) |
| Printing | CUPS, driverless IPP, IPP-over-USB |
| Hardware | Framework laptops, Intel 11th Gen through Core Ultra Series 3, Ryzen 7040 / Ryzen AI |

## Use it

    ik-os version           # image, kernel and build identity
    ik-os status            # plus the current bootc deployment
    ik-os update            # fetch and stage the current channel image
    ik-os rollback          # boot the previous deployment
    ik-os hardware          # detected hardware and firmware
    ik-os diagnostics       # full report; --bundle writes a support archive

`apt upgrade` is not how this system is updated. The host is immutable: OS
changes are made by publishing a new image. Install GUI applications with
`flatpak`, CLI tools with `brew`, and project dependencies with containers.

## Build it

    just build              # container image
    just verify             # in-image acceptance checks
    just build-qcow2        # bootable VM image
    just build-iso          # UEFI live installer ISO

See [`docs/development.md`](docs/development.md).

## Install it

**New machine:** boot the installer ISO from the latest release.

**Existing Bluefin machine:** `ik-os-migrate` — it preserves `/home`. See
[`docs/migration.md`](docs/migration.md). Do not use the ISO for this; it wipes
the disk.

## Repository layout

    Containerfile           multi-stage build; bootc/composefs from pinned source
    build/scripts/          ordered build steps (00 preflight -> 95 finalize)
    build/validation/       package-list and in-image acceptance checks
    config/                 apt, boot, cups, docker, security, systemd, company
    packages/               the OS package inventory, one list per role
    desktop/gnome/          dconf defaults, locks, and the pinned extension set
    systemd/                ik-os units and timers
    scripts/                first boot, diagnostics, maintenance
    migration/bluefin/      ik-os-migrate
    iso/                    UEFI live installer ISO builder
    tests/                  booted-system acceptance suites
    docs/adr/               decisions that deviate from the SDD, and why

## Status

**Pre-M1.** The image builds end to end and passes `bootc container lint` plus
all 55 in-container acceptance checks:

    Debian 14 (forky) · pinned kernel 7.1.8-2
    bootc 1.16.9 (from source) · ostree 2026.2 + composefs 1.0.8 (Debian packages)
    GNOME Shell 50.3 · Docker 28.5.2 · Compose v2.40.3

It has **not** been booted on Framework hardware, and the ISO and disk-image
paths have not been run end to end. Everything that needs a running machine —
Secure Boot, suspend/resume, printing a page, the migration — is still open.
Track the milestones in [SDD §62](docs/SDD.md) and the hardware matrix in
[`docs/hardware.md`](docs/hardware.md).

## Security note

The previous Bluefin-based image shipped the ik-office OpenVPN client key and
`tls-crypt` pre-shared key inside the published container image, and they are
also committed to that public repository. ik-os does not carry them — the VPN
identity is provisioned per device at enrolment.

The exposed material is **not** being reissued, deliberately: the VPN is
`password-tls`, so the certificate is only one of two factors and the password
is neither stored nor published. What is lost is `tls-crypt`'s job of hiding the
endpoint from unauthenticated traffic. The reasoning and the residual risk are
in [`config/company/vpn/README.md`](config/company/vpn/README.md).
