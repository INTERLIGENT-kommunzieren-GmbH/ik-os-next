# ADR 0012 — First boot narrates on the normal boot animation, without a progress bar

**Status:** accepted
**Supersedes:** the splash mechanics in ADR 0010 (its per-image stamp decision stands)
**SDD:** §37

## Context

First boot ran `plymouth change-mode --updates` and drove that mode's progress
bar with `plymouth system-update --progress=N`.

That decision was made for the wrong reason. The first attempt used
`plymouth display-message` and produced a blank screen; the cause was
`SuppressMessages=true` in the theme's `[updates]` section, inherited from bgrt.
The conclusion drawn was "messages do not work, drive the bar instead" — but the
constraint belonged to the mode, not to Plymouth. Reading the themes upstream
ships makes it plain. In `bgrt.plymouth` and `spinner.plymouth`, both
`SuppressMessages` and `UseProgressBar` appear **only** under `[updates]`,
`[system-upgrade]`, `[firmware-upgrade]` and `[system-reset]`. Neither appears
under `[boot-up]`, `[shutdown]` or `[reboot]`.

The two modes are therefore exact opposites:

| mode      | loader animation | progress bar | `display-message` |
|-----------|------------------|--------------|-------------------|
| `boot-up` | yes              | no           | **renders**       |
| `updates` | no               | yes          | silently discarded |

So entering `updates` mode bought a progress bar at the price of the loader
animation *and* of every message. And the bar was a poor trade on its own: the
steps differ by orders of magnitude in duration — a Flatpak pull takes minutes,
the snakeoil certificate milliseconds — so a step-count percentage jumps and then
stalls, which is exactly what a progress bar is supposed to avoid.

## Decision

Never leave `boot-up` mode. Keep the normal loader animation, and write what is
happening onto it with `display-message`.

`ik-os-firstboot` shows two messages:

    Setting up this machine — do not turn off your computer     (constant)
    Installing applications (4 of 6): org.gnome.TextEditor      (changes)

Step labels live in the `STEPS` table beside the scope and command, so the table
remains the single source of truth. The long step names each app as it
downloads, because that is the one that previously sat on a single line for
minutes and read as a hang.

## Consequences

- **The loader keeps turning**, which is what a user expects a booting machine to
  look like. Nothing about the screen says "this boot is special" except the text.
- **No percentage to be wrong.** The count `(4 of 6)` is over *pending* steps, so
  it is accurate on a partial re-run, and it never claims to predict duration.
- **Replacing a line means hiding the old one.** Plymouth keys messages by their
  exact text — `--text=<string>` on both `display-message` and `hide-message` —
  and has no update verb. Without the hide, every step's line stays on screen and
  they pile up. `verify-image.sh` checks for the hide of the *detail* line
  specifically: the banner has its own hide, so a looser check passes with the
  important one deleted.
- **Whether both lines render at once is unverified.** The protocol clearly
  supports several messages, but whether `two-step` draws more than one could not
  be confirmed — gitlab.freedesktop.org is behind an anti-bot gate and the GitHub
  mirrors 404. The banner is displayed first and the detail after it, so if only
  the newest renders, the detail wins: informative, without the warning. It
  cannot degrade to a blank screen, which is the failure that mattered.
- **`[updates]` stays in the theme, upstream-equivalent.** Nothing in ik-os
  enters it, but something else might, and it should not then claim to be setting
  up the machine.
- **A `SuppressMessages=true` added to `[boot-up]` would silently blank every
  message** with no error anywhere — the original bug. `verify-image.sh` fails
  the build if it appears, and that check was confirmed by making the change and
  watching it fail.
- **The splash gate from ADR 0010 is untouched.** Messages appear on the first
  boot of an image; a quiet retry of an earlier failure stays silent.
