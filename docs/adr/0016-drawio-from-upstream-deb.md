# ADR 0016 — draw.io ships as a pinned upstream `.deb`, not a Flatpak

**Status:** accepted
**SDD:** §15, §24, §54; Rules 4, 15, 17, 18

## Context

`build/validation/check-flatpaks.sh` failed on 2026-08-31:

    ✗ "com.jgraph.drawio.desktop" is marked end-of-life on Flathub

It had passed earlier the same day, so Flathub marked it end-of-life between the
two runs — the check existed for exactly this and caught it within hours.

There is no successor on Flathub. `is_eol` is set with no `is_eol_rebase`
target, the id is hidden from search, and six plausible renames all 404. The
maintained diagram applications there are narrower (`com.umlet.Umlet` is UML
only) rather than equivalent.

**The application is not abandoned — only its Flathub packaging is.** That is
the fact that decided this ADR, and the first draft got it wrong:

| | version | date |
| ----------------------------- | ------- | ---------- |
| Flathub `com.jgraph.drawio.desktop` | 30.0.4 | 2026-05-27 |
| Upstream `.deb` / AppImage | 31.3.2 | 2026-08-22 |

So keeping the Flatpak was not "ship a slightly stale app". It was pinning an
Electron application — its own bundled Chromium — three months and one major
version behind, with the gap widening at upstream's release cadence and no
mechanism to ever close it.

The routes, in the order §54 and Rule 17 prefer them:

| Source | Status |
| --- | --- |
| Flathub | **end-of-life**, frozen at 30.0.4 |
| Debian archive | **not packaged** — no source package, no binary in forky |
| An upstream APT repository | **does not exist** (unlike Claude Desktop, ADR 0007) |
| Upstream GitHub release `.deb` | **available**, first-party, current |

## Decision

Install draw.io from upstream's own `.deb`, pinned by version and sha256 in
`config/desktop/drawio.env` and unpacked by `build/scripts/52-drawio.sh`. Remove
`com.jgraph.drawio.desktop` from `config/desktop/system-flatpaks.list`.

This overrides §54's "GUI application → Flatpak" and Rule 4's preference against
applications in the immutable host, on the same grounds as ADR 0007: the Flatpak
route is not available, so the rule has nothing to route to.

### Fetched, not vendored

`67-printer-vendor.sh` sets the house pattern — commit the `.deb` with a
`SHA256SUMS` and install from local disk, so the build needs no network and the
artefact cannot change under it. That is not possible here: the `.deb` is 127 MiB
and GitHub refuses any file over 100 MiB. Git LFS would work and is the way back
to vendoring if offline reproducibility becomes a requirement.

The pin therefore buys **tamper-evidence, not availability**. If upstream
deletes or re-tags the release, the build fails loudly with a message pointing at
`scripts/maintenance/update-drawio.sh`. Build-time network access is not a new
dependency — the build already fetches from `deb.debian.org`, `rustup.rs`,
GitHub (bootc) and Homebrew.

### Placed in `/usr`, with no `/opt` symlink

Upstream installs to `/opt/drawio`, and `/opt` is a symlink to `var/opt` here
while `95-finalize.sh` empties `/var` — so `/opt` cannot hold image content. The
Brother driver solves this with a tmpfiles symlink because its CUPS wrapper
recovers the printer model from its own `/opt` path.

draw.io needs none of that. Exactly two files in the package name `/opt/drawio` —
the `.desktop` and the AppArmor profile — and no binary resolves resources
through an absolute path. The tree goes to `/usr/lib/drawio`, `Exec=` is
rewritten, `/usr/bin/drawio` is a relative symlink, and nothing has to be
recreated at boot.

### The maintainer scripts are not run, and here that is load-bearing

ADR 0008 already skips maintainer scripts. This package shows why it is a rule
and not a preference — its postinst chooses a **privilege boundary** from a
property of the build environment:

    if ! { [[ -L /proc/self/ns/user ]] && unshare --user true; }; then
        chmod 4755 '/opt/drawio/chrome-sandbox'
    else
        chmod 0755 '/opt/drawio/chrome-sandbox'
    fi

`unshare --user` always fails in a rootless build container. Running the postinst
would therefore bake a **setuid-root binary** into every image, decided by how
the image was built rather than by what the target kernel supports. Debian
enables unprivileged user namespaces, so `0755` — what the archive already ships
— is correct. `52-drawio.sh` asserts both that no setuid bit exists anywhere in
the tree and that `chrome-sandbox` is exactly `0755`.

The bundled AppArmor profile is not installed either. It is the Ubuntu 24 userns
stub — `profile "drawio" "/opt/drawio/drawio" flags=(unconfined)` granting
`userns` — so it adds no confinement, names a path this image does not use, and
grants a permission Debian does not withhold.

### Dependencies are declared, and checked by running `ldd`

Unpacking rather than installing means apt never reads the `.deb`'s `Depends`, so
they are transcribed into `packages/desktop/packages.list`. Two names had to
change: forky's 64-bit `time_t` transition renamed `libgtk-3-0` to
`libgtk-3-0t64` and `libatspi2.0-0` to `libatspi2.0-0t64`, and
`libappindicator3-1` was dropped from Debian in favour of the `libayatana-` fork.
Transcribing upstream's list verbatim would have failed the build.

Because a transcribed list rots silently, `52-drawio.sh` runs `ldd` over every
ELF in the tree and fails on any `not found` — the same check
`67-printer-vendor.sh` uses, for the same reason: a missing library installs
perfectly and fails when a user clicks the icon.

## Consequences

**The sandbox is gone.** This is the real cost, and it is worse than the version
lag it fixes in one respect: the Flatpak confined draw.io, and a `/usr` install
does not. draw.io opens untrusted files, so this matters. Mitigations available
without another image build: it is a normal binary, so `firejail` or a systemd
unit could confine it; and `.drawio` files are XML handled by the app's own
bundled Chromium, which is now at least current.

**Updates are manual and nothing reminds us.** No Flathub, no APT repo, no
`apt upgrade` — the version in the image is whatever `drawio.env` pins.
`scripts/maintenance/update-drawio.sh` resolves the latest release, verifies the
artefact really is `Package: draw.io` at the claimed version, and rewrites both
pin lines together. That script is the entire maintenance story; if nobody runs
it, the image is exactly as stale as the Flatpak would have been, only without
the CI warning that would have said so.

That is the honest weakness of this decision. A periodic check that compares
`DRAWIO_VERSION` against the latest upstream tag, failing or warning in
`validate.yml`, would close it and is the obvious next step.

**+447 MiB in the image** (127 MiB compressed), against a 7.01 GB base — the
Electron runtime, unshared with anything. The Flatpak would have cost roughly the
same on disk but shared nothing either, since no other app used its runtime.

**One `.deb` does not make a pattern.** Rule 17 still prefers a maintained
upstream package, and §54 still prefers Flatpak. The next application that wants
this treatment needs its own ADR, and the question to ask first is the one asked
here: is the Flatpak *missing*, or merely *inconvenient*?

Revisit if draw.io returns to Flathub under any id, or if upstream publishes an
APT repository — either would restore a route the SDD prefers, and both are
cheaper to adopt than this is to maintain.
