# Teams video backgrounds

Each background is committed here **twice**: `ik-<name>.jpg` at 1920x1080 and
`ik-<name>-thumb.jpg` at 280x158, which are the sizes Teams wants for the
background itself and for the tile in the picker. `build/scripts/54-teams.sh`
installs both to `/usr/share/ik-os/teams-backgrounds/` as they are.

They are committed already rendered rather than resized during the build,
because resizing at build time would mean shipping ImageMagick in every image
for a step that runs once per new photograph. `scripts/maintenance/render-teams-backgrounds.sh`
is what produces the pair.

## How they reach the picker

Teams builds the background picker itself and offers no API for adding to it.
What `teams-for-linux` can do is redirect every request Teams makes for
`statics.teams.cdn.office.net/evergreen-assets/backgroundimages/…` to a local
service. A company background therefore appears by being served **in place of
one of Microsoft's own assets** — the names listed in `slots.txt`, matched to
the images in sorted order.

Everything not listed in `slots.txt` is proxied straight back to Microsoft by
`ik-os-teams-backgrounds.service`, so the rest of the picker looks untouched.
Without the proxy you get a grid of empty tiles instead: the redirect catches
*all* of Microsoft's assets, whether this image has a replacement or not.

One consequence worth knowing: the tiles keep Microsoft's names internally. The
picker shows no captions, so it is invisible in use, but a background someone
selects is recorded by Teams as e.g. `teamsBackgroundHome`.

The reasoning, and why Teams is no longer a Flatpak, is in
[ADR 0020](../../docs/adr/0020-teams-for-linux-from-upstream-deb.md).

## Adding or replacing one

    scripts/maintenance/render-teams-backgrounds.sh ~/Pictures/ik-kitchen.png

That writes both files here. Keep the `ik-` prefix: the manifest strips it to
build the display name, so `ik-window-view` becomes "Window View".

Any aspect ratio works — sources are scaled to cover and centre-cropped, so put
the subject in the middle. The current set came from 1680x1120 (3:2) originals,
which lose a little off the top and bottom; exporting at 16:9 avoids that.

Each image takes over one Microsoft asset name, so add a spare to `slots.txt`
when they run out. The build fails when there are fewer slots than images
rather than installing one that can never be seen.

## If an image stops appearing

Microsoft retired the asset name it was mapped to.

    journalctl -u ik-os-teams-backgrounds

logs every asset Teams asks for, marked `ik` (served from this image) or `ms`
(proxied). Pick a live name from that log and replace the dead line in
`slots.txt`.
