#!/bin/bash
# Render company photographs into the Teams background pair the image ships
# (ADR 0020).
#
# Teams wants ~1920x1080 for the background itself and ~280x158 for the tile in
# the picker. branding/teams-backgrounds/ therefore holds BOTH, already cropped
# and encoded, and build/scripts/54-teams.sh installs them as they are. The
# alternative — resizing during the image build — would put ImageMagick in every
# shipped image for a step that runs once per new photograph.
#
# Sources can be any aspect ratio: they are scaled to cover and centre-cropped,
# so put the subject in the middle.
#
# Usage:  scripts/maintenance/render-teams-backgrounds.sh IMAGE [IMAGE...]
#
# The output name is the source basename, lowercased, and it must start with
# "ik-" so the manifest's display name comes out right ("ik-window-view" ->
# "Window View").
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DEST="${REPO}/branding/teams-backgrounds"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

(( $# )) || die "usage: $(basename "$0") IMAGE [IMAGE...]

       Renders each image to ${DEST}/<name>.jpg (1920x1080) and
       <name>-thumb.jpg (280x158). The image does not ship ImageMagick, so run
       this on a checkout with it installed, not on an ik-os machine."

command -v magick >/dev/null \
    || die "ImageMagick (the 'magick' command) is required and is not installed.
       This is a maintainer's tool, and ImageMagick is deliberately not in the
       image -- see the comment at the top of this script."

[[ -d "$DEST" ]] || die "no ${DEST} — is REPO=${REPO} the ik-os-next checkout?"

for src in "$@"; do
    [[ -r "$src" ]] || die "cannot read ${src}"
    name=$(basename "$src"); name="${name%.*}"; name="${name,,}"

    [[ "$name" == ik-* ]] || die "'${name}' does not start with ik-.
       The manifest strips that prefix to build the display name, so a file
       without it appears in the picker under a name nobody recognises."
    [[ "$name" == *-thumb ]] && die "'${name}' ends with -thumb, which is the
       suffix this script generates. Rename the source."

    log "Rendering ${name}"
    # -resize ^ scales to COVER the geometry, then -extent crops the overflow
    # about the centre; without the ^ the image is letterboxed instead.
    magick "$src" -resize 1920x1080^ -gravity center -extent 1920x1080 \
        -quality 88 "${DEST}/${name}.jpg"
    magick "$src" -resize 280x158^ -gravity center -extent 280x158 \
        -quality 85 "${DEST}/${name}-thumb.jpg"
    chmod 0644 "${DEST}/${name}.jpg" "${DEST}/${name}-thumb.jpg"
    info "$(basename "${DEST}/${name}.jpg")       $(stat -c '%s' "${DEST}/${name}.jpg" | numfmt --to=iec 2>/dev/null || stat -c '%s' "${DEST}/${name}.jpg")"
    info "$(basename "${DEST}/${name}-thumb.jpg") $(stat -c '%s' "${DEST}/${name}-thumb.jpg" | numfmt --to=iec 2>/dev/null || stat -c '%s' "${DEST}/${name}-thumb.jpg")"
done

# Each image takes over one Microsoft asset name, so running out of names means
# the extra images are installed and never reachable. 54-teams.sh fails the
# build on this; saying it here saves a build.
images=$(find "$DEST" -maxdepth 1 -name '*.jpg' ! -name '*-thumb.jpg' | wc -l)
slots=$(grep -cv '^[[:space:]]*#\|^[[:space:]]*$' "${DEST}/slots.txt")
log "${images} backgrounds, ${slots} slots"
(( slots >= images )) || die "only ${slots} slots in slots.txt for ${images} images.
       Add more Microsoft asset names to branding/teams-backgrounds/slots.txt —
       journalctl -u ik-os-teams-backgrounds on a running machine lists the ones
       the client actually asks for."

info "commit branding/teams-backgrounds/ and rebuild the image"
