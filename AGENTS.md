# Repository Guidelines

`ik-os` is a company-managed immutable Debian desktop for Interligent
developers, shipped as a bootable OCI image over `bootc`. It reimplements the
previous Bluefin (Fedora) based `ik-os` on a Debian base.

[`docs/SDD.md`](docs/SDD.md) is the specification and it is binding. Read the
section a change touches before making it. Deviations must be recorded as an
ADR under `docs/adr/` **before** implementation (Rule 15).

## Project Structure & Module Organization

- `Containerfile` — three stages: `ctx` (build context), `bootc-builder`
  (compiles `bootc` and `composefs` from pinned source, because Debian packages
  neither), and the image itself.
- `build/scripts/` — numbered build steps run in order. `95-finalize.sh` must
  stay last: it captures `/var`, relocates the dpkg database into `/usr`, and
  lays down the ostree symlink farm. Anything writing to `/var` after it is
  lost.
- `packages/` — the OS package inventory by role. Not application dependencies.
- `config/company/` and `config/security/` — kept separate from upstream Debian
  config so policy can change independently.
- `desktop/gnome/extensions/{enabled.txt,versions.lock}` — the pinned extension
  set; the build fails if the two disagree with what is installed.
- `migration/bluefin/` — a distribution migration, never a `bootc switch`.
- `iso/` — the UEFI live installer. `bootc-image-builder`'s `anaconda-iso` is
  RPM-only, so the ISO is built with Debian tooling.

## Build, Test, and Development Commands

    just lint               # shellcheck every script
    just check-packages     # every package list resolves against the archive
    just check              # Justfile formatting
    just build              # ik-os:testing
    just verify             # in-image acceptance checks (SDD §63)
    just build-qcow2        # bootable VM image
    just build-iso          # UEFI live installer ISO

Run `just check-packages` before `just build`: it catches a renamed or dropped
package in seconds instead of forty minutes into an image build.

Booted-system suites live in `tests/`; run a single one directly, e.g.
`tests/printing/test-printing.sh`. Items printed with `?` are manual by design.

## Coding Style & Naming Conventions

- Build scripts source `build/scripts/lib.sh`, which sets `set -euo pipefail`
  and provides `log`/`info`/`die` and `apt_install_lists`.
- Under `pipefail`, never write `producer | grep -q`: `grep` exits early, the
  producer takes SIGPIPE, and a successful match is reported as a failure. Use
  `output_matches` / `output_matches_fixed` from `lib.sh`.
- Every package needs a justification comment (Rule 11). Prefer not adding one:
  GUI apps go to Flatpak, CLI tools to Homebrew, project dependencies to
  containers (SDD §54).
- Shellcheck must be clean at warning level. Suppressions carry a reason.

## Non-negotiables

These are acceptance criteria, not preferences, and CI enforces them:

- Debian Stable base; never Fedora, Ubuntu, Arch, NixOS, or rpm-ostree.
- Kernel from `stable-backports`, pinned to an explicit version, never compiled.
- ArcMenu, not Search Light; its button hidden; `Super+Space` opens its search.
- Docker required; Podman may be present but must not replace it.
- No secrets in the image. `config/company/` is scanned for private keys at
  build time and in CI.
- Nothing enters the immutable host that is not part of the OS specification.

## Validation Philosophy

The build asserts what it claims. `build/scripts/50-desktop.sh` checks every
gsettings key against the installed schema, `25-kernel.sh` fails on a missing
pinned kernel, `35-initramfs.sh` fails if the bootc dracut module is absent, and
`build/validation/verify-image.sh` runs the SDD §63 criteria inside the image.
When adding a requirement, add the check that would catch its absence.
