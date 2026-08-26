# ADR 0014 — Bazaar and Mission Center are baked into the image

**Status:** accepted
**SDD:** §15, §37, §54; Rules 4, 15
**Supersedes nothing.** Narrows one invariant asserted by `verify-image.sh`.

## Context

SDD §15 installs the approved Flatpak list at first boot, from Flathub. That was
uncontroversial while the list held four applications. It now holds 58, which is
~6.7 GiB of applications over six runtimes — roughly 12 GB of download against
`ik-os-firstboot.service`'s `TimeoutStartSec=15min`, which also holds GDM.

The step is idempotent and fails open: on timeout the unit is killed, GDM starts,
and the unfinished apps retry on the next boot (ADR 0010, ADR 0012). Nothing
breaks. But it means the *normal* first boot of a new machine now ends with the
Flatpak step incomplete, and until it finishes there is:

* no application store — so no way to install anything, and no way to see why;
* no task manager, because `gnome-system-monitor` was removed from the image
  when Mission Center replaced it (ADR 0013).

A machine with no network on first boot has neither, indefinitely.

## Decision

Install a short list of Flatpaks into `/var/lib/flatpak` at build time and copy
it into the image. `config/desktop/preinstalled-flatpaks.list` holds the subset;
`config/desktop/system-flatpaks.list` remains the definition of the approved
desktop, and every preinstalled id must also appear there.

Two applications qualify:

    io.github.kolunmi.Bazaar          the store — the way out of any other gap
    io.missioncenter.MissionCenter    the task manager the image no longer has

The apps themselves are 22 MB and 34 MB. Their runtime stack —
`org.gnome.Platform` 50, the two `org.freedesktop.Platform.GL.default`
branches, codecs and locales — is ~2.4 GB and is the entire cost. It is also
shared by 37 of the 58 applications, so paying it here removes it from every
first boot as well: ~12 GB becomes ~9.5 GB.

It runs in a dedicated Containerfile stage, for the same reason bootc does: a
2.4 GB download must not repeat when an unrelated build script changes.

## Consequences

The image grows from ~4.5 GB to ~7 GB. That is paid once per image on the
registry side and per `bootc upgrade` only when the layer actually changes.

**This narrows a stated invariant.** `verify-image.sh` asserted `/var` was empty
of package state, because `/var` is machine-local: bootc applies the image's
`/var` at install time and never again, so anything there is applied once and
then drifts. `95-finalize.sh` exists to move package `/var` state into
`tmpfiles.d` and `/usr/share/factory` for exactly this reason.

A Flatpak has nowhere else to be installed. So the check now permits
`/var/lib/flatpak` **by name** and still fails on any other directory — the
invariant is narrowed, not removed.

The consequence of `/var` semantics is that preinstallation reaches machines
**installed** from this image, not machines upgraded in place: an existing
machine keeps its own `/var/lib/flatpak`. That is correct rather than
unfortunate — those machines already have the apps — and `ik-os-firstboot` is
per-image (ADR 0010), so it installs anything genuinely missing.

Preinstalled apps update through `flatpak update` like any other, since they land
in the normal writable system installation. They are not pinned to the image.

Two build-time caveats, both asserted rather than assumed:

* `bwrap` cannot create a namespace in a rootless build container, so flatpak's
  post-install triggers (desktop, mime and icon caches) fail with a warning. The
  `exports` symlinks are created by flatpak itself and are what the shell reads,
  so the applications appear; the caches are regenerated the first time flatpak
  installs anything on the machine. The build fails if a `.desktop` export is
  missing, because "installed but invisible" is the failure mode that warning
  could plausibly cause.
* ostree writes objects through `O_TMPFILE` in `TMPDIR`. A build container has no
  `/var/tmp`, and the resulting error — `open(O_TMPFILE): No such file or
  directory` — reads like a filesystem that cannot do `O_TMPFILE` and sends you
  looking at overlayfs. The script creates the directory.

## Alternatives rejected

**Reorder the first-boot list** so these two install first. Free, and it does
shorten the window, but it does not close it: a machine without network still
has no store and no task manager.

**A read-only extra installation under `/usr`**, declared through
`/etc/flatpak/installations.d`. Properly image-managed, updated by
`bootc upgrade`, and no `/var` exception needed. Rejected because
`flatpak-installation(5)` has no `ReadOnly` key — the mechanism is undocumented
for this use, and the apps could then only be updated by rebuilding the image.

**Raise `TimeoutStartSec`.** Addresses the timeout, not the offline case, and
holds the login screen for longer to do it.
