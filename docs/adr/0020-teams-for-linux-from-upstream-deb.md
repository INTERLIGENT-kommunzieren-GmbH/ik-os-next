# ADR 0020 — Teams moves off Flathub so the company video backgrounds can exist

**Status:** accepted
**SDD:** §14, §15, §24, §50, §53, §54; Rules 4, 17, 18
**Follows:** [ADR 0016](0016-drawio-from-upstream-deb.md),
[ADR 0019](0019-sidra-from-upstream-deb.md)

## Context

The company wants its own video backgrounds available in Teams on a new machine,
without anyone uploading a file.

Microsoft ships no Linux client, so the client this image ships is
[teams-for-linux](https://github.com/IsmaelMartinez/teams-for-linux), an
Electron wrapper around the web app — until now as a Flathub id in
`system-flatpaks.list`, as §54 requires.

Teams builds the background picker itself and offers **no way to add to it**.
Three mechanisms were tried against a running client:

1. `teams-for-linux`'s own custom-background list. Dead: nothing has consumed
   the `get-custom-bg-list` IPC since 2.x, and the list never reaches the picker.
2. The documented service manifest, `{"videoBackgroundImages": [...]}`. The app
   throws *"configJSON is not iterable"* — it iterates whatever it parses, so the
   manifest has to be a bare JSON **array**.
3. Redirecting the image requests. `teams-for-linux` rewrites every URL under
   `statics.teams.cdn.office.net/evergreen-assets/backgroundimages/` to
   `customBGServiceBaseUrl`. **This one works** — a company background reaches
   the picker by being served *in place of* one of Microsoft's own assets.

Two further facts came out of the same testing, and each is a line of code:

* Responses must carry `Access-Control-Allow-Origin`. The picker draws the
  chosen image into a canvas, so without it Teams fetches the image and then
  silently refuses to apply it. The background never changes and nothing is
  logged.
* The redirect catches *all* of Microsoft's assets, not only the ones this image
  replaces. Without a proxy for the rest, the picker becomes a grid of empty
  tiles — the feature would break the UI it extends.

So the mechanism requires `customBGServiceBaseUrl` to be set. That setting lives
in `/etc/teams-for-linux/config.json`, and **a Flatpak can never read it**:
flatpak refuses to share `/etc` with a sandbox (`Path "/etc" is reserved by
Flatpak`), and `/usr` likewise.

## Decision

Install teams-for-linux from upstream's own `.deb`, pinned in
`config/desktop/teams-for-linux.env` and unpacked by `build/scripts/54-teams.sh`;
remove `com.github.IsmaelMartinez.teams_for_linux` from
`config/desktop/system-flatpaks.list`. Serve the company backgrounds from
`ik-os-teams-backgrounds.service` on `127.0.0.1:8421`, which answers for the
Microsoft asset names listed in `branding/teams-backgrounds/slots.txt` and
proxies everything else back to Microsoft's CDN.

Packaging follows ADR 0016 exactly — same `/opt` relocation into
`/usr/lib/teams-for-linux`, same skipped maintainer scripts and the same setuid
assertion, same transcribed `Depends` with an `ldd` check. Two things are
specific to this application:

* **The launcher loses `--ozone-platform=x11`.** Upstream's `.desktop` forces
  it, which would put the client on XWayland on this Wayland-first image: blurry
  under fractional scaling, and screen sharing loses the portal path. It becomes
  `--ozone-platform-hint=auto`.
* **Client defaults ship in `/usr` and reach `/etc` through tmpfiles**, the way
  `cupsd.conf` does (`65-printing.sh`), so the image carries no `/etc` file to
  three-way merge on every update. The app merges the user's own
  `~/.config/teams-for-linux/config.json` over them, user keys winning, so these
  are defaults and not locks (§53).

### The alternative that was not taken

The Flatpak could have been kept and its config seeded per user, into
`~/.var/app/com.github.IsmaelMartinez.teams_for_linux/config/teams-for-linux/`,
from the post-login provisioning that already exists (ADR 0011). That keeps the
sandbox and Flathub's update cadence, which is not nothing.

It was rejected because it makes a company default into per-user state: it
applies only to accounts that existed when provisioning ran, it cannot be
changed by publishing a new image, and a user whose file already exists silently
never gets it. The configuration would stop being image-owned, which is the
property this image is built around.

That trade is worth re-examining if the sandbox loss below proves to matter more
than the declarative default.

## Consequences

**The sandbox is gone, and this is a worse place to lose it than draw.io.**
Teams renders untrusted remote content continuously and has a microphone, a
camera and the screen. Flatpak confined it; a `/usr` install does not. Nothing
in this decision improves on that — the mitigations are the same as ADR 0016's
(it is an ordinary binary, so `firejail` or a systemd unit could confine it) and
none of them are in place.

**Teams now updates on the image cadence.** It used to update itself from
Flathub. `scripts/maintenance/update-teams-for-linux.sh` moves the pin and
`build/validation/check-teams-for-linux.sh` warns in CI when upstream is ahead.
Of the three pinned `.deb`s this is the one to move promptly.

**One listening port is added** — `127.0.0.1:8421`, the first this image opens
beyond CUPS. §50 wants no unnecessary listening ports, so: it is loopback-only
(asserted in `verify-image.sh`), it runs `DynamicUser` with an empty capability
set and `ProtectSystem=strict`, and it serves static files out of `/usr` plus a
proxy to one CDN.

**The service proxies to Microsoft on the user's behalf.** Every picker tile
this image does not replace is fetched by the service rather than by the client.
That is the same data going to the same CDN, but it now leaves from a system
service instead of the application.

**This costs no migration today, because nothing is deployed.** At the time of
this decision ik-os-next is Pre-M1 and has never been installed on a machine, so
there is no fleet holding the Flatpak and no cleanup to schedule. A first
install gets the packaged client and only that.

The one path that can still produce two Teams entries is a Bluefin machine
migrated in place with `ik-os-migrate`. It runs `bootc install
to-existing-root`, which leaves `/var` alone — that is what preserves `/home` —
so a Flatpak already in `/var/lib/flatpak` survives the migration. First boot
will not reinstall it, because the id is gone from `system-flatpaks.list`, but
it will not remove it either:

```bash
flatpak uninstall --system com.github.IsmaelMartinez.teams_for_linux
```

For anyone in that position the profile also moves, from
`~/.var/app/com.github.IsmaelMartinez.teams_for_linux/config/teams-for-linux` to
`~/.config/teams-for-linux`; copying it across keeps the session, otherwise it is
a fresh sign-in. That is in `/usr/share/doc/ik-os/teams-backgrounds.md` on the
machine itself, because that is where someone looking at two Teams icons will
actually be.

**+338 MiB in the image** (108 MiB compressed), an Electron runtime shared with
nothing.

**The backgrounds carry Microsoft's names internally.** A user who picks the
office photograph has `teamsBackgroundContemporaryOffice01` recorded by Teams.
The picker shows no captions, so it is invisible in use, but it is why a
retired Microsoft asset name makes a company background disappear —
`journalctl -u ik-os-teams-backgrounds` lists the names the client actually
asks for, and `slots.txt` is where the dead one is replaced.

Revisit if teams-for-linux gains a way to read configuration from a path a
Flatpak may see, or if Teams itself ever accepts an added background.
