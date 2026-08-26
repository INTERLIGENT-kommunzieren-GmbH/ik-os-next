# Desktop wallpapers

Every image in this directory is installed to `/usr/share/backgrounds/ik-os/`
and registered in `/usr/share/gnome-background-properties/ik-os.xml`, so all of
them appear in **Settings → Appearance → Background**.

The one a new account starts with is named in `config/image.env`:

    IK_OS_DEFAULT_WALLPAPER=ik-hubble.jpg

It is a *default*, not a locked setting — developers may pick any of the others
(SDD §53). The build fails if the named file is not present, so renaming a
wallpaper cannot silently fall back to a different one.

## Adding or replacing

Drop the file in, and if it should become the new default, update
`IK_OS_DEFAULT_WALLPAPER`. Display names are derived from the filename:
`ik-winter-forest.jpg` becomes "Winter Forest". Keep the `ik-` prefix.

Target 2560x1440 or larger; the current set is all 2560x1440. The whole set
adds about 38 MB to the image.

## Note

This directory deliberately has no fallback to the company logo. An earlier
version of the build used the logo as the wallpaper when no asset was present,
and every desktop came up with a 1.5 KB logo stretched across the screen.
