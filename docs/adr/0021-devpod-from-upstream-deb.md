# ADR 0021 — DevPod comes from upstream's `.deb`, and is on notice

**Status:** accepted
**SDD:** §15, §24, §54; Rules 4, 11, 17, 18
**Follows:** [ADR 0016](0016-drawio-from-upstream-deb.md),
[ADR 0019](0019-sidra-from-upstream-deb.md),
[ADR 0020](0020-teams-for-linux-from-upstream-deb.md)

## Context

`build/validation/check-flatpaks.sh` fails:

    ✗ "sh.loft.devpod" is marked end-of-life on Flathub — it will install but
       never receive another update.

This is draw.io's situation again, and the check caught it the same way. The
Flathub build is frozen at **0.6.10 (2024-01-21)**, `is_eol` is set with no
`is_eol_rebase` target, and nothing on Flathub replaces it.

The routes, in the order §54 and Rule 17 prefer them:

| Source | Status |
| --- | --- |
| Flathub | **end-of-life**, frozen at 0.6.10 |
| Debian archive | **not packaged** |
| An upstream APT repository | **does not exist** |
| Homebrew | a `devpod` **cask** exists, but casks are macOS — it installs a `.dmg` |
| Upstream GitHub release `.deb` | **available**, first-party, 0.6.15 |

The Homebrew line is worth stating because ADR 0009 already put two GUI tools in
Homebrew from the `ublue-os` tap, so it was the obvious route to try. It does
not work here: the only `devpod` cask points at `DevPod_macos_aarch64.dmg`.

### The part that is not like draw.io

Upstream is **not obviously shipping either**. The newest stable release is
0.6.15 (2025-03-10); since then there are only `v0.7.0-alpha` prereleases, the
last from 2025-06-23, and the repository's last commit is 2025-11-14. draw.io's
ADR turned on the fact that *the application was alive and only its packaging was
dead*. That fact does not hold here.

What is still true is that **0.6.15 is fourteen months newer than 0.6.10**. The
choice is not between a maintained DevPod and an unmaintained one; it is between
two frozen copies, one of them more than a year further along and installed by a
mechanism we control.

## Decision

Install DevPod from upstream's own `.deb`, pinned by version and sha256 in
`config/desktop/devpod.env` and unpacked by `build/scripts/51-devpod.sh`. Remove
`sh.loft.devpod` from `config/desktop/system-flatpaks.list`.

**And treat it as provisional.** `build/validation/check-devpod.sh` warns in CI
when upstream's newest stable release is more than a year old — which it does
today, at 555 days. That warning is the trigger to revisit this ADR, not
something to silence.

### It is the cleanest of the four vendor packages

The three before it are electron-builder output and all needed the same
handling: relocate out of `/opt`, rewrite `Exec=`, skip a postinst that decides
a setuid bit from the build environment. DevPod needs none of it.

* The payload is **already a `/usr` tree** — `usr/bin`, `usr/share`. Nothing to
  relocate, nothing to recreate at boot.
* It ships **no maintainer scripts at all**. There is no privilege decision to
  skip and no setuid assertion to make afterwards.
* Its launcher is **left exactly as upstream wrote it**. Both binaries have a
  space in the name (`/usr/bin/DevPod Desktop`), and the desktop entry is
  self-consistent about it (`Exec="DevPod Desktop"`, `Icon=DevPod Desktop`,
  matching `DevPod Desktop.png` in the icon theme). Renaming for tidiness would
  mean rewriting the entry and risking the window-to-launcher association GNOME
  derives from `WM_CLASS` and the `Exec` basename. The build asserts instead
  that the entry resolves — which catches the real risk, upstream renaming the
  binary in a release nobody reads the changelog of.
* One thing **is** added: `/usr/bin/devpod` as a symlink to `devpod-cli`. The
  `.deb` uses that name because the desktop app looks for it, while every
  DevPod instruction ever written says `devpod`.

It is still unpacked rather than `dpkg -i`'d, for consistency with the other
three and because installing would write to the dpkg database that
`95-finalize.sh` then has to relocate.

### The dependency it brings

DevPod Desktop is **Tauri**, not Electron: it renders through the system WebKit
instead of a bundled Chromium. That needs `libwebkit2gtk-4.1-0`, which the image
did not have — it already carries `libwebkitgtk-6.0-4` for GTK4, pulled in by
GNOME, so this is a **second, older build of the same engine** (~126 MB with its
JavaScriptCore) existing for one application.

That is the honest cost, and it comes with the one genuine advantage DevPod has
over the Electron three: **its renderer is Debian's**, so it gets Debian's
security updates whether or not upstream ever ships again. A frozen Electron app
carries a frozen Chromium; a frozen Tauri app does not.

## Consequences

**The sandbox is gone**, as with the others. DevPod drives Docker and SSH to
remote machines, so its blast radius was never really contained by a Flatpak
sandbox anyway — the Flathub build needed broad filesystem and socket access to
do its job.

**+240 MB in the image**: ~114 MB of DevPod (an 86 MB Go CLI and a 33 MB Tauri
binary) and ~126 MB of the GTK3 WebKit.

**If the GUI is not worth that, the CLI alone is a two-line change.** Everything
DevPod does is `devpod up`, `devpod ide`, `devpod provider`; the desktop app is a
workspace manager on top. Installing only `usr/bin/devpod-cli` drops both the
33 MB binary and the entire 126 MB WebKit dependency. That is the obvious move
if `check-devpod.sh` is still warning about upstream a year from now and nobody
has opened the GUI.

**There is no fleet to clean up.** Nothing has been installed from this image at
the time of this decision, so removing the id from the list is the whole of the
change: a first install gets the `.deb` and nothing else. A Bluefin machine
migrated in place keeps whatever is already in `/var/lib/flatpak`, because the
migration leaves `/var` alone; first boot will not reinstall the id now that it
is out of the list, but removing a leftover copy is manual
(`flatpak uninstall --system sh.loft.devpod`), and until it is done the launcher
shows two DevPods, one frozen at 0.6.10.

**This is the fourth `.deb`, and the pattern now needs a rule rather than an
ADR each time.** ADR 0016 said one does not make a pattern, and asked whether
the Flatpak is *missing* or merely *inconvenient*. Four applications later the
answers have been: end-of-life, absent, incompatible with company configuration,
and end-of-life again. A fifth should still be argued, but the honest summary is
that Flathub coverage for developer tooling is not what §54 assumed.

Revisit when `check-devpod.sh` warns, when DevPod appears on Flathub under any
id, or when upstream resumes stable releases — whichever comes first.
