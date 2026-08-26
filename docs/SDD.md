# ik-os — Software Design Document

| Field | Value |
| --- | --- |
| Document version | 1.1 |
| Status | Implementation specification |
| Target | x86-64 developer workstations |
| Base | Debian 14 (forky) — testing until release, stable thereafter |
| OS model | Immutable OCI image + bootc |
| Desktop | GNOME |

### Revision history

| Version | Change |
| --- | --- |
| 1.0 | Initial specification. Base: Debian Stable (trixie) + Backports. |
| 1.1 | Base changed to Debian 14 (forky), tracked by codename so the testing-to-stable transition needs no migration. ik-os ships after Debian 14 releases; building on trixie would mean shipping a release behind on day one, and GNOME 50 is unavailable on trixie in any form. Affects §2, §3, §9, §47, §63. |

---

## 1. Purpose

`ik-os` is a company-managed immutable Linux desktop distribution for software developers.

The system shall provide a reproducible, centrally maintained workstation while allowing developers to use normal desktop and development applications without modifying the immutable operating-system layer.

The implementation MUST prioritize:

1. Debian compatibility.
2. Modern Framework Laptop hardware support.
3. Atomic OS updates and rollback.
4. OCI-based image distribution.
5. GNOME desktop usability.
6. Docker compatibility.
7. Flatpak and Homebrew support.
8. Driverless printing.
9. Controlled legacy/proprietary printer-driver support.
10. Migration from Fedora-based Bluefin installations.
11. Git-based reproducibility.
12. Automated CI/CD.

The implementation MUST NOT use Fedora as the base distribution.

NixOS MUST NOT be used as the base distribution.

---

## 2. Target Hardware

The initial hardware target is Framework Laptop hardware covering:

- Intel 11th generation
- Intel 12th generation
- Intel 13th generation
- AMD Ryzen 7040
- AMD Ryzen AI
- Intel Core Ultra
- Intel Core Ultra Series 3

The OS shall use a sufficiently recent Debian kernel. Until Debian 14 releases the kernel comes from the target release itself; afterwards `forky-backports` becomes the source when a newer kernel is required than the release provides.

The kernel MUST NOT be compiled from upstream source during the normal build process unless a documented hardware requirement makes this necessary.

The exact kernel package/version MUST be configurable and pinned by the image build.

The project MUST maintain a tested kernel channel independently from the userspace.

---

## 3. Base Distribution

The base distribution is:

```
Debian 14 (forky)
```

The image MUST track the **codename** `forky`, not a suite alias:

```
deb http://deb.debian.org/debian forky main
deb http://deb.debian.org/debian forky-updates main
deb http://security.debian.org/debian-security forky-security main
deb http://deb.debian.org/debian forky-backports main
```

### Why a codename and not a suite

`forky` is Debian *testing* today and becomes Debian *stable* when Debian 14 is
released. Because the sources name the codename, that transition requires no
change to the image, no migration, and no window in which the build silently
follows a different release. The same URLs describe a testing base before
release and a stable base after it.

Tracking the alias `testing` MUST NOT be done: on release day it would move to
the *next* release rather than staying with Debian 14. Tracking the alias
`stable` MUST NOT be done either: it would silently switch the base from
trixie to forky mid-project and back again in the future.

### Rationale for targeting Debian 14

ik-os ships after Debian 14 is released. Building on Debian 13 would mean
shipping a release behind on the first day, and the desktop parity ik-os
targets (GNOME 50) is not available on Debian 13 at all — neither in the
release nor in `trixie-backports`. Back-porting the GNOME stack onto trixie
would produce an incoherent mixture of two releases.

Targeting Debian 14 additionally removes work: forky provides `ostree` 2026.2
and `composefs` 1.0.8 as maintained packages, both of which had to be built
from upstream source on trixie.

### Obligations while forky is testing

Until Debian 14 releases, the base is a moving target and carries risks that
the released version will not:

1. The build MUST record the exact package versions of every release
   (see §46, §47), so that any regression can be attributed.
2. Package churn MUST be expected. A failing build after an archive change is
   a normal event before release, not an incident.
3. `forky-security` on `security.debian.org` MUST be configured, but the
   project MUST NOT assume the Debian security team supports testing to the
   same standard as stable. Security-critical fixes MAY need to be pulled
   forward explicitly.
4. The **stable** ik-os channel MUST NOT be published from a pre-release forky
   base without an explicit, recorded decision to do so. The testing channel is
   the appropriate home for ik-os builds until Debian 14 is released.
5. When Debian 14 is released, the project MUST re-validate the full hardware
   matrix (§9) before promoting to the stable channel.

The production OS MUST NOT use the floating `testing` alias as its base, and
MUST NOT be based on Debian unstable (sid) at any time.

`forky-backports` MAY be used, once it exists, for:

- Linux kernel
- firmware
- hardware enablement
- graphics stack where necessary
- other explicitly approved packages

Every package taken from Backports MUST be explicitly justified and documented.

The build MUST record the exact Debian repository and package versions used to
create a release.

---

## 4. Immutable OS Model

The operating system MUST be distributed as a bootable OCI image.

The target technology stack is:

```
OCI image
    |
    v
  bootc
    |
    v
OSTree / composefs
    |
    v
bootable system
```

The immutable OS layer MUST contain:

- kernel
- initramfs
- systemd
- system libraries
- GNOME
- hardware support
- Docker Engine
- CUPS
- company system configuration
- required security configuration

Developers MUST NOT normally modify `/usr` or install arbitrary Debian packages directly into the immutable host.

Host modifications MUST be performed by changing the OS image and publishing a new release.

---

## 5. Boot

The target boot architecture is:

- UEFI
- Secure Boot
- systemd-boot
- Boot Loader Specification
- bootc

Legacy BIOS is out of scope for the initial implementation.

The implementation MUST support booting a previous deployment/generation when supported by the bootc/OSTree deployment mechanism.

The system MUST be designed so that a failed OS deployment can be rolled back without reinstalling the machine.

---

## 6. Repository Structure

The canonical source repository SHOULD have this structure:

```
ik-os/
├── Containerfile
├── README.md
├── LICENSE
├── SDD.md
├── Makefile
│
├── build/
│   ├── scripts/
│   ├── package-lists/
│   └── validation/
│
├── config/
│   ├── apt/
│   ├── boot/
│   ├── cups/
│   ├── desktop/
│   ├── docker/
│   ├── security/
│   ├── systemd/
│   └── company/
│
├── desktop/
│   └── gnome/
│       ├── extensions/
│       │   ├── enabled.txt
│       │   └── versions.lock
│       ├── dconf/
│       └── defaults/
│
├── hardware/
│   └── framework/
│
├── packages/
│   ├── base/
│   ├── desktop/
│   ├── development/
│   ├── docker/
│   ├── hardware/
│   └── printing/
│
├── systemd/
│   ├── services/
│   └── timers/
│
├── migration/
│   └── bluefin/
│
├── scripts/
│   ├── firstboot/
│   ├── diagnostics/
│   └── maintenance/
│
├── tests/
│   ├── image/
│   ├── boot/
│   ├── hardware/
│   ├── printing/
│   ├── docker/
│   └── migration/
│
└── docs/
    ├── development.md
    ├── hardware.md
    ├── printing.md
    ├── migration.md
    └── releases.md
```

---

## 7. OCI Registry

The project MUST publish images to an OCI-compatible registry.

Canonical image names:

```
registry.example.com/ik-os:stable
registry.example.com/ik-os:testing
registry.example.com/ik-os:<version>
```

Release images MUST be immutable by digest.

The deployment system SHOULD support digest-pinned deployments.

---

## 8. Release Channels

At minimum:

```
testing
stable
```

### Testing

Testing contains:

- newer kernel versions
- new OS changes
- new GNOME extensions
- new application integrations
- hardware changes

### Stable

Stable contains:

- validated OS releases
- validated kernel
- validated desktop configuration
- validated hardware support

A release MUST pass automated validation before promotion from testing to stable.

The previous stable image MUST remain available for rollback.

---

## 9. Kernel Strategy

The kernel is an independently controlled component of the OS image.

Initial source:

```
forky            (the target release itself, until Debian 14 is released)
forky-backports  (afterwards, when a newer kernel than the release provides is needed)
```

The build configuration MUST contain a clearly defined kernel policy.

Example:

```
KERNEL_SUITE=forky
KERNEL_CHANNEL=release
KERNEL_VERSION=<validated-version>
```

`KERNEL_VERSION` MUST be an explicit validated version rather than "whatever the suite currently offers". This matters more, not less, while forky is testing: the archive kernel moves frequently, and an unpinned kernel would change under the hardware validation matrix without notice.

The build MUST fail if the requested kernel version is unavailable.

The kernel package MUST be installed through Debian packaging rather than downloading an arbitrary kernel archive.

Kernel updates MUST initially enter the testing channel.

A kernel release MAY be promoted to stable only after hardware validation.

Hardware validation MUST include, where applicable:

- boot
- Wi-Fi
- Bluetooth
- audio
- webcam
- suspend/resume
- USB
- USB-C
- external displays
- docking stations
- battery
- charging
- keyboard
- touchpad
- fingerprint reader

---

## 10. Firmware

The OS MUST include the appropriate Debian firmware packages.

Firmware SHOULD be updated independently from the kernel when possible.

The build MUST track firmware package versions.

Firmware required for supported Framework hardware MUST be part of the hardware validation matrix.

---

## 11. GNOME Desktop

The desktop environment MUST be GNOME.

The desktop SHOULD provide a user experience similar to Bluefin while remaining independently maintained by ik-os.

The implementation MUST NOT depend on Bluefin as a runtime component.

The project MUST maintain an explicit list of required GNOME extensions.

The exact extension identifiers MUST be stored in:

```
desktop/gnome/extensions/enabled.txt
```

Versions or source revisions SHOULD be stored in:

```
desktop/gnome/extensions/versions.lock
```

This prevents the desktop environment from silently changing when upstream extensions change.

---

## 12. Bluefin GNOME Extensions

The initial extension set SHOULD reproduce the current Bluefin desktop experience as closely as practical.

The exact current Bluefin extension list MUST be verified during implementation rather than inferred from this document.

Each extension MUST be classified as:

- required
- optional
- unsupported
- replaced by ik-os

The project MUST document the source and version of every required extension.

Bluefin itself MUST NOT be a runtime dependency.

---

## 13. ArcMenu

ArcMenu MUST be used instead of Search Light.

The ArcMenu launcher button MUST be hidden from the normal desktop UI.

The primary application/search interaction MUST be:

```
Super + Space
```

This shortcut MUST open ArcMenu's search interface.

The configuration MUST ensure that the ArcMenu button is not permanently visible in the panel/dock.

The implementation MUST test conflicts between:

- GNOME Super key handling
- ArcMenu
- Super+Space
- input-method switching

The exact keybinding MUST be stored in version-controlled GNOME/dconf configuration.

---

## 14. GNOME Configuration

Company desktop defaults MUST be declarative.

The configuration SHOULD include:

- GNOME interface settings
- keyboard shortcuts
- power settings
- display defaults
- touchpad defaults
- wallpaper
- dock/panel configuration
- ArcMenu configuration
- extension configuration

Configuration MUST be stored under:

```
desktop/gnome/dconf/
desktop/gnome/defaults/
```

User-specific settings MUST NOT be forcibly overwritten on every login.

The implementation SHOULD distinguish between:

1. company defaults
2. managed settings
3. user settings

---

## 15. Flatpak

Flatpak MUST be installed.

Flathub SHOULD be configured as the default application source.

Desktop applications SHOULD preferentially use Flatpak when:

- they are GUI applications
- they do not need privileged system integration
- the Flatpak has adequate hardware and filesystem permissions
- the application is sufficiently maintained

The company MAY maintain an approved Flatpak application list.

User Flatpaks MUST live outside the immutable `/usr` layer.

The OS MUST provide:

```
flatpak
```

without requiring developers to modify the base image.

---

## 16. Homebrew

Linux Homebrew MUST be supported.

Homebrew MUST be treated as a developer/application package manager, not as an OS package manager.

Homebrew MUST NOT be used for:

- kernel
- systemd
- bootloader
- core system libraries
- security-critical host packages

The project SHOULD provide a company-managed Brewfile.

Example:

```ruby
brew "git"
brew "gh"
brew "jq"
brew "ripgrep"
```

Developers MAY add personal Brew packages.

The company Brewfile MUST be version controlled.

---

## 17. Docker

Docker MUST be installed in the base OS.

Required components:

- Docker Engine
- Docker CLI
- Docker Compose
- Docker Buildx

The Docker daemon MUST be enabled as a system service.

The image MUST configure normal developer access to Docker according to the company's security policy.

The implementation MUST explicitly document the security implications of Docker group membership because Docker daemon access is privileged.

Docker Compose MUST work without requiring a separate manually installed binary.

Buildx MUST be available.

Required validation:

```bash
docker version
docker compose version
docker buildx version
docker run --rm hello-world
```

---

## 18. Podman

Podman MAY be installed for compatibility with OCI tooling.

Podman MUST NOT replace Docker as the primary developer container runtime in the initial implementation.

The project MUST avoid unnecessary duplication of container configuration.

---

## 19. OCI Development Environments

Project dependencies SHOULD be implemented through OCI containers.

Examples:

- PHP
- Node.js
- MariaDB
- PostgreSQL
- Redis
- development toolchains

The host OS SHOULD remain independent of project-specific runtime versions.

A project SHOULD be able to provide:

```
Containerfile
compose.yaml
devcontainer.json
```

without requiring modifications to the host OS.

---

## 20. Printing Architecture

CUPS MUST be included in the base image.

The initial package set SHOULD include, where provided by Debian:

```
cups
cups-client
cups-ipp-utils
cups-filters
cups-browsed
avahi-daemon
ipp-usb
```

Only packages actually required by the selected Debian release MUST be included.

---

## 21. Driverless Printing

Driverless printing is the preferred printing architecture.

The system MUST support, where provided by the printer:

- IPP Everywhere
- AirPrint
- IPP over USB
- DNS-SD/mDNS discovery

A user MUST be able to add a compatible network printer from GNOME Settings without manually installing a printer driver.

Printer discovery SHOULD use Avahi/DNS-SD.

---

## 22. Printer Drivers

Printer support is divided into three levels.

### Level 1 — Driverless

Preferred.

```
IPP Everywhere
AirPrint
IPP-over-USB
```

No driver installation is required.

### Level 2 — Debian packages

If a suitable driver exists in Debian, it SHOULD be packaged as part of the ik-os image or an approved system extension.

Potential examples:

```
printer-driver-*
gutenprint
hplip
```

The exact package set MUST be determined from actual supported printer hardware.

### Level 3 — Vendor-specific drivers

Vendor drivers MUST NOT be installed directly into the immutable root filesystem by arbitrary users.

Supported vendor drivers MUST be packaged and tested by the ik-os project.

The implementation SHOULD prefer modern CUPS Printer Applications/PAPPL-based solutions where available.

---

## 23. User Printer Installation

The normal workflow MUST be:

```
GNOME Settings
    |
    v
Printers
    |
    v
Add Printer
    |
    +--> Driverless IPP
    |
    +--> Installed Debian driver
    |
    +--> Approved printer application
```

Users SHOULD NOT require root privileges for normal driverless printer installation.

If a proprietary driver is required and is not installed, the UI SHOULD clearly indicate that administrator/company support is required.

---

## 24. Proprietary Printer Driver Installation

Because the host is immutable, arbitrary vendor `.deb` installation is prohibited.

The company MAY provide a separate approved driver repository.

Example:

```
packages/printing/vendor/
├── brother/
├── canon/
├── epson/
├── hp/
└── xerox/
```

The CI pipeline MUST validate:

- package origin
- package signature where available
- dependency compatibility
- installation
- removal
- CUPS integration
- printing functionality

Vendor packages MUST be included in the OS image only when necessary.

---

## 25. Docker Storage

Docker migration and persistence MUST distinguish between:

- images
- containers
- volumes
- networks
- Compose projects
- configuration

Images SHOULD be re-pulled.

Containers SHOULD be recreated.

Compose files SHOULD be preserved.

Named volumes MAY be migrated.

Docker internal state MUST NOT be blindly copied between Fedora and Debian.

---

## 26. Persistent User Data

The following data MUST persist across OS replacement:

```
/home
```

Relevant persistent `/var` data MUST also be retained where explicitly required.

The immutable OS image MUST NOT contain user secrets.

Examples of persistent user data:

- documents
- Git repositories
- SSH keys
- browser profiles
- Git configuration
- shell configuration
- application data

---

## 27. Secrets

The OCI image MUST NOT contain:

- SSH private keys
- API keys
- passwords
- cloud credentials
- company authentication tokens

Secrets MUST be provisioned after installation/enrollment.

---

## 28. Bluefin → ik-os Migration

ik-os MUST provide a migration path from Bluefin.

The migration MUST be an explicit distribution migration rather than a normal:

```bash
bootc switch
```

Reason:

```
Bluefin = Fedora-based
ik-os   = Debian-based
```

The migration tool SHOULD be:

```
ik-os-migrate
```

Commands:

```bash
ik-os-migrate check
ik-os-migrate backup
ik-os-migrate install
ik-os-migrate reboot
ik-os-migrate status
ik-os-migrate rollback
```

---

## 29. Migration Preflight

`ik-os-migrate check` MUST validate:

- supported hardware
- UEFI
- Secure Boot state
- disk capacity
- existing partitions
- `/home`
- user accounts
- UID/GID
- installed Flatpaks
- Docker state
- Docker volumes
- SSH configuration
- Git configuration
- network configuration
- recovery capability

The migration MUST abort if required prerequisites are not satisfied.

The migration tool MUST produce a human-readable report.

---

## 30. Migration Data Preservation

The migration SHOULD preserve:

- `/home`
- user accounts
- UID/GID
- SSH keys
- Git configuration
- shell configuration
- browser profiles
- Flatpak user data
- Flatpak application list
- Docker Compose projects
- Docker volumes
- user documents

The migration MUST NOT blindly copy:

- `/usr`
- Fedora system configuration
- Fedora systemd units
- RPM database
- rpm-ostree state
- Fedora kernel configuration
- Fedora-specific GNOME system configuration

---

## 31. Migration — Flatpak

Before migration:

```bash
flatpak list --app --columns=application
```

The application list SHOULD be saved.

After migration, applications SHOULD be reinstalled from Flathub.

User application data SHOULD remain in the persistent home directory.

The migration MUST detect Flatpaks that are unavailable and report them.

---

## 32. Migration — Docker

Docker projects SHOULD be preserved.

The migration MUST:

1. record running containers
2. record images
3. record volumes
4. record networks
5. preserve Compose files
6. stop Docker cleanly
7. install ik-os Docker
8. restore approved persistent data
9. recreate containers

Docker internal state MUST NOT be copied blindly between Fedora and Debian.

---

## 33. Migration — Homebrew

If Homebrew is installed on Bluefin, the migration SHOULD record:

```bash
brew bundle dump
```

or an equivalent package inventory.

The migration SHOULD restore the approved Brew packages after the new OS has booted.

Homebrew itself MUST be reinstalled on the new OS rather than copying its Fedora-era installation tree.

---

## 34. Migration — GNOME

The migration MUST NOT blindly import the complete Bluefin GNOME configuration.

Instead:

```
Bluefin user configuration
        |
        +--> personal settings
        |
        +--> application settings
        |
        +--> compatible user preferences
```

should be migrated selectively.

The ik-os desktop defaults MUST take precedence for managed settings.

The new desktop configuration MUST establish:

- required GNOME extensions
- ArcMenu
- hidden ArcMenu button
- Super+Space
- ik-os defaults

---

## 35. Migration Rollback

The migration MUST provide a recovery path.

Before destructive partition or boot changes, the tool MUST create or verify a recovery mechanism.

The migration MUST NOT destroy `/home` without explicit confirmation.

The migration SHOULD provide a dry-run mode:

```bash
ik-os-migrate check
```

and preferably:

```bash
ik-os-migrate install --dry-run
```

---

## 36. Installation

The initial installer SHOULD support:

- automatic installation
- manual disk selection
- preservation of existing `/home` where explicitly supported
- Secure Boot
- UEFI
- user creation
- optional company enrollment

The installer MUST clearly warn before destructive disk operations.

---

## 37. First Boot

After installation, the system SHOULD execute a first-boot service.

Responsibilities:

- hardware detection
- enrollment
- company configuration
- user configuration
- Flatpak configuration
- Homebrew setup
- Docker verification
- CUPS verification
- diagnostics

The first-boot process MUST be idempotent.

Running it twice MUST NOT corrupt the system.

---

## 38. Device Enrollment

The OS SHOULD support company device enrollment.

Enrollment SHOULD identify:

- device
- hardware model
- OS version
- image digest
- kernel version
- user

The identity provider and management backend MUST remain configurable.

---

## 39. Company Configuration

Company configuration MUST be separate from upstream Debian configuration.

Examples:

```
config/company/
config/security/
config/desktop/
```

This allows company policy to evolve without redesigning the Debian base.

---

## 40. Updates

OS updates MUST be image-based.

Developers MUST NOT normally execute:

```bash
apt upgrade
apt dist-upgrade
```

against the immutable host.

The supported update mechanism is:

```bash
bootc update
```

A company wrapper SHOULD eventually be provided:

```bash
ik-os update
ik-os status
ik-os rollback
ik-os version
```

---

## 41. Update Safety

Every new deployment MUST have:

- image digest
- release version
- kernel version
- build ID
- Git commit
- Debian package manifest

The system SHOULD retain the previous known-good deployment.

---

## 42. Rollback

A failed deployment MUST be recoverable through the boot/deployment mechanism.

Rollback SHOULD be possible from:

```bash
ik-os rollback
```

and, where supported, from the bootloader.

Rollback MUST NOT delete persistent user data.

---

## 43. Diagnostics

The system MUST provide:

```bash
ik-os diagnostics
```

The command SHOULD report:

- OS version
- image digest
- Git commit
- kernel
- firmware
- hardware
- Secure Boot
- boot deployment
- Docker
- Flatpak
- Homebrew
- CUPS
- networking
- GNOME
- GNOME extensions

Secrets MUST be redacted.

A support bundle SHOULD be exportable.

---

## 44. CI/CD

The CI pipeline MUST perform:

```
Git commit
    |
    v
Container build
    |
    v
Package validation
    |
    v
Image boot test
    |
    v
Security scan
    |
    v
CUPS tests
    |
    v
Docker tests
    |
    v
OCI image signing
    |
    v
OCI registry
    |
    v
Testing
    |
    v
Hardware validation
    |
    v
Stable promotion
```

The pipeline SHOULD run on Forgejo/GitLab or another Git-compatible CI system.

---

## 45. Image Signing

Production images SHOULD be cryptographically signed.

The deployment system SHOULD verify image signatures before installation.

The signing system MUST operate independently from individual developer workstations.

---

## 46. Supply Chain

The build MUST generate a package manifest.

The release SHOULD contain:

- OCI image digest
- source Git commit
- Debian repository information
- resolved Debian suite codename and point release
- package versions
- kernel version
- firmware version
- GNOME extension versions
- build timestamp
- SBOM

The implementation SHOULD use standard OCI/SBOM formats.

---

## 47. Package Pinning

Critical components MUST be pinned or otherwise reproducibly resolved.

At minimum:

- kernel
- bootc
- systemd-related boot components
- firmware
- GNOME extension versions
- critical company packages

Because the base suite is the floating `stable`, the build MUST record the codename that `stable` resolved to for each release, and the CI pipeline MUST fail the build when that codename changes without an approved release-transition ticket.

The project MUST avoid uncontrolled dependency upgrades during a stable image build.

---

## 48. Hardware Detection

The OS SHOULD provide:

```bash
ik-os hardware
```

The command SHOULD identify:

- Framework generation
- CPU vendor/model
- GPU
- Wi-Fi chipset
- Bluetooth chipset
- display controller
- docking hardware
- firmware versions

The result SHOULD be usable by support and migration tooling.

---

## 49. Framework Hardware Profiles

The project MAY define profiles:

```
framework-intel
framework-amd
framework-ryzen-ai
framework-core-ultra
```

Profiles MUST NOT create separate operating-system distributions unless technically necessary.

The preferred architecture is one common image with hardware detection and compatible packages.

---

## 50. Security

The OS MUST:

- use Secure Boot where hardware supports it
- enable a supported firewall configuration
- keep security updates current
- minimize unnecessary services
- avoid unnecessary listening network ports
- restrict CUPS network exposure
- protect Docker daemon access
- keep secrets outside the image

The exact security policy MUST be configurable through:

```
config/security/
```

---

## 51. Docker Security

Docker group membership MUST be explicitly documented.

By default, membership in the Docker group effectively grants root-equivalent control over the host.

If company policy requires stronger isolation, the project SHOULD investigate:

- rootless Docker
- rootless Podman
- controlled privileged development environments

The initial implementation MUST prioritize compatibility with normal Docker workflows.

---

## 52. CUPS Security

CUPS administration MUST require appropriate authorization.

Remote CUPS administration SHOULD be disabled unless explicitly required.

Printer queues SHOULD NOT be exposed to the LAN by default.

Network printer discovery MAY use:

```
Avahi
DNS-SD
mDNS
IPP
```

---

## 53. User Customization

Developers SHALL be able to customize:

- shell
- editor
- terminal
- Flatpak applications
- Homebrew packages
- Git configuration
- SSH configuration
- project containers
- user services
- GNOME personal settings

Developers SHALL NOT normally modify:

- `/usr`
- kernel
- bootloader
- system security configuration
- immutable system libraries

---

## 54. Application Policy

Use this decision hierarchy:

```
Is it part of the OS?
    |
    +-- Yes --> Debian package / OS image
    |
    +-- No
         |
         +-- GUI application --> Flatpak
         |
         +-- CLI developer tool --> Homebrew
         |
         +-- Project dependency --> OCI container
         |
         +-- Hardware/system integration --> OS image
```

This policy SHOULD be enforced during architectural review.

---

## 55. Development Environment

A developer workstation SHOULD provide:

```
Git
Docker
Docker Compose
Buildx
Flatpak
Homebrew
GNOME
CUPS
SSH
standard Unix tooling
```

Additional tools SHOULD be provided through Homebrew or project containers.

---

## 56. Application Inventory

The project SHOULD maintain:

```
packages/
    base/
    desktop/
    development/
    hardware/
    printing/
```

Flatpak applications SHOULD be listed separately.

Homebrew packages SHOULD be defined through the company Brewfile.

This prevents the OS package list from becoming a mixture of unrelated application dependencies.

---

## 57. OS Branding

The operating system name is:

```
ik-os
```

The project MUST use `ik-os` consistently for:

- image names
- documentation
- CLI tools
- diagnostics
- migration tooling
- system identification
- support information

Examples:

```bash
ik-os version
ik-os update
ik-os diagnostics
ik-os hardware
ik-os rollback
ik-os-migrate check
```

---

## 58. Migration Branding

The migration tool is:

```
ik-os-migrate
```

It MUST clearly identify:

```
Current OS: Bluefin
Target OS: ik-os
```

before performing any destructive operation.

---

## 59. Non-Goals

The initial project MUST NOT attempt to provide:

- Fedora compatibility
- NixOS compatibility
- legacy BIOS support
- arbitrary kernel compilation
- arbitrary host package installation
- arbitrary proprietary driver installation
- a custom package manager
- a custom container runtime
- a custom desktop environment
- a custom init system

The project should integrate mature existing technologies rather than replace them.

---

## 60. Implementation Rules for an LLM

An implementation agent MUST follow these rules.

**Rule 1** — Do not replace Debian with Fedora, Ubuntu, Arch or NixOS.

**Rule 2** — Do not replace bootc with rpm-ostree.

**Rule 3** — Do not compile the kernel from source unless explicitly requested. Use Debian Backports.

**Rule 4** — Do not install development dependencies into the immutable host unless they are explicitly part of the OS specification. Prefer Flatpak, Homebrew or OCI containers.

**Rule 5** — Do not install arbitrary proprietary printer `.deb` packages directly into `/usr`.

**Rule 6** — Do not copy Bluefin system configuration blindly. Extract the desired functionality and reproduce it on Debian.

**Rule 7** — Do not use Search Light. Use ArcMenu.

**Rule 8** — ArcMenu MUST be hidden.

**Rule 9** — Super+Space MUST open ArcMenu search.

**Rule 10** — Docker is required. Podman may be provided additionally but MUST NOT replace Docker.

**Rule 11** — Do not add speculative dependencies. Every package MUST have a documented reason.

**Rule 12** — Every OS-level change MUST be reproducible from Git.

**Rule 13** — Never embed secrets in the OCI image.

**Rule 14** — Do not destroy persistent user data during migration.

**Rule 15** — Every implementation decision that deviates from this SDD MUST be documented before implementation.

**Rule 16** — Do not assume that an upstream Bluefin component is compatible with Debian. Verify every dependency.

**Rule 17** — Do not use a third-party package when Debian provides an adequate maintained package unless there is a documented reason.

**Rule 18** — Do not silently substitute an alternative technology. If a required component is unavailable, stop and document the issue.

---

## 61. Initial Deliverables

The implementation agent MUST produce:

```
Containerfile
build scripts
package lists
GNOME configuration
GNOME extension lock file
Docker configuration
CUPS configuration
systemd units
boot configuration
Secure Boot configuration
CI pipeline
OCI image publishing configuration
image signing configuration
migration tool
diagnostics tool
tests
documentation
```

The first milestone is a bootable:

```
ik-os:testing
```

OCI image.

The implementation MUST proceed incrementally.

The agent MUST NOT attempt to implement the complete fleet-management system before a bootable workstation image has been validated.

---

## 62. Development Milestones

### M1 — Bootable OS

Implement:

```
Debian 14 (forky)
+ bootc
+ OCI
+ systemd-boot
+ Secure Boot
+ GNOME
+ pinned forky kernel
```

Acceptance:

- Framework machine boots
- Secure Boot works
- GNOME starts
- `bootc status` works

### M2 — Developer Workstation

Add:

```
Flatpak
Flathub
Homebrew
Docker
Compose
Buildx
```

Acceptance:

```bash
docker run --rm hello-world
flatpak --version
brew --version
```

### M3 — Desktop UX

Add:

```
GNOME configuration
Bluefin-inspired extensions
ArcMenu
hidden ArcMenu button
Super+Space
```

Acceptance:

- ArcMenu button is hidden
- Super+Space opens search
- required extensions load
- no Search Light is installed

### M4 — Framework Hardware

Validate:

```
Intel 11th Gen
Intel 12th Gen
Intel 13th Gen
Ryzen 7040
Ryzen AI
Core Ultra
Core Ultra Series 3
```

Test:

- Wi-Fi
- Bluetooth
- suspend/resume
- audio
- webcam
- USB
- USB-C
- displays
- docking
- battery
- charging

### M5 — Printing

Implement:

```
CUPS
driverless IPP
Avahi
IPP-over-USB
approved printer drivers
```

Acceptance:

- network printer discovery
- IPP Everywhere
- AirPrint
- USB printer support where available
- print test page

### M6 — Migration

Implement:

```
Bluefin detection
preflight
backup
data preservation
Flatpak migration
Docker migration
Homebrew migration
installation
first boot
recovery
```

### M7 — Production

Implement:

```
CI/CD
image signing
SBOM
testing channel
stable channel
rollback
diagnostics
documentation
```

---

## 63. Acceptance Criteria

Version 1.0 is complete when:

1. ik-os boots on all defined Framework hardware classes.
2. Secure Boot works.
3. systemd-boot works.
4. The pinned kernel from the target Debian release is used.
5. bootc updates work.
6. boot rollback works.
7. GNOME works.
8. the selected Bluefin-style extensions work.
9. ArcMenu is installed.
10. ArcMenu is hidden.
11. Search Light is not installed.
12. Super+Space opens ArcMenu search.
13. Docker Engine works.
14. Docker Compose works.
15. Docker Buildx works.
16. Flatpak works.
17. Flathub works.
18. Homebrew works.
19. CUPS works.
20. driverless IPP printing works.
21. Bluefin migration preflight works.
22. Bluefin user data can be migrated without formatting `/home`.
23. Flatpak applications can be restored.
24. Docker Compose projects can be restored.
25. Homebrew packages can be restored.
26. The OS can be rebuilt from Git.
27. OCI image publication works.
28. Production images are signed.
29. Testing and stable channels exist.
30. A failed OS update can be rolled back.
31. Diagnostics can produce a support bundle.
32. No secrets are present in the OCI image.

---

## 64. Recommended Final Architecture

```
                         Git Repository
                               |
                               v
                         CI/CD Pipeline
                               |
                +--------------+--------------+
                |                             |
                v                             v
          Build / Test                  Security / SBOM
                |                             |
                +--------------+--------------+
                               |
                               v
                         OCI Image
                       registry/ik-os
                               |
                    +----------+----------+
                    |                     |
                 testing                stable
                    |                     |
                    +----------+----------+
                               |
                             bootc
                               |
                     Debian 14 (forky)
                               |
                         Linux kernel
                          (pinned)
                               |
                        systemd-boot
                               |
                         Secure Boot
                               |
               +---------------+---------------+
               |                               |
             GNOME                         Docker
               |                               |
       +-------+-------+                  Compose
       |               |                  Buildx
    ArcMenu        Extensions                |
       |                                  OCI dev
 Super+Space                             environments
       |
   Flatpak
       |
   Flathub
       +----------------+----------------+
       |                |                |
    Homebrew          CUPS           Hardware
       |                |                |
    CLI tools       Driverless       Framework
                     IPP              laptops
```

---

## 65. Design Principle

The central design principle of ik-os is:

```
Stable immutable host
        +
modern Debian kernel
        +
standard Linux applications
        +
Docker
        +
Flatpak
        +
Homebrew
        +
OCI development environments
        +
reproducible configuration
        +
controlled company integration
```

The developer should experience a normal Linux desktop.

The complexity of the immutable image, CI pipeline, hardware validation and release management should remain behind the operating-system implementation.

The system should feel like a conventional, polished Linux workstation while retaining the reproducibility and rollback characteristics of an immutable OS.
