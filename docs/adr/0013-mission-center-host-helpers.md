# ADR 0013 — Mission Center's privileged helpers live in the OS image

**Status:** accepted
**SDD:** §15, §54; Rules 4, 5, 15

## Context

`gnome-system-monitor` was dropped from the image and replaced by Mission Center
(`io.missioncenter.MissionCenter`), a Flatpak. SDD §54 routes GUI applications to
Flatpak, so the application itself is not in question.

Mission Center's advanced features are, because they need privileges a sandbox
cannot grant. On first run it offers to execute a setup script on the host
through `pkexec`. The script does four things:

    setcap "cap_net_admin,cap_net_raw,cap_dac_read_search,cap_sys_ptrace+pe" "$(which nethogs)"
    echo 'SUBSYSTEM=="powercap", ... chmod a+r /sys/%p/energy_uj' > /etc/udev/rules.d/99-powercap.rules
    udevadm control --reload-rules && udevadm trigger --subsystem-match=powercap
    sensors-detect --auto

On ik-os it cannot succeed, and it fails in a way that looks like a broken
machine: a dialog titled **Setup Script Failed**.

1. `setcap` writes an xattr on the binary. `/usr` is read-only, so this fails
   with `EROFS`. `bootc usr-overlay` would make it writable transiently, and the
   capability would then disappear on the next reboot — worse than not working,
   because it works until it doesn't.
2. `nethogs` and `sensors-detect` were not in the image at all. `nethogs` was in
   the Brewfile, but Homebrew installs to `/home/linuxbrew/.linuxbrew/sbin`,
   which appears on no root `PATH` — so the script reported it missing even on a
   machine that had it. It also cannot carry file capabilities usefully: the app
   resolves the binary on a `PATH` it hardcodes for its subprocesses
   (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin`),
   which contains no Homebrew prefix.

Two options were rejected:

**Let the user run the script.** It cannot work, for the reason above. Retrying
it produces the same dialog on every laptop.

**Copy `nethogs` into `/usr/local/sbin`** (which is `/var/usrlocal`, writable and
first on that `PATH`) so `setcap` succeeds at runtime. This makes the script work
and is the wrong trade: an unmanaged binary in `/var` that shadows the image's
copy forever and is never updated by a `bootc upgrade`. Rules 4 and 5 exist to
prevent exactly this.

## Decision

Ship the helpers and their configuration in the OS image, and answer the
first-run prompt in advance:

* `nethogs` and `lm-sensors` as Debian packages
  (`packages/desktop/packages.list`).
* The capability set applied at build time by `build/scripts/50-desktop.sh`, so
  it is part of the ostree commit rather than machine-local state.
* The powercap udev rule shipped as `/usr/lib/udev/rules.d/99-powercap.rules`,
  byte-identical to the app's own, so a user who runs the script anyway gets an
  identical `/etc` copy instead of a second, conflicting rule.
* `first-time-running=false` seeded through `/etc/skel`, because a Flatpak
  without dconf access stores its GSettings in a per-app keyfile and cannot be
  reached by the dconf defaults every other setting in this image uses.

`sensors-detect --auto` is deliberately NOT reproduced. It writes
`/etc/modules-load.d/lm_sensors.conf`, and on the target hardware nothing needs
it: the sensor modules for the Framework 13 (`k10temp`, `cros_ec_hwmon`) are
autoloaded from ACPI and PCI ids, which is why `sensors` already reports the full
set of hwmon devices without it.

## Consequences

Per-process network usage, CPU power draw and fan/temperature readings work on a
fresh machine with no user action, and no dialog appears.

This puts two monitoring tools in the immutable host. Rule 4 forbids non-OS
software there, and these qualify as OS-level: a binary with file capabilities is
by definition privileged host tooling, and it is the *only* place a capability
can be granted on this system. The GUI stays in Flatpak, which is what §54 is
actually about.

`nethogs` is now in the image and no longer in the Brewfile. Keeping both would
put the copy *without* capabilities first on the user's `PATH` — the one that
cannot capture.

The seeded keyfile is the weak part. It is the app's private state, so a renamed
key would silently stop suppressing the dialog, and it cannot be validated at
build time because the schema defining it ships inside the Flatpak. The failure
mode is one cosmetic dialog, not a broken feature: everything the script would
have configured is already in place.
