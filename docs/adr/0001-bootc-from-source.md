# ADR 0001 — bootc is built from pinned source

**Status:** accepted — **scope reduced by [ADR 0006](0006-debian-14-base.md)**

> **Superseded in part.** This ADR originally covered ostree and composefs as
> well. On Debian 14 (ADR 0006) the archive provides `ostree` 2026.2 and
> `composefs` 1.0.8, both new enough for bootc, so only **bootc** is still
> built from source. The analysis below is retained because it explains why the
> ostree version matters at all, and what to check if bootc's requirement moves
> again.
**SDD:** §3, §4, §46, §47; Rules 15, 17, 18

## Context

SDD §4 requires the OS to be distributed as a bootable OCI image on `bootc`
over OSTree/composefs, and SDD §3 requires the base to be Debian **Stable**.
Rule 17 says not to use a third-party package when Debian provides an adequate
maintained one.

Checked against the Debian archive (`stable` and `stable-backports`):

| Component | In Debian stable | In trixie-backports | Adequate? |
| --- | --- | --- | --- |
| `ostree` | 2025.2-1 | **no** | **no** — too old, see below |
| `composefs` | **no source package** | **no** | — |
| `bootc` | **no source package** | **no** | — |

`trixie-backports` was checked directly against its package index: 3220 binary
packages, none of them `ostree`, `composefs` or `bootc`.

The ostree version is the part that is easy to miss. bootc's `ostree-ext` crate
requires the ostree crate's `v2025_3` feature, so building bootc against Debian
stable's ostree fails at compile time:

    Package 'ostree-1' has version '2025.2', required version is '>= 2025.3'

This is not specific to the newest bootc. Every release back to v1.11.0
(December 2025) pins `features = ["v2025_3"]`. Downgrading bootc far enough to
match Debian's ostree would mean shipping a bootc from before October 2025 as
the update mechanism of a production OS — a worse trade than building ostree.

Rule 18 forbids silently substituting an alternative, so the options had to be
stated rather than worked around.

## Options considered

1. **Substitute rpm-ostree, or plain ostree without bootc.** Rejected: Rule 2
   forbids rpm-ostree, and dropping bootc gives up the OCI-native update model
   that SDD §4 and §40 are built on.
2. **Base on Debian testing/unstable, which has a new enough ostree.**
   Rejected: SDD §3 explicitly forbids Debian Testing as the production base.
   This is why `bootcrew/mono` bases on `debian:unstable` and ik-os cannot.
3. **Use a third-party APT repository.** `DaemonCores/debian-bootc` publishes a
   `bootc` package for trixie. Rejected as the default: it adds a signing key
   and a release cadence outside company control to the most privileged
   component in the image, against SDD §46's requirement that the supply chain
   be recorded and reproducible.
4. **Build all three from pinned upstream tags in a builder stage.** Chosen.

## Decision

`Containerfile` builds composefs, then ostree, then bootc in a builder stage
from tags pinned in `config/image.env`, and copies only the resulting binaries
into the final image through a bind mount, so no Rust toolchain enters a layer.

    COMPOSEFS_VERSION=v1.0.8
    OSTREE_VERSION=2026.3
    BOOTC_VERSION=v1.16.9

Debian's `ostree` package **is** still installed, from `packages/base`, purely
so that apt resolves the runtime dependency graph correctly. The pinned upstream
build is then laid down on top and the package is held. `30-bootc.sh` asserts
that `ostree --version` reports the pinned version and fails the build if the
Debian binaries have shadowed it, and `verify-image.sh` re-checks this in the
finished image.

All three versions are recorded in `/usr/share/ik-os/release.env` and therefore
in every release manifest (SDD §41, §46).

## Consequences

- Image builds take substantially longer and download a Rust toolchain.
- The dpkg manifest reports ostree 2025.2 while the shipped binary is the
  pinned upstream build. `release.env` carries the true version
  (`OSTREE_SOURCE=upstream-pinned`), and support should read that, not
  `packages.manifest`.
- Upgrading any of the three is a deliberate, reviewable change to
  `config/image.env`, which is what SDD §47 asks for.
- **This ADR should shrink at the next Debian release.** Debian *forky* already
  carries ostree 2026.2, which satisfies bootc. When
  `EXPECTED_DEBIAN_CODENAME` moves to forky, drop the ostree build and take the
  Debian package (Rule 17). Revisit bootc and composefs then too.

## Prior art

The Debian ostree layout in `build/scripts/10-ostree-layout.sh` and
`95-finalize.sh` follows the approach proven by
[`bootcrew/mono`](https://github.com/bootcrew/mono) and
[`frostyard/debian-bootc-core`](https://github.com/frostyard/debian-bootc-core):
the `/ostree` symlink farm, `prepare-root.conf` with the composefs backend, the
`bootc` dracut module, and `HOME=/var/home` in `/etc/default/useradd`. The
`/var` symlink capture exists because of a concrete bug those projects hit —
ghostscript's CMap tree is entirely symlinks, and CUPS filters break without it.

ik-os does not build *on* those images: `bootcrew` bases on `debian:unstable`,
which SDD §3 forbids, and none of them are company-controlled. The techniques
are reused; the base is not.
