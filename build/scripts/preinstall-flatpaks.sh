#!/bin/bash
# Install the Flatpaks in config/desktop/preinstalled-flatpaks.list into
# /var/lib/flatpak, for the Containerfile to copy into the image (SDD §15).
#
# NOT part of the numbered build sequence: this runs in its own build stage, so
# a 2.4 GB download is not repeated every time an unrelated build script
# changes. The same reason bootc is built in a stage of its own.
#
# The result is copied in AFTER 95-finalize.sh has emptied /var, so it is not
# captured into tmpfiles.d and not wiped.
set -euo pipefail

CTX="${CTX:-/ctx}"
LIST="${CTX}/config/desktop/preinstalled-flatpaks.list"
REPOFILE="${CTX}/config/desktop/flathub.flatpakrepo"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[[ -r "$LIST" ]] || die "no preinstall list at ${LIST}"
[[ -r "$REPOFILE" ]] || die "no Flathub repo definition at ${REPOFILE}"

mapfile -t APPS < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$LIST" | grep -v '^$')
(( ${#APPS[@]} )) || die "the preinstall list is empty"

# Every preinstalled app has to be in the approved list too, or the image would
# ship an application that nothing declares and no validation covers.
for app in "${APPS[@]}"; do
    grep -qxF "$app" <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' \
        "${CTX}/config/desktop/system-flatpaks.list" | grep -v '^$') \
        || die "${app} is preinstalled but not in config/desktop/system-flatpaks.list"
done

# ostree writes its objects through O_TMPFILE in a temporary directory. In a
# build container /var/tmp does not exist, and the failure is reported as
# "open(O_TMPFILE): No such file or directory" — which reads like a filesystem
# that cannot do O_TMPFILE, sends you looking at overlayfs, and is really just a
# missing directory.
mkdir -p /var/tmp /var/lib/flatpak
chmod 1777 /var/tmp
export TMPDIR=/var/tmp

log "adding the Flathub remote from the image's own pinned definition"
flatpak remote-add --if-not-exists --system flathub "$REPOFILE" \
    || die "could not add the Flathub remote"

log "installing ${#APPS[@]} application(s) and their runtimes"
# bwrap cannot create a namespace in a rootless build container, so flatpak's
# post-install triggers (the desktop, mime and icon caches) fail with
# "Creating new namespace failed: Operation not permitted". That is a warning,
# not an error: flatpak creates the /var/lib/flatpak/exports symlinks itself,
# and GNOME reads .desktop files directly. The caches are regenerated the first
# time flatpak installs anything on the real machine. Asserted below rather
# than assumed.
flatpak install -y --system --noninteractive flathub "${APPS[@]}" \
    || die "flatpak install failed"

log "verifying"
for app in "${APPS[@]}"; do
    flatpak info --system "$app" >/dev/null 2>&1 \
        || die "${app} is not installed after a successful install"
    # Without this symlink the application exists but appears nowhere in the
    # shell, which is indistinguishable from it not being installed at all.
    [[ -e "/var/lib/flatpak/exports/share/applications/${app}.desktop" ]] \
        || die "${app} has no exported .desktop entry — it would be invisible
       in the shell. The bwrap trigger failure above is normally harmless, but
       this part is not optional."
    echo "    ${app}  $(flatpak info --system "$app" --show-size 2>/dev/null || echo)"
done

flatpak list --system --columns=ref | sed 's/^/    /'
log "/var/lib/flatpak is $(du -sh /var/lib/flatpak | cut -f1)"
