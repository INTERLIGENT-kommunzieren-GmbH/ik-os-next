# ADR 0011 — Post-login provisioning publishes state; a user unit renders it

**Status:** accepted
**SDD:** §16, §37; Rules 11, 15

## Context

Provisioning that needs a user account cannot be ordered by boot targets —
gnome-initial-setup creates the first account from inside the GDM session, long
after `multi-user.target`. `ik-os-homebrew.service` therefore fires from
`ik-os-homebrew.path` on `PathChanged=/etc/passwd`, and installs Homebrew plus
the company Brewfile while the user is at their desktop. It takes minutes and
downloads hundreds of megabytes.

It tried to say so. `ik-os-homebrew` opened with
`notify low "Setting up developer tools"`, and nobody ever saw it, because
`ik-os-notify` began:

    [[ -S "/run/user/${uid}/bus" ]] || exit 0

The path unit fires when the account is **created**, which is before that
account has logged in and therefore before it has a session bus. The opening
message was discarded every single time. Minutes later the user was logged in,
so only the closing "Developer tools ready" toast landed — the machine appeared
to do nothing at all and then announce that it had finished.

`ik-os-user-groups` had the identical bug for the same reason: its "Sign out to
finish setup" notification fires on the same trigger and was equally lost.

A system service pushing UI into a session that may not exist yet is the wrong
shape. And a toast is the wrong medium regardless: it cannot show progress, and
"do not reboot" needs to be visible for the whole several minutes, not for the
four seconds a banner is on screen.

## Decision

Invert it. The system service **publishes state**; a **user unit inside the
graphical session renders it**.

- `/run/ik-os/provisioning.status` — `state`, `phase`, `detail`, `current`,
  `total`, written atomically. tmpfs, so it resets each boot. Named generically:
  `ik-os-user-groups` and first-boot retries are the obvious next writers.
- `ik-os-provisioning.service` — a **user** unit, `WantedBy=graphical-session.target`,
  running `ik-os-provisioning-monitor`. Being a user unit is the point: systemd
  hands it the session's display and bus, so there is no environment to guess at
  and nothing to miss, however late the session starts.
- The UI is a **zenity progress window**, driven through zenity's own stdin
  protocol — a bare number sets the percentage, a `#`-prefixed line replaces the
  text — so ik-os ships no GTK code.

Separately, the Brewfile is applied **only when `brew bundle check` says it is
unsatisfied**, with `HOMEBREW_NO_AUTO_UPDATE=1` so the check is local.

## Consequences

- **A release that adds a Brewfile entry installs it automatically, and is now
  seen.** The service already ran on every boot and applied the Brewfile
  unconditionally; what it never did was say so. An update boot used to download
  a new cask in complete silence.
- **A settled machine does nothing and shows nothing.** `bundle check` is local
  and fast, so a boot with a satisfied Brewfile costs no network and no window.
  This also removed a `brew update` round trip from every boot.
- **`bundle check`, not a Brewfile-hash stamp.** ADR 0010 keys first-boot steps
  to the image because their work is not cheaply observable. Homebrew's is: the
  check *is* the question, and it self-heals a package the user removed by hand,
  which a hash stamp would never notice.
- **A repeated failure retries silently.** `/var/lib/ik-os/homebrew/failed-for`
  records which Brewfile last failed; unchanged, the work still runs but
  publishes `running-quiet` and no window appears. Otherwise a cask that can
  never install would put a progress window on screen at every login forever —
  the same split ADR 0010 makes for the boot splash.
- **The window informs; the inhibitor protects.** `--no-cancel` removes the
  button but the window is still closeable, and closing it does not interrupt
  anything. The existing `systemd-inhibit --what=shutdown` in
  `ik-os-homebrew.service` is what actually makes GNOME warn before a reboot.
- **A first boot pulsates rather than showing a percentage.** `--pulsate` cannot
  be toggled on a live dialog, and relaunching zenity to switch modes reads as
  "it finished", so the mode is fixed from the first state seen — which on a
  first boot is the Homebrew bootstrap, one opaque clone with no countable steps.
  The text still carries "(3 of 9)" once the bundle starts. An update run has no
  bootstrap and gets a real percentage.
- **User units are enabled with a baked `.wants` symlink**, not a preset. A user
  preset only applies if `systemctl --user preset-all` runs for that account, and
  nothing guarantees it ever does. `/usr/lib/systemd/user/<target>.wants/<unit>`
  is how pipewire enables itself and works from the first login.
- **`zenity` is a new dependency** — 2 packages measured against the image's dpkg
  database. `verify-image.sh` checks it is present, because a renderer whose UI
  binary is missing fails silently at runtime on the user's machine.
- **Removals are still not applied.** `brew bundle install` never uninstalls an
  entry dropped from the Brewfile; that needs `brew bundle cleanup`. The company
  baseline only grows. Not addressed here.
