# ADR 0006 — the base is Debian 14 (forky), tracked by codename

**Status:** accepted — SDD amended to 1.1
**SDD:** §3 (rewritten), §2, §9, §47, §63; Rules 15, 17

## Context

SDD 1.0 specified Debian Stable, tracked through the floating `stable` suite,
and forbade Debian Testing outright. That was the right default for a project
shipping immediately. ik-os is not shipping immediately: it ships after Debian
14 is released.

Two things forced the question:

1. **Desktop parity.** ik-os targets the Bluefin desktop experience, which is
   GNOME 50. Debian 13 has GNOME 48.7 and `trixie-backports` has **no GNOME at
   all** — 3220 binary packages, of which the only matches are
   `libreoffice-gnome` and `ssh-askpass-gnome`. GNOME 50 exists only in forky.
2. **Shipping a release behind.** Building on trixie means ik-os 1.0 arrives on
   an already-superseded base, and the migration to Debian 14 becomes a project
   in itself, during which the hardware matrix must be revalidated anyway.

## Decision

The base is Debian 14, tracked by the **codename** `forky`:

    deb http://deb.debian.org/debian forky main
    deb http://deb.debian.org/debian forky-updates main
    deb http://security.debian.org/debian-security forky-security main

### Why the codename, and not a suite alias

This is the part that makes the decision safe rather than reckless.

| Tracked | Today | On Debian 14 release day |
| --- | --- | --- |
| `stable` | trixie | forky — silent base change |
| `testing` | forky | **forky+1** — silent jump to the *next* release |
| `forky` | forky (testing) | forky (stable) — **nothing changes** |

Naming the codename means the testing-to-stable transition is a no-op: the same
URLs describe a testing base before release and a stable base after it. No
migration, no cut-over window, no build that silently follows a different
release. `00-preflight.sh` asserts the resolved codename is `forky` and fails
the build otherwise.

## What this removes

Debian 14 packages two of the three components ADR 0001 had to build from
source:

| Component | On trixie | On forky |
| --- | --- | --- |
| ostree | built from source (stable had 2025.2, bootc needs ≥ 2025.3) | **`ostree` 2026.2** |
| composefs | built from source (not packaged) | **`composefs` 1.0.8** |
| bootc | built from source | still built from source |

Rule 17 prefers Debian's maintained packages, so both source builds are gone.
bootc now links against the same `libostree`/`libcomposefs` the image ships, so
build and runtime cannot skew. The builder stage drops from three source builds
to one, and `libarchive` support is Debian's problem rather than a configure
flag we can forget (as we did once).

## Consequences, stated plainly

**Until Debian 14 releases, this is a testing base**, with the risks that
implies:

- Package churn. A build that failed because the archive moved is a normal
  event before release, not an incident.
- Security support for testing is not equivalent to stable. `forky-security` is
  configured, but the project must not assume stable-grade response times.
- `forky-backports` does not exist yet. The kernel therefore comes from the
  release itself (`KERNEL_SUITE=forky`), still pinned to an explicit version.
  The Backports pinning policy is kept in place but inert, ready for release.

**SDD §3 now requires** that the ik-os *stable* channel is not published from a
pre-release forky base without an explicit recorded decision, and that the full
hardware matrix is revalidated when Debian 14 ships. Development belongs in the
testing channel until then.

If Debian 14 slips badly, revisit: the alternative is trixie plus GNOME 48, not
trixie plus a back-ported GNOME 50.
