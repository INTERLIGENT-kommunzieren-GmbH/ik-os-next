# ADR 0004 — the dpkg database is relocated into /usr

**Status:** accepted
**SDD:** §4, §46

## Context

OSTree ships `/usr` and `/etc`; `/var` is machine state and is *not* part of
the image. On Fedora this is a non-issue because the RPM database lives at
`/usr/lib/sysimage/rpm`. Debian's dpkg database lives at `/var/lib/dpkg`.

Left alone, the dpkg database disappears the moment the image is deployed.
Consequences: `dpkg -l` and `apt` report an empty system, `ik-os diagnostics`
cannot list packages, and anyone deriving an image from ik-os starts from a
package manager that thinks nothing is installed.

Existing Debian bootc experiments simply `rm -rf /var` and accept this. For a
company image that has to produce a package manifest per release (SDD §46) and
supports derived images, it is not acceptable.

## Decision

`build/scripts/95-finalize.sh` copies `/var/lib/dpkg` to `/usr/lib/dpkg` and
`/var/lib/apt` to `/usr/lib/apt`, then ships tmpfiles symlinks:

    L /var/lib/dpkg - - - - ../../usr/lib/dpkg
    L /var/lib/apt  - - - - ../../usr/lib/apt

and points apt at the new location via `Dir::State` / `Dir::State::status`.

The same script captures the rest of `/var` — directories, symlinks and seeded
files — into `/usr/lib/tmpfiles.d/ik-os-var.conf` plus `/usr/share/factory/var`,
so state that packages created at build time is recreated on first boot. The
symlink capture is load-bearing for printing: ghostscript's CMap tree under
`/var/lib/ghostscript` is entirely symlinks, and CUPS filters break without it.

## Consequences

- `dpkg -l`, `apt list --installed` and the release manifest all work on a
  deployed machine.
- The package database is image content, so it is read-only at runtime. This is
  correct: SDD §40 forbids `apt upgrade` against the host anyway.
- Any package installed at build time that writes to `/var` after
  `95-finalize.sh` runs would be lost. Keep `95-finalize.sh` last.
