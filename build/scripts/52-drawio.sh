#!/bin/bash
# draw.io Desktop from upstream's own .deb — a deliberate SDD §54 exception
# (ADR 0016).
#
# §54 sends GUI applications to Flatpak. draw.io's Flathub package was marked
# end-of-life on 2026-08-31, frozen at 30.0.4, with no successor id and no
# maintained equivalent, while upstream keeps shipping (31.3.2 on 2026-08-22).
# Neither Debian nor an upstream APT repository packages it, so the
# claude-desktop route (ADR 0007) is unavailable too.
#
# Fetched here rather than vendored in git like the Brother driver
# (67-printer-vendor.sh) for one blunt reason: the .deb is 127 MiB and GitHub
# refuses any file over 100 MiB. The pinned sha256 in config/desktop/drawio.env
# keeps the artefact tamper-evident; it does not keep it available, so a deleted
# upstream release fails this build loudly rather than silently shipping an
# image without the app.
#
# The maintainer scripts are NOT run (ADR 0008), and here that is not a
# preference. drawio's postinst picks the chrome-sandbox mode from the *build*
# environment:
#
#     if ! { [[ -L /proc/self/ns/user ]] && unshare --user true; }; then
#         chmod 4755 '/opt/drawio/chrome-sandbox'
#     else
#         chmod 0755 '/opt/drawio/chrome-sandbox'
#     fi
#
# `unshare --user` fails inside a rootless build container, so running the
# postinst would bake a setuid-root binary into the image because of a property
# of the builder rather than of the target. Debian enables unprivileged user
# namespaces, so 0755 — what the archive already ships — is correct, and the
# assertion below proves no setuid bit reached the image.
#
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

# shellcheck source=config/desktop/drawio.env
. "${CTX}/config/desktop/drawio.env"

[[ -n "${DRAWIO_VERSION:-}" ]]    || die "DRAWIO_VERSION is not set in config/desktop/drawio.env"
[[ -n "${DRAWIO_DEB_SHA256:-}" ]] || die "DRAWIO_DEB_SHA256 is not set in config/desktop/drawio.env"

# 64 hex digits. A truncated or placeholder checksum would otherwise be compared
# against a real one and simply never match, reported as a corrupt download.
[[ "$DRAWIO_DEB_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "DRAWIO_DEB_SHA256 is not a sha256 digest: ${DRAWIO_DEB_SHA256}
       Re-run scripts/maintenance/update-drawio.sh to regenerate it."

DEB="drawio-amd64-${DRAWIO_VERSION}.deb"
URL="https://github.com/jgraph/drawio-desktop/releases/download/v${DRAWIO_VERSION}/${DEB}"

# Only the amd64 artefact is pinned. Fail rather than install an x86_64 binary
# on another architecture, or silently skip the app.
arch=$(dpkg --print-architecture)
[[ "$arch" == amd64 ]] || die "config/desktop/drawio.env pins the amd64 draw.io
       package, but this build targets ${arch}. Pin the matching artefact or
       drop 52-drawio.sh from the Containerfile for this architecture."

log "Installing draw.io Desktop ${DRAWIO_VERSION}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

info "fetching ${DEB}"
curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o "${STAGE}/${DEB}" "$URL" \
    || die "cannot download ${URL}
       Upstream deletes and re-tags releases occasionally. Check
       https://github.com/jgraph/drawio-desktop/releases and re-run
       scripts/maintenance/update-drawio.sh to move the pin."

# --- provenance (SDD §24: validate origin) ---------------------------------
actual=$(sha256sum "${STAGE}/${DEB}" | cut -d' ' -f1)
[[ "$actual" == "$DRAWIO_DEB_SHA256" ]] || die "checksum mismatch on ${DEB}
       expected ${DRAWIO_DEB_SHA256}
       actual   ${actual}
       Either the pin is stale or the artefact changed under it. Do not ship
       this image until that is explained."
info "sha256 verified: ${actual}"

# --- unpack (payload only, never maintainer scripts) -----------------------
PAYLOAD="${STAGE}/payload"
mkdir -p "$PAYLOAD"
dpkg-deb -x "${STAGE}/${DEB}" "$PAYLOAD"

# The payload is opt/ plus a small usr/ tree. Anything else means the packaging
# changed shape, and this step would place it wrong or drop it silently.
for top in "${PAYLOAD}"/*/; do
    case "$(basename "$top")" in
        opt|usr) ;;
        *) die "the draw.io payload contains $(basename "$top")/, which this step
       does not place. Inspect it with 'dpkg-deb -c' and extend 52-drawio.sh." ;;
    esac
done
[[ -x "${PAYLOAD}/opt/drawio/drawio" ]] \
    || die "no executable at opt/drawio/drawio in the payload — the upstream
       layout changed and 52-drawio.sh needs updating."

# --- where it lives --------------------------------------------------------
# Upstream installs to /opt/drawio. /opt is a symlink to var/opt here and
# 95-finalize.sh empties /var, so /opt cannot hold image content — the Brother
# driver works around that with a tmpfiles symlink because its CUPS wrapper
# recovers the model name from its own /opt path (67-printer-vendor.sh).
#
# draw.io needs none of that. Only two files in the whole package name
# /opt/drawio — the .desktop and the AppArmor profile — and no binary resolves
# its resources through an absolute path, so the tree goes straight into /usr and
# depends on nothing that has to be recreated at boot.
APP=/usr/lib/drawio

rm -rf "$APP"
mkdir -p "$APP"
cp -a "${PAYLOAD}/opt/drawio/." "${APP}/"

# The icons, the MIME definition for .drawio files, and the .desktop itself.
cp -a "${PAYLOAD}/usr/." /usr/

# Exec still points at /opt/drawio/drawio, which will not exist.
DESKTOP=/usr/share/applications/drawio.desktop
[[ -f "$DESKTOP" ]] || die "the payload shipped no ${DESKTOP}"
sed -i "s|^Exec=/opt/drawio/drawio|Exec=${APP}/drawio|" "$DESKTOP"
grep -q "^Exec=${APP}/drawio" "$DESKTOP" \
    || die "could not rewrite Exec= in ${DESKTOP}. Upstream changed the line;
       the launcher would point at /opt/drawio, which does not exist."
info "Exec rewritten to ${APP}/drawio"

# Relative, so it stays correct however /usr is mounted.
ln -sfn ../lib/drawio/drawio /usr/bin/drawio

# The bundled AppArmor profile is deliberately not installed. It is the Ubuntu
# 24 userns stub — `profile "drawio" "/opt/drawio/drawio" flags=(unconfined)`
# granting `userns` — so it adds no confinement, it names a path this image does
# not use, and Debian does not apply the AppArmor userns restriction that makes
# it necessary on Ubuntu.
info "AppArmor profile not installed: unconfined stub, and Debian needs no userns grant"

# --- assert what the skipped postinst would have decided -------------------
# The whole reason the maintainer scripts are skipped. Prove it held: a setuid
# root binary in the image would be a privilege boundary nobody chose.
mapfile -t setuid_files < <(find "$APP" -perm /6000 -type f 2>/dev/null)
(( ${#setuid_files[@]} == 0 )) || die "setuid/setgid bits in ${APP}:
$(printf '       %s\n' "${setuid_files[@]}")
       drawio's postinst sets chrome-sandbox 4755 when it cannot create a user
       namespace, which is always true in a rootless build container. It must
       not run here."

sandbox_mode=$(stat -c '%a' "${APP}/chrome-sandbox")
[[ "$sandbox_mode" == 755 ]] || die "${APP}/chrome-sandbox is mode ${sandbox_mode},
       expected 755. Electron uses the user-namespace sandbox on Debian and the
       setuid helper only on kernels without it."
info "chrome-sandbox is 0755: the user-namespace sandbox, not the setuid helper"

# --- prove it can actually start (SDD §24: dependency compatibility) -------
# Nothing resolves drawio's Depends for us: the payload is unpacked, not
# installed, so apt never sees them. They are declared in
# packages/desktop/packages.list instead, and this is the check that they are
# complete. An Electron binary with a missing library installs perfectly and
# then fails the moment a user clicks the icon.
log "Verifying draw.io resolves its shared libraries"
missing=0 checked=0
while IFS= read -r bin; do
    output_matches_fixed 'ELF' file "$bin" || continue
    checked=$(( checked + 1 ))
    if output_matches_fixed 'not found' ldd "$bin"; then
        info "MISSING LIBRARIES: ${bin}"
        ldd "$bin" 2>/dev/null | grep 'not found' | sed 's/^/        /'
        missing=1
    fi
done < <(find "$APP" -type f -perm -u+x 2>/dev/null | sort)
info "${checked} binaries checked"
(( missing == 0 )) || die "draw.io cannot resolve its shared libraries. It would
       install cleanly and fail at launch. Add the missing packages to
       packages/desktop/packages.list (upstream's Depends are listed there)."

# --- caches ----------------------------------------------------------------
# The postinst's remaining useful work. Without the MIME cache a .drawio file
# has no type and the app is never offered to open one.
command -v update-mime-database >/dev/null \
    || die "update-mime-database is missing — add shared-mime-info to
       packages/desktop/packages.list."
update-mime-database /usr/share/mime

command -v update-desktop-database >/dev/null \
    || die "update-desktop-database is missing — add desktop-file-utils to
       packages/desktop/packages.list."
update-desktop-database /usr/share/applications

# GTK scans hicolor when there is no cache, so this is an optimisation rather
# than a requirement.
if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -qf /usr/share/icons/hicolor 2>/dev/null || true
fi

# --- record what shipped (SDD §41, §46) ------------------------------------
mkdir -p /usr/share/ik-os
{
    echo "# draw.io Desktop baked into this image (ADR 0016)"
    echo "# Not a Flatpak: the Flathub package is end-of-life (30.0.4)."
    echo "version=${DRAWIO_VERSION}"
    echo "source=${URL}"
    echo "sha256=${DRAWIO_DEB_SHA256}"
    echo "path=${APP}"
} > /usr/share/ik-os/drawio.release

log "draw.io Desktop ${DRAWIO_VERSION} ready at ${APP} ($(du -sh "$APP" | cut -f1))"
