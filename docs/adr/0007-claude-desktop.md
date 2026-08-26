# ADR 0007 — Claude Desktop from Anthropic's own APT repository

**Status:** accepted — supersedes the first draft of this ADR
**SDD:** §54, §15, §45, §46; Rules 4, 11, 15, 17

> **Corrected.** The first version of this ADR stated that Claude Desktop was
> "a third-party repackaging of a proprietary application, not an
> Anthropic-published artefact", and installed it from a GitHub release of the
> community `aaddrick/claude-desktop-debian` project. **That was wrong.**
> Anthropic ships a first-party Linux `.deb` from their own signed APT
> repository. The community project is real and useful — it repackages
> Anthropic's official `.deb` into `.rpm`, AppImage, Nix and AUR formats — but
> it is not the right source for a Debian image.

## Context

SDD §54's decision hierarchy sends GUI applications to Flatpak, and Rule 4
forbids installing applications into the immutable host when Flatpak, Homebrew
or a container would do.

Claude Desktop is a GUI application the fleet already uses — the Bluefin-based
`ik-os` installed it — and the Flatpak route is unavailable:

| Source | Status |
| --- | --- |
| Flathub | **not published** — `com.anthropic.claude`, `com.anthropic.Claude` and `io.github.aaddrick.claude-desktop` all 404 |
| Debian archive | **not packaged** |
| Anthropic's APT repository | **available**, first-party, signed |

Since Anthropic publishes the package themselves, Rule 17's preference for the
maintained upstream package applies directly.

## Decision

Claude Desktop is installed as an ordinary APT package from Anthropic's
repository, declared in `config/apt/claude-desktop.sources`:

    Types: deb
    URIs: https://downloads.claude.ai/claude-desktop/apt/stable
    Suites: stable
    Components: main
    Architectures: amd64 arm64
    Signed-By: /usr/share/keyrings/claude-desktop-archive-keyring.asc

`claude-desktop` then sits in `packages/desktop/packages.list` like any other
package, and `just check-packages` validates it against the real repository.

### The signing key is pinned and verified

The key is committed at `config/apt/keyrings/claude-desktop-archive-keyring.asc`
rather than fetched at build time, and `00-preflight.sh` verifies it against a
fingerprint pinned in `config/image.env` before configuring the repository:

    CLAUDE_DESKTOP_KEY_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
    uid: Anthropic Claude Code Release Signing <security@anthropic.com>

A swapped, corrupted, or rotated key fails the build with the expected and
actual fingerprints, instead of silently trusting whatever signed the packages.
This satisfies SDD §45's intent — verify what you install — for a repository
outside the Debian archive.

Set `CLAUDE_DESKTOP=false` to omit both the application and its repository.

## Consequences

- **Still a deviation from SDD §54**, allowed under Rule 15 because it is
  recorded here: a GUI application enters the immutable host because neither
  Flatpak nor Debian offers it. It applies to Claude Desktop only.
- **ik-os trusts one non-Debian APT repository.** It is the vendor's own, it is
  signed, and the key is pinned — but it is a second archive whose contents the
  project does not control, and every release now depends on it being reachable.
- Updates arrive with the OS image rather than through apt on the running host,
  because the host is immutable (SDD §40). The version is therefore tied to the
  image release cadence, and is recorded in `packages.manifest`.
- The repository is release-agnostic (`Origin: Anthropic`, `Suite: stable`), so
  it does not track the Debian codename the rest of `config/apt/` follows and
  survives the Debian 14 transition untouched.
- **If Claude Desktop appears on Flathub, revert this.** Move it to
  `config/desktop/system-flatpaks.list`, drop the repository, the keyring and
  the fingerprint check — that restores SDD §54 compliance and removes the
  third-party archive.
