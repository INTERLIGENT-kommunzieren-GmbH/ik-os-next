# ADR 0010 — First boot is per image, and the setup splash is gated on the image

**Status:** accepted
**SDD:** §37, §38; Rules 1, 13

## Context

`ik-os-firstboot` recorded each completed step as an empty stamp file under
`/var/lib/ik-os/firstboot/`. Two things follow from that, and both turned out to
be wrong.

**The stamps never expire.** `/var` survives a bootc update — it is wiped and
re-created at install, not at every deployment. So an image that added a Flatpak
to `system-flatpaks.list`, or shipped a new VPN template, never applied either:
the step was stamped done on the machine's very first boot and skipped forever
after. The machine reported a clean first boot while quietly keeping the
configuration it was installed with. This is the same failure shape as the
Homebrew `RemainAfterExit` bug and the swallowed Flatpak errors — a step that
reports success while doing nothing.

**The splash ran unconditionally.** The script called `splash_begin` before
reading a single stamp, so every boot flipped Plymouth into the theme's
`[updates]` mode and displayed *"Setting up this machine — This happens once. Do
not turn off your computer."* The message was a lie on boot two onward, and the
one it tells — do not reboot — is exactly the instruction that stops meaning
anything when it is repeated on a machine that is already set up.

## Decision

Steps declare a **scope**, and the splash is gated on the **image**, not on
whether work exists.

    once   snakeoil                  machine-local state a new image cannot invalidate
    image  enrollment, vpn, flatpak, inputs ship in the image, or the step reports
           verify-docker, verify-cups the current image to something that cares

An `image`-scoped stamp records the image id it was satisfied on; a different id
makes the step pending again. `/var/lib/ik-os/firstboot/.last-run-image` records
the image the last full run happened on, and the splash appears only when the
booted image differs from it.

Enrollment is `image`-scoped deliberately: SDD §38 has the payload carry
`os_version` and `image_digest`, which are only meaningful if the backend hears
about a new image.

## Consequences

- **The setup screen appears on a machine's first boot and on the first boot
  after each image update, and at no other time.** That is the whole point.
- **A step that failed earlier retries quietly.** Work can be pending on any
  boot; being *shown* it is reserved for a new image. Without that split, a
  machine that can never reach Flathub would display the setup screen on every
  boot for the rest of its life — the exact symptom this ADR removes.
- **The image id is a runtime value**, read from `bootc status`, falling back to
  the ostree deployment checksum in `/proc/cmdline`, then `VERSION_ID`. The
  build-time identifiers are unusable here: `IK_OS_VERSION` defaults to `dev`
  and `IK_OS_BUILD_ID` to `local`, so every locally built image shares a string
  and a test VM would never re-provision — the bug would survive precisely where
  it gets tested. `just build` now passes a real
  `<channel>.<YYYYMMDD>.<build>` version, but that does not make it usable as the
  detector either: it is date-based, so two builds on the same day still share
  it. The digest remains the only value that is unique per image.
- **Re-enrolling touches `ENROLLMENT_URL` on update boots.** Safe by
  construction: `ENROLLMENT_ENABLED` defaults to false and a failed step never
  propagates, so an unreachable backend leaves a `.failed` stamp and a
  diagnostics entry rather than a stalled boot.
- **Steps must be idempotent across images, not just across boots** (SDD §37
  already requires this). `verify-*` are read-only, `snakeoil` returns early when
  the key exists, `vpn` rewrites the same connection file, and `flatpak` uses
  `--or-update`.
- **Existing machines self-heal.** A legacy stamp is empty, which reads as
  unknown provenance, so the first boot after this change re-runs the
  `image`-scoped steps once and then settles.
- **`ik-os-firstboot.service` keeps `Before=gdm.service plymouth-quit.service`
  unconditionally.** systemd resolves ordering before the unit runs, so no
  in-script guard can remove that edge; a no-work run exits in milliseconds
  instead. The residual cost is that GDM stays ordered behind
  `network-online.target` on every boot. If that ever measures as real time
  (`systemd-analyze critical-chain gdm.service`), the fix is to split the
  blocking ordering into its own unit — not worth doing speculatively.
- **`STEP_TOTAL` is the count of pending steps.** It used to be hardcoded to 6
  while skipped steps did not advance the bar, so a five-of-six re-run drove it
  to 1/6 and then jumped to full. The progress bar itself is gone — ADR 0012
  replaced it with messages on the normal boot animation — but the count still
  feeds the "(4 of 6)" in those messages, and being over *pending* steps is what
  makes it honest on a partial re-run.
