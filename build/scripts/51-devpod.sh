#!/bin/bash
# DevPod from upstream's own .deb, replacing the end-of-life Flathub build
# (ADR 0021).
#
# This is the fourth application §54 sends to Flatpak and this image installs
# instead, and by far the least invasive of them. Unlike draw.io, Sidra and
# teams-for-linux it is not an Electron package: the payload is already a
# /usr tree, there are NO maintainer scripts at all, and nothing has to be
# relocated out of /opt or rewritten. It is a plain Debian package that happens
# to be published on GitHub rather than in the archive.
#
# What it does need is the GTK3 WebKit, libwebkit2gtk-4.1-0. The image already
# carries WebKit for GTK4 (libwebkitgtk-6.0-4, pulled in by GNOME), so this is
# a second, older build of the same engine that exists solely for this app.
# Both come from Debian and are updated by Debian, which is the one respect in
# which this app is safer than the Electron three: its renderer is not frozen
# inside the package.
#
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

# shellcheck source=config/desktop/devpod.env
. "${CTX}/config/desktop/devpod.env"

[[ -n "${DEVPOD_VERSION:-}" ]]    || die "DEVPOD_VERSION is not set in config/desktop/devpod.env"
[[ -n "${DEVPOD_DEB_SHA256:-}" ]] || die "DEVPOD_DEB_SHA256 is not set in config/desktop/devpod.env"

[[ "$DEVPOD_DEB_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "DEVPOD_DEB_SHA256 is not a sha256 digest: ${DEVPOD_DEB_SHA256}
       Re-run scripts/maintenance/update-devpod.sh to regenerate it."

# The Flathub build is end-of-life and frozen at 0.6.10. Installing both would
# put two DevPods in the launcher, the older one silently unmaintained.
flatpak_ids=$(grep -v '^[[:space:]]*#' "${CTX}/config/desktop/system-flatpaks.list" || true)
if grep -qF 'loft.devpod' <<<"$flatpak_ids"; then
    die "sh.loft.devpod is still in config/desktop/system-flatpaks.list.
       First boot would install the end-of-life Flathub build alongside this
       package: two DevPod entries in the launcher, the Flatpak frozen at
       0.6.10 and never updated again (ADR 0021)."
fi

DEB="DevPod_${DEVPOD_VERSION}_amd64.deb"
URL="https://github.com/loft-sh/devpod/releases/download/v${DEVPOD_VERSION}/${DEB}"

arch=$(dpkg --print-architecture)
[[ "$arch" == amd64 ]] || die "config/desktop/devpod.env pins the amd64 DevPod
       package, but this build targets ${arch}. Upstream publishes no arm64
       .deb — only an AppImage — so pin nothing here and drop 51-devpod.sh from
       the Containerfile for that architecture."

log "Installing DevPod ${DEVPOD_VERSION}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

info "fetching ${DEB}"
curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o "${STAGE}/${DEB}" "$URL" \
    || die "cannot download ${URL}
       Check https://github.com/loft-sh/devpod/releases and re-run
       scripts/maintenance/update-devpod.sh to move the pin."

# --- provenance (SDD §24) --------------------------------------------------
actual=$(sha256sum "${STAGE}/${DEB}" | cut -d' ' -f1)
[[ "$actual" == "$DEVPOD_DEB_SHA256" ]] || die "checksum mismatch on ${DEB}
       expected ${DEVPOD_DEB_SHA256}
       actual   ${actual}
       Either the pin is stale or the artefact changed under it. Do not ship
       this image until that is explained."
info "sha256 verified: ${actual}"

# --- unpack ----------------------------------------------------------------
# Still unpacked rather than installed, for ADR 0008's reason applied in the
# negative: this package ships no maintainer scripts, so there is nothing to
# skip and nothing to assert afterwards. `dpkg -i` would additionally want to
# resolve Depends through apt and write to the dpkg database, which
# 95-finalize.sh then has to relocate. Unpacking keeps it consistent with the
# other three.
PAYLOAD="${STAGE}/payload"
mkdir -p "$PAYLOAD"
dpkg-deb -x "${STAGE}/${DEB}" "$PAYLOAD"

for top in "${PAYLOAD}"/*/; do
    case "$(basename "$top")" in
        usr) ;;
        *) die "the DevPod payload contains $(basename "$top")/, which this step
       does not place. It used to be a pure /usr tree; inspect it with
       'dpkg-deb -c' and extend 51-devpod.sh." ;;
    esac
done

# Upstream names both binaries with a SPACE in them -- "DevPod Desktop" is the
# literal filename, and the icons match ("DevPod Desktop.png"). That is ugly in
# /usr/bin but it is also self-consistent: the desktop entry says
# Exec="DevPod Desktop" and Icon=DevPod Desktop, and both resolve. Renaming
# them would mean rewriting the entry and would risk the window-to-launcher
# association, which GNOME derives from WM_CLASS and the Exec basename, for
# nothing but tidiness. Left alone deliberately.
[[ -x "${PAYLOAD}/usr/bin/DevPod Desktop" ]] \
    || die "no executable at usr/bin/'DevPod Desktop' in the payload — the
       upstream layout changed and 51-devpod.sh needs updating."
[[ -x "${PAYLOAD}/usr/bin/devpod-cli" ]] \
    || die "no executable at usr/bin/devpod-cli in the payload. The desktop app
       shells out to it for every operation, so it is not optional."

cp -a "${PAYLOAD}/usr/." /usr/

# The CLI is the whole of DevPod's documented interface -- `devpod up`,
# `devpod ide`, `devpod provider` -- and upstream's own install instructions
# name it `devpod`. The .deb calls it devpod-cli because the desktop app looks
# for that name, so both exist.
ln -sfn devpod-cli /usr/bin/devpod

DESKTOP="/usr/share/applications/DevPod.desktop"
[[ -f "$DESKTOP" ]] || die "the payload shipped no ${DESKTOP}"

# Nothing was rewritten above, so this is not a check that a rewrite worked --
# it is a check that upstream's entry still points at something that exists. A
# renamed binary in a future release would leave an icon in the menu that does
# nothing when clicked, and nothing else here would notice.
devpod_exec=$(sed -nE 's/^Exec=(.*)/\1/p' "$DESKTOP" | head -1)
devpod_exec="${devpod_exec%% %*}"          # drop field codes (%U, %F)
devpod_exec="${devpod_exec%\"}"            # and the quoting upstream needs for
devpod_exec="${devpod_exec#\"}"            # the space in the name
[[ -x "/usr/bin/${devpod_exec}" ]] || die "the DevPod launcher runs
       '${devpod_exec}', which is not an executable in /usr/bin. Upstream
       renamed the binary; ${DESKTOP} now points at nothing."
info "launcher runs /usr/bin/${devpod_exec}"

devpod_icon=$(sed -nE 's/^Icon=(.*)/\1/p' "$DESKTOP" | head -1)
[[ -n "$devpod_icon" ]] || die "${DESKTOP} declares no Icon="
compgen -G "/usr/share/icons/hicolor/*/apps/${devpod_icon}.png" >/dev/null \
    || die "no icon matches Icon=${devpod_icon} in the hicolor theme. The
       launcher would fall back to a generic placeholder."
info "icon ${devpod_icon} found in the hicolor theme"

# --- prove it can actually start (SDD §24) ---------------------------------
# DevPod's Depends are transcribed into packages/desktop/packages.list like the
# others'. libwebkit2gtk-4.1-0 is the one that is there only for this app.
log "Verifying DevPod resolves its shared libraries"
missing=0 checked=0
while IFS= read -r bin; do
    output_matches_fixed 'ELF' file "$bin" || continue
    checked=$(( checked + 1 ))
    if output_matches_fixed 'not found' ldd "$bin"; then
        info "MISSING LIBRARIES: ${bin}"
        ldd "$bin" 2>/dev/null | grep 'not found' | sed 's/^/        /'
        missing=1
    fi
done < <(find /usr/bin -maxdepth 1 -name 'DevPod*' -o -name 'devpod-cli' | sort)
info "${checked} binaries checked"
(( missing == 0 )) || die "DevPod cannot resolve its shared libraries. It would
       install cleanly and fail at launch. Add the missing packages to
       packages/desktop/packages.list (upstream's Depends are listed there)."

# The CLI is the part people script against, so prove it runs rather than only
# that it links. It is a Go binary with no daemon, so this is safe in a build.
devpod_reported=$("/usr/bin/devpod" version 2>/dev/null | head -1 | sed 's/^v//' || true)
[[ "$devpod_reported" == "$DEVPOD_VERSION" ]] || die "'devpod version' reports
       '${devpod_reported:-nothing}', but the pin says ${DEVPOD_VERSION}. The
       artefact is not the release it claims to be."
info "devpod version reports ${devpod_reported}"

update-desktop-database /usr/share/applications
if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -qf /usr/share/icons/hicolor 2>/dev/null || true
fi

# --- record what shipped (SDD §41, §46) ------------------------------------
mkdir -p /usr/share/ik-os
{
    echo "# DevPod baked into this image (ADR 0021)"
    echo "# Replaces sh.loft.devpod, which Flathub marked end-of-life at 0.6.10."
    echo "version=${DEVPOD_VERSION}"
    echo "source=${URL}"
    echo "sha256=${DEVPOD_DEB_SHA256}"
    echo "cli=/usr/bin/devpod"
} > /usr/share/ik-os/devpod.release

log "DevPod ${DEVPOD_VERSION} ready (CLI at /usr/bin/devpod)"
