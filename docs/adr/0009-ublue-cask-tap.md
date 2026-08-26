# ADR 0009 — Framework tooling and JetBrains Toolbox from the ublue-os cask tap

**Status:** accepted
**SDD:** §16, §54; Rules 4, 5, 11, 15, 17

## Context

SDD §54 gives a decision hierarchy for where software lives:

    GUI application            --> Flatpak
    CLI developer tool         --> Homebrew
    Hardware/system integration --> OS image

Two requested packages do not fit cleanly.

**`framework-tool`** reads and configures Framework laptop EC state (battery
charge limits, fan curves, firmware info). By §54 that is "hardware/system
integration", which points at the OS image. But it is a vendor binary released
on GitHub with no Debian package, and Rule 5 keeps arbitrary vendor binaries out
of `/usr`. Putting it in the image would also mean re-pinning and rebuilding the
whole OS for a tool that only matters on one hardware line.

**`jetbrains-toolbox-linux`** is a GUI application, which §54 routes to Flatpak.
JetBrains publishes no official Flatpak. IDEs also run badly from one: they need
to drive toolchains, containers and the Docker socket outside the sandbox, which
is most of what a Flatpak is for. Bluefin — the image ik-os reimplements — makes
the same call and ships it from this tap.

Both are packaged as **casks** in `github.com/ublue-os/homebrew-tap`, which
Homebrew addresses as `ublue-os/tap` (it strips the `homebrew-` prefix).

## Decision

Add `tap "ublue-os/tap"` to the company Brewfile and install both as casks.

This keeps them in userspace under `/home/linuxbrew`, where Homebrew already
lives per SDD §16, and out of the immutable host. Neither is a kernel, systemd,
bootloader, core library or security-critical host package, so Rule 4 is
unaffected.

## Consequences

- **Supply chain.** Each cask pins an upstream `sha256` and fetches from the
  vendor's own origin — `github.com/FrameworkComputer/...` and
  `download.jetbrains.com`. Trusting the tap means trusting those vendors plus
  ublue-os's packaging metadata, not an opaque third-party binary channel.
- **The tap is explicitly a staging area.** Its own README calls it a place "to
  test Linux casks" whose "metric of success is when the applications in here
  are deleted", i.e. upstreamed into homebrew/cask. Expect these entries to move
  and re-point the Brewfile when they do.
- **The tap must be trusted, per user.** Homebrew refuses to load a cask from a
  third-party tap until `brew trust <tap>` has been run, recording it in
  `~/.homebrew/trust.json`. `brew bundle` does not do this for you and reports
  overall success regardless, so an untrusted tap means the casks silently never
  install. `ik-os-homebrew` therefore trusts every tap the Brewfile declares,
  as the user, before running the bundle. Note `just check-brewfile` cannot
  catch this: the entries resolve correctly against the tap: it is a runtime
  trust decision, not a naming error.
- **The tap must be cloned before the bundle runs.** `brew bundle` evaluates
  each cask before processing the `tap` line that provides it, so on a machine
  where the tap is not yet on disk the cask is skipped as `requires macOS` and
  the run still reports success. `ik-os-homebrew` taps explicitly first and
  checks with `brew bundle check` afterwards.
- **Casks, not formulae.** `brew "ublue-os/tap/framework-tool"` does not
  resolve. The Brewfile says `cask`, and anything added from this tap later must
  be checked against `Casks/` versus `Formula/` in the repository.
- **`$HOME` must be set.** The JetBrains cask writes a `.desktop` file into
  `$HOME/.local/share/applications`, so first boot runs `brew bundle` under
  `sudo -H`.
- **framework-tool installs only on Framework hardware.** A Brewfile is Ruby, so
  the entry is guarded by a `sys_vendor`/`chassis_vendor` check — the same
  condition Bluefin applies in its `20-framework.sh` user-setup hook. Missing DMI
  files (VMs, containers) evaluate to false rather than raising.
- **The cask token is `framework-tool`, with a hyphen.** Bluefin's hook asks for
  `ublue-os/tap/framework_tool`, which does not exist in the tap — their
  Framework install is currently a silent no-op. Do not copy that spelling.
- **JetBrains Toolbox is installed for everyone**, not offered as an opt-in
  command. Bluefin once had an `install-jetbrains-toolbox` ujust recipe; it is
  gone from their current tree, and IDEs now come from this tap instead. ik-os
  installs it by default because it is standard company tooling.
- Neither package is validated by the image build — Homebrew runs on first boot,
  by design (SDD §16), so a broken cask surfaces there and is reported by
  `ik-os diagnostics`, not by `just verify`.
