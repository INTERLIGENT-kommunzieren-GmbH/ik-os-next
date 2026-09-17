# ADR 0019 — Sidra ships as a pinned upstream `.deb`

**Status:** accepted
**SDD:** §15, §24, §54; Rules 4, 11, 17, 18
**Follows:** [ADR 0016](0016-drawio-from-upstream-deb.md) (draw.io), which
established the pattern and the reservations about it

## Context

[Sidra](https://github.com/wimpysworld/sidra) is an Apple Music desktop client.
It was asked for as a normal application request; the only question this ADR
answers is *how* it gets installed, not whether it should be.

The routes, in the order §54 and Rule 17 prefer them:

| Source | Status |
| --- | --- |
| Flathub | **nothing at all** — the id 404s and a search for "sidra" returns no hits |
| Debian archive | **not packaged** — no source package, no binary in forky |
| An upstream APT repository | **does not exist** (unlike Claude Desktop, ADR 0007) |
| Upstream GitHub release `.deb` | **available**, first-party, current |

This is a weaker case than draw.io's in one respect and a stronger one in
another. Weaker: draw.io was already in the image and its Flatpak *died*, so
doing nothing meant shipping an end-of-life Electron runtime. Nothing is at
stake here but a new application. Stronger: there is no "is the Flatpak merely
inconvenient?" question to ask, which is the question ADR 0016 closed with.
There is no Flatpak.

## Decision

Install Sidra from upstream's own `.deb`, pinned by version and sha256 in
`config/desktop/sidra.env` and unpacked by `build/scripts/53-sidra.sh`.

The mechanics are draw.io's, because the packaging is identical — both are
electron-builder output:

* **Placed in `/usr/lib/sidra`, not `/opt`.** `/opt` is a symlink to `var/opt`
  and `95-finalize.sh` empties `/var`, so a payload left in `/opt` produces an
  image whose application disappears on deployment. Only the `.desktop` names
  `/opt/Sidra`; its four `[Desktop Action]` entries call `dbus-send`, not the
  binary. `Exec=` is rewritten and `/usr/bin/sidra` is a relative symlink.
* **The maintainer scripts do not run** (ADR 0008), and here that is again
  load-bearing rather than tidy. Sidra's postinst is draw.io's, down to the
  `unshare --user` test that decides whether `chrome-sandbox` is setuid root.
  That test always fails in a rootless build container, so running the postinst
  would bake a setuid-root binary into every image because of a property of the
  **builder**. Debian enables unprivileged user namespaces, so `0755` is
  correct, and `53-sidra.sh` asserts both that no setuid bit exists in the tree
  and that `chrome-sandbox` is exactly `0755`.
* **The AppArmor profile is not installed.** Same Ubuntu 24 userns stub as
  draw.io's: unconfined, naming a path this image does not use, granting a
  permission Debian does not withhold.
* **Dependencies are declared and checked.** Sidra's `Depends` is byte-for-byte
  draw.io's, so `packages/desktop/packages.list` already satisfied it — the
  comment there now names all three unpacked applications. `53-sidra.sh` still
  runs `ldd` over every ELF and fails on `not found`, because a transcribed list
  rots silently and a missing library installs perfectly and fails at launch.

## Consequences

**No sandbox.** A `/usr` install is not confined, and unlike draw.io there is no
"but the Flatpak was three months stale" to set against it — the Flatpak simply
does not exist. Sidra talks to Apple's servers and renders their web content in
its own bundled Chromium. That is the honest cost.

**Updates are manual.** `scripts/maintenance/update-sidra.sh` moves the pin;
`build/validation/check-sidra.sh` warns in CI when upstream is ahead, so this
one does not repeat draw.io's original mistake of a pin nobody notices going
stale. It warns rather than fails: upstream releases often, and a check that
reddens unrelated work gets disabled rather than acted on.

**+296 MiB in the image** (98 MiB compressed) — another unshared Electron
runtime, the third after draw.io and teams-for-linux (ADR 0020).

**Tamper-evidence, not provenance.** Upstream publishes no signature and no
checksum file, so the pinned digest records what was served when a human ran the
update script. It catches a corrupted download and a re-tagged release. It
proves nothing about upstream itself.

**This is now three `.deb`s, which is close to being a pattern.** ADR 0016 said
one does not make one, and that the question to ask first is whether the Flatpak
is *missing* or merely *inconvenient*. For Sidra it is missing. The next
application still needs its own ADR and the same question — Rule 17 has not
changed, and neither has §54.

Revisit if Sidra appears on Flathub, or if upstream publishes an APT repository.
Either restores a route the SDD prefers.
