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
| Applications | Flatpak/Flathub (GUI), Homebrew (CLI), OCI containers (project deps), four pinned vendor packages |
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

**New machine:** boot the installer ISO from the latest release. It asks for
Wi-Fi and carries it over, so the first boot can install applications; if you
skip that, the desktop comes up bare and finishes setting itself up as soon as
it reaches a network. It takes the whole disk and encrypts it — LUKS2, passphrase chosen during installation and
asked for at every boot ([ADR 0022](docs/adr/0022-full-disk-encryption.md)).
There is no unencrypted install and no recovery key: a lost passphrase is a
lost disk. Disks under 32 GiB are refused, because first boot needs about
23 GiB for the deployment and the approved applications.

**Existing Bluefin machine:** `ik-os-migrate` — it preserves `/home`. See
[`docs/migration.md`](docs/migration.md). Do not use the ISO for this; it wipes
the disk. Note that migration cannot encrypt a disk underneath a running
system, so a migrated machine stays unencrypted until it is reinstalled.

## Applications not from Flathub

§54 routes GUI applications to Flatpak. Five are baked into the image instead,
each with an ADR saying why, and each pinned — four by version and sha256 in
`config/desktop/`, one by the signing key of its vendor's APT repository:

| | why | pin |
| --- | --- | --- |
| Claude Desktop | first-party APT repository, not on Flathub ([ADR 0007](docs/adr/0007-claude-desktop.md)) | apt |
| draw.io | the Flathub package is end-of-life ([ADR 0016](docs/adr/0016-drawio-from-upstream-deb.md)) | `drawio.env` |
| DevPod | the Flathub package is end-of-life, and upstream is quiet too ([ADR 0021](docs/adr/0021-devpod-from-upstream-deb.md)) | `devpod.env` |
| Sidra | on no Flatpak remote at all ([ADR 0019](docs/adr/0019-sidra-from-upstream-deb.md)) | `sidra.env` |
| Teams | a Flatpak cannot read `/etc/teams-for-linux/config.json`, where the company video backgrounds are configured ([ADR 0020](docs/adr/0020-teams-for-linux-from-upstream-deb.md)) | `teams-for-linux.env` |

Nothing updates these but their pins, so `scripts/maintenance/update-*.sh` moves
one and CI warns when upstream is ahead. Teams is the one to move promptly: as
a Flathub id it would have updated itself, and as a pin it will not. DevPod is
the one to reconsider: its pin is already upstream's newest stable release, and
that release is over a year old.

Nothing has been installed from this image yet, so no machine carries an older
copy of any of them. The one case that can produce two launcher entries is a
Bluefin machine migrated in place: the migration leaves `/var` alone, which is
what preserves `/home`, so a Flatpak already in `/var/lib/flatpak` survives it.
First boot will not reinstall Teams or DevPod — both ids are out of
`config/desktop/system-flatpaks.list` — but it will not remove a leftover
either:

    flatpak uninstall --system com.github.IsmaelMartinez.teams_for_linux

## Repository layout

    Containerfile           multi-stage build; bootc/composefs from pinned source
    build/scripts/          ordered build steps (00 preflight -> 95 finalize)
    build/validation/       package-list and in-image acceptance checks
    config/                 apt, boot, cups, docker, network, security, systemd, company
    packages/               the OS package inventory, one list per role
    desktop/gnome/          dconf defaults, locks, and the pinned extension set
    branding/               wallpapers, Teams video backgrounds, Plymouth, GDM
    systemd/                ik-os units and timers
    scripts/                first boot, diagnostics, maintenance
    migration/bluefin/      ik-os-migrate
    iso/                    UEFI live installer ISO builder
    tests/                  booted-system acceptance suites
    docs/adr/               decisions that deviate from the SDD, and why

## Status

**Pre-M1.** The image builds end to end and passes `bootc container lint` plus
all 300 in-container acceptance checks:

    Debian 14 (forky) · pinned kernel 7.1.13-1 (7.1.13+deb14-amd64)
    bootc 1.16.9 (from source) · ostree 2026.4 + composefs 1.0.8 (Debian packages)
    GNOME Shell 50.4 · Docker 28.5.2 · Compose v2.40.3

It has **not** been booted on Framework hardware, and the ISO and disk-image
paths have not been run end to end. Everything that needs a running machine —
Secure Boot, suspend/resume, printing a page, the migration — is still open.
Track the milestones in [SDD §62](docs/SDD.md) and the hardware matrix in
[`docs/hardware.md`](docs/hardware.md).

## Security note

The previous Bluefin-based image shipped the ik-office OpenVPN client key and
`tls-crypt` pre-shared key inside the published container image, and they are
also committed to that public repository. ik-os carries the same identity, in
`config/company/vpn/certs/`, so the company VPN works on a freshly installed
machine (ADR 0018). That is a deliberate, bounded exception to Rule 13: the
material is already public, and the profile is `password-tls`, so the
certificate is one factor of two — the username and password are in neither the
repository nor the image. It does not extend to any other credential, and CI
fails on a private key committed anywhere else.

The exposed material is **not** being reissued, deliberately: the VPN is
`password-tls`, so the certificate is only one of two factors and the password
is neither stored nor published. What is lost is `tls-crypt`'s job of hiding the
endpoint from unauthenticated traffic. The reasoning and the residual risk are
in [`config/company/vpn/README.md`](config/company/vpn/README.md).
