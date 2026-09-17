#!/bin/bash
# Microsoft Teams (teams-for-linux) from upstream's own .deb, plus the company
# video backgrounds — an SDD §54 exception (ADR 0020).
#
# Microsoft ships no Linux client, so the image carries the unofficial Electron
# one. Unlike draw.io (ADR 0016) and Sidra (ADR 0019), this application IS on
# Flathub, and it was a Flathub id in system-flatpaks.list until now. It moves
# into the image for one concrete reason: the background service below is
# configured through /etc/teams-for-linux/config.json, and a Flatpak can never
# read that file — flatpak refuses to share /etc with a sandbox ("Path /etc is
# reserved by Flatpak"). The cost, an unsandboxed communication client, is set
# out in the ADR.
#
# The packaging half of this script is 52-drawio.sh and 53-sidra.sh again: the
# same electron-builder layout, the same /opt problem, the same postinst that
# picks a privilege boundary from the build environment.
#
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

# shellcheck source=config/desktop/teams-for-linux.env
. "${CTX}/config/desktop/teams-for-linux.env"

[[ -n "${TEAMS_VERSION:-}" ]]    || die "TEAMS_VERSION is not set in config/desktop/teams-for-linux.env"
[[ -n "${TEAMS_DEB_SHA256:-}" ]] || die "TEAMS_DEB_SHA256 is not set in config/desktop/teams-for-linux.env"

[[ "$TEAMS_DEB_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "TEAMS_DEB_SHA256 is not a sha256 digest: ${TEAMS_DEB_SHA256}
       Re-run scripts/maintenance/update-teams-for-linux.sh to regenerate it."

# The Flatpak and the .deb install the same application under two different
# ids, so shipping both puts two "Teams" entries in the launcher and splits the
# profile in half. The list is the source of truth for what first boot
# installs, so check it rather than trust a comment.
# Comments are stripped first: the list now explains in prose where Teams went,
# and that explanation names the id.
flatpak_ids=$(grep -v '^[[:space:]]*#' "${CTX}/config/desktop/system-flatpaks.list" || true)
if grep -qF 'teams_for_linux' <<<"$flatpak_ids"; then
    die "com.github.IsmaelMartinez.teams_for_linux is still in
       config/desktop/system-flatpaks.list. First boot would install the
       Flatpak alongside this package: two launcher entries, two profiles, and
       only one of them reading /etc/teams-for-linux/config.json (ADR 0020)."
fi

DEB="teams-for-linux_${TEAMS_VERSION}_amd64.deb"
URL="https://github.com/IsmaelMartinez/teams-for-linux/releases/download/v${TEAMS_VERSION}/${DEB}"

arch=$(dpkg --print-architecture)
[[ "$arch" == amd64 ]] || die "config/desktop/teams-for-linux.env pins the amd64
       package, but this build targets ${arch}. Pin the matching artefact or
       drop 54-teams.sh from the Containerfile for this architecture."

log "Installing teams-for-linux ${TEAMS_VERSION}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

info "fetching ${DEB}"
curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o "${STAGE}/${DEB}" "$URL" \
    || die "cannot download ${URL}
       Check https://github.com/IsmaelMartinez/teams-for-linux/releases and
       re-run scripts/maintenance/update-teams-for-linux.sh to move the pin."

# --- provenance (SDD §24) --------------------------------------------------
# No upstream signature, no published digest: this compares the artefact with
# what a human saw when the pin was written. Tamper-evidence between builds,
# not proof of provenance.
actual=$(sha256sum "${STAGE}/${DEB}" | cut -d' ' -f1)
[[ "$actual" == "$TEAMS_DEB_SHA256" ]] || die "checksum mismatch on ${DEB}
       expected ${TEAMS_DEB_SHA256}
       actual   ${actual}
       Either the pin is stale or the artefact changed under it. Do not ship
       this image until that is explained."
info "sha256 verified: ${actual}"

# --- unpack (payload only, never maintainer scripts) -----------------------
PAYLOAD="${STAGE}/payload"
mkdir -p "$PAYLOAD"
dpkg-deb -x "${STAGE}/${DEB}" "$PAYLOAD"

for top in "${PAYLOAD}"/*/; do
    case "$(basename "$top")" in
        opt|usr) ;;
        *) die "the teams-for-linux payload contains $(basename "$top")/, which
       this step does not place. Inspect it with 'dpkg-deb -c' and extend
       54-teams.sh." ;;
    esac
done
[[ -x "${PAYLOAD}/opt/teams-for-linux/teams-for-linux" ]] \
    || die "no executable at opt/teams-for-linux/teams-for-linux in the payload
       — the upstream layout changed and 54-teams.sh needs updating."

# --- where it lives --------------------------------------------------------
# /opt is a symlink to var/opt and 95-finalize.sh empties /var, so the payload
# has to leave /opt or the application disappears on deployment.
APP=/usr/lib/teams-for-linux

rm -rf "$APP"
mkdir -p "$APP"
cp -a "${PAYLOAD}/opt/teams-for-linux/." "${APP}/"
cp -a "${PAYLOAD}/usr/." /usr/

ln -sfn ../lib/teams-for-linux/teams-for-linux /usr/bin/teams-for-linux

DESKTOP=/usr/share/applications/teams-for-linux.desktop
[[ -f "$DESKTOP" ]] || die "the payload shipped no ${DESKTOP}"
sed -i "s|/opt/teams-for-linux/teams-for-linux|${APP}/teams-for-linux|g" "$DESKTOP"
grep -q "Exec=${APP}/teams-for-linux" "$DESKTOP" \
    || die "could not rewrite Exec= in ${DESKTOP}. Upstream changed the line;
       the launcher would point at /opt/teams-for-linux, which does not exist."
if output_matches_fixed '/opt/teams-for-linux' cat "$DESKTOP"; then
    die "${DESKTOP} still refers to /opt/teams-for-linux after the rewrite."
fi

# Upstream's entry forces --ozone-platform=x11, so the client would render
# through XWayland on this Wayland-first image — blurry under fractional
# scaling, and screen sharing loses the portal path. The hint lets Electron
# choose Wayland when there is a Wayland session and fall back to X11 otherwise.
sed -i 's|--ozone-platform=x11|--ozone-platform-hint=auto|g' "$DESKTOP"
if output_matches_fixed 'ozone-platform=x11' cat "$DESKTOP"; then
    die "the XWayland flag survived the rewrite in ${DESKTOP}."
fi
info "Exec rewritten to ${APP}/teams-for-linux, native Wayland restored"

# --- assert what the skipped postinst would have decided (ADR 0008) --------
mapfile -t setuid_files < <(find "$APP" -perm /6000 -type f 2>/dev/null)
(( ${#setuid_files[@]} == 0 )) || die "setuid/setgid bits in ${APP}:
$(printf '       %s\n' "${setuid_files[@]}")
       The postinst sets chrome-sandbox 4755 when it cannot create a user
       namespace, which is always true in a rootless build container. It must
       not run here."

sandbox_mode=$(stat -c '%a' "${APP}/chrome-sandbox")
[[ "$sandbox_mode" == 755 ]] || die "${APP}/chrome-sandbox is mode ${sandbox_mode},
       expected 755. Electron uses the user-namespace sandbox on Debian and the
       setuid helper only on kernels without it."
info "chrome-sandbox is 0755: the user-namespace sandbox, not the setuid helper"

# --- prove it can actually start (SDD §24) ---------------------------------
log "Verifying teams-for-linux resolves its shared libraries"
missing=0 checked=0 alt_libc=0
while IFS= read -r bin; do
    output_matches_fixed 'ELF' file "$bin" || continue
    # cbor-extract ships one native module per libc -- node.abi137.glibc.node
    # and node.abi137.musl.node -- and picks at runtime. The musl builds link
    # against musl's libc.so, which glibc neither provides nor should: they are
    # dead weight in this image, not a missing dependency. Reporting them would
    # leave two bad options, a permanently red build or a check taught to
    # tolerate "not found", so they are skipped by name -- but only when the
    # glibc sibling they defer to is really there, or the skip would hide a
    # package that ships nothing loadable at all.
    if [[ "$bin" == *.musl.node ]]; then
        glibc_sibling="${bin/.musl.node/.glibc.node}"
        [[ -f "$glibc_sibling" ]] || die "${bin} is a musl build of a native
       module and there is no glibc build beside it. Nothing in this image can
       load either, so the feature it backs is silently dead."
        alt_libc=$(( alt_libc + 1 ))
        continue
    fi
    checked=$(( checked + 1 ))
    if output_matches_fixed 'not found' ldd "$bin"; then
        info "MISSING LIBRARIES: ${bin}"
        ldd "$bin" 2>/dev/null | grep 'not found' | sed 's/^/        /'
        missing=1
    fi
done < <(find "$APP" -type f -perm -u+x 2>/dev/null | sort)
info "${checked} binaries checked, ${alt_libc} musl builds skipped"
(( missing == 0 )) || die "teams-for-linux cannot resolve its shared libraries.
       It would install cleanly and fail at launch. Add the missing packages to
       packages/desktop/packages.list (upstream's Depends are listed there)."

update-mime-database /usr/share/mime
update-desktop-database /usr/share/applications
if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -qf /usr/share/icons/hicolor 2>/dev/null || true
fi

# --- company video backgrounds ---------------------------------------------
# Teams builds the picker itself and teams-for-linux can only redirect the
# image requests it makes, so a company background reaches the picker by being
# served in place of one of Microsoft's own assets. The names taken over are in
# branding/teams-backgrounds/slots.txt; everything else is proxied back to
# Microsoft by the service, which is why the rest of the picker still looks
# normal instead of becoming a grid of empty tiles.
log "Installing the company Teams video backgrounds"

TBG_SRC="${CTX}/branding/teams-backgrounds"
TBG_DIR=/usr/share/ik-os/teams-backgrounds

# The images are committed already rendered — 1920x1080 for the background and
# 280x158 for the picker thumbnail, centre-cropped to 16:9. They are NOT resized
# here: doing that at build time would put ImageMagick in every shipped image
# for a step that runs once per new photograph. scripts/maintenance/render-teams-backgrounds.sh
# is what produces them.
shopt -s nullglob
TEAMS_BGS=()
for img in "${TBG_SRC}"/*.jpg; do
    [[ "$img" == *-thumb.jpg ]] && continue
    TEAMS_BGS+=( "$img" )
done
shopt -u nullglob

(( ${#TEAMS_BGS[@]} > 0 )) || die "no images in branding/teams-backgrounds/.
       The service would start with an empty map and every company tile in the
       Teams picker would fall through to Microsoft's own asset."

install -d -m0755 "$TBG_DIR"
for bg in "${TEAMS_BGS[@]}"; do
    name=$(basename "$bg" .jpg)
    thumb="${TBG_SRC}/${name}-thumb.jpg"
    # A background without its thumbnail shows an empty tile in the picker,
    # which reads as "the feature is broken" rather than "one file is missing".
    [[ -f "$thumb" ]] || die "no thumbnail for ${name}.
       Expected branding/teams-backgrounds/${name}-thumb.jpg — regenerate the
       pair with scripts/maintenance/render-teams-backgrounds.sh."
    install -Dm0644 "$bg"    "${TBG_DIR}/${name}.jpg"
    install -Dm0644 "$thumb" "${TBG_DIR}/${name}-thumb.jpg"
done
install -Dm0644 "${TBG_SRC}/slots.txt" "${TBG_DIR}/slots.txt"
info "installed ${#TEAMS_BGS[@]} backgrounds ($(du -sh "$TBG_DIR" | cut -f1))"

# One Microsoft asset can only be taken over by one image. Fail the build
# rather than let an image silently never appear in the picker.
TBG_SLOTS=$(grep -cv '^[[:space:]]*#\|^[[:space:]]*$' "${TBG_DIR}/slots.txt")
(( TBG_SLOTS >= ${#TEAMS_BGS[@]} )) || die "only ${TBG_SLOTS} slots in slots.txt
       for ${#TEAMS_BGS[@]} images. Every image past the ${TBG_SLOTS}th would be
       installed and never reachable; add more Microsoft asset names."

# teams-for-linux fetches this manifest once at startup. The picker ignores it
# (nothing has consumed the get-custom-bg-list IPC since 2.x), but answering
# keeps a warning out of the app log. It must be a bare JSON array: the app
# iterates whatever it parses, and the documented object form makes it throw
# "configJSON is not iterable".
{
    echo '['
    first=1
    for bg in $(printf '%s\n' "${TEAMS_BGS[@]}" | sort); do
        name=$(basename "$bg" .jpg)
        # ik-window-view-logo -> "Window View Logo", the same derivation
        # 55-branding.sh uses for wallpaper names.
        pretty=$(printf '%s' "${name#ik-}" | sed -e 's/-/ /g' -e 's/\b\(.\)/\u\1/g')
        (( first )) || echo ','
        first=0
        printf '  {"filetype": "jpg", "id": "%s", "name": "%s", "src": "/%s.jpg", "thumb_src": "/%s-thumb.jpg"}' \
            "$name" "$pretty" "$name" "$name"
    done
    echo
    echo ']'
} > "${TBG_DIR}/config.json"
chmod 0644 "${TBG_DIR}/config.json"

# The names come from filenames, so nothing here should be able to produce
# invalid JSON — which is exactly why an unnoticed change that does is worth
# catching at build time rather than in the app log.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d, list) and d' \
    "${TBG_DIR}/config.json" \
    || die "${TBG_DIR}/config.json is not a non-empty JSON array."
info "manifest lists $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${TBG_DIR}/config.json") backgrounds"

# The loopback service that answers the redirected requests. The unit itself is
# installed by 85-systemd.sh with every other unit, and enabled by the preset.
install -Dm0755 "${CTX}/scripts/desktop/ik-os-teams-backgrounds.py" \
    /usr/libexec/ik-os/ik-os-teams-backgrounds.py
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' \
    /usr/libexec/ik-os/ik-os-teams-backgrounds.py \
    || die "/usr/libexec/ik-os/ik-os-teams-backgrounds.py does not parse."

# --- client defaults -------------------------------------------------------
# teams-for-linux reads /etc/teams-for-linux/config.json and merges the user's
# own ~/.config/teams-for-linux/config.json over it, user keys winning — so
# these are defaults, not locks (SDD §53).
#
# Shipped through tmpfiles rather than baked into /etc, the same way cupsd.conf
# is (65-printing.sh): image content lives in /usr, and /etc stays free of
# files that would need a three-way merge on every update. `C` copies only when
# the target does not exist, so a machine where someone edited it keeps their
# version — and does NOT pick up a changed default. Changing the port or the
# service URL therefore needs a note in the release notes, not just a new image.
install -Dm0644 "${CTX}/config/desktop/teams-for-linux.json" \
    /usr/lib/ik-os/teams-for-linux/config.json
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
    /usr/lib/ik-os/teams-for-linux/config.json \
    || die "config/desktop/teams-for-linux.json is not valid JSON."

cat > /usr/lib/tmpfiles.d/ik-os-teams-for-linux.conf <<'EOF'
d /etc/teams-for-linux 0755 root root -
C /etc/teams-for-linux/config.json 0644 root root - /usr/lib/ik-os/teams-for-linux/config.json
EOF

# --- record what shipped (SDD §41, §46) ------------------------------------
mkdir -p /usr/share/ik-os
{
    echo "# teams-for-linux baked into this image (ADR 0020)"
    echo "# Taken off Flathub: a Flatpak cannot read /etc/teams-for-linux/config.json."
    echo "version=${TEAMS_VERSION}"
    echo "source=${URL}"
    echo "sha256=${TEAMS_DEB_SHA256}"
    echo "path=${APP}"
    echo "backgrounds=${#TEAMS_BGS[@]}"
    echo "slots=${TBG_SLOTS}"
} > /usr/share/ik-os/teams-for-linux.release

install -Dm0644 /dev/stdin /usr/share/doc/ik-os/teams-backgrounds.md <<'EOF'
# Company video backgrounds in Teams

The image ships teams-for-linux and the company backgrounds together. Teams
builds its background picker itself and offers no way to add to it, so the
company images are served **in place of** Microsoft's own assets: the names
listed in /usr/share/ik-os/teams-backgrounds/slots.txt.

    ik-os-teams-backgrounds.service   127.0.0.1:8421

Every asset the client does not get from this image is proxied straight back to
Microsoft's CDN, which is why the rest of the picker looks untouched.

## Turning it off

/etc/teams-for-linux/config.json holds the defaults; your own
~/.config/teams-for-linux/config.json is merged over it and wins. To go back to
Microsoft's backgrounds only:

    {"isCustomBackgroundEnabled": false}

## A background stopped appearing

Microsoft retired the asset name it was mapped to. The service logs every asset
the client asks for, marked `ik` (served from the image) or `ms` (proxied):

    journalctl -u ik-os-teams-backgrounds

Pick a live name from that log and replace the dead line in slots.txt, in
branding/teams-backgrounds/ in the ik-os-next repository.

## Two Teams in the launcher

A fresh install has only the packaged client. Two entries mean this machine came
from Bluefin through ik-os-migrate and kept a Flatpak: the migration leaves /var
in place, so anything already in /var/lib/flatpak survives it. Nothing
reinstalls it -- the id is not in this image's list -- and nothing removes it
either:

    flatpak uninstall --system com.github.IsmaelMartinez.teams_for_linux

The profile moves too: copy
~/.var/app/com.github.IsmaelMartinez.teams_for_linux/config/teams-for-linux to
~/.config/teams-for-linux to keep the session, otherwise it is a fresh sign-in.
Only the packaged client reads /etc/teams-for-linux/config.json, so until the
Flatpak is gone the company backgrounds appear in one of the two and not the
other.
EOF

log "teams-for-linux ${TEAMS_VERSION} ready at ${APP} ($(du -sh "$APP" | cut -f1))"
info "${#TEAMS_BGS[@]} company backgrounds in ${TBG_SLOTS} slots"
