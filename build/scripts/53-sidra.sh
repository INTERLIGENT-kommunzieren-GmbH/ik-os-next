#!/bin/bash
# Sidra (Apple Music desktop client) from upstream's own .deb — an SDD §54
# exception (ADR 0019).
#
# §54 sends GUI applications to Flatpak. Sidra is on neither Flathub nor any
# other remote (the Flathub search for it returns nothing), Debian does not
# package it, and upstream publishes no APT repository — so, as with draw.io
# (ADR 0016), the preferred route has nothing to route to.
#
# The shape of this script is deliberately the same as 52-drawio.sh: both are
# electron-builder packages, with the same /opt payload and the same postinst
# that picks a privilege boundary from the *build* environment. Read the long
# explanation there; the short version is below.
#
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

# shellcheck source=config/desktop/sidra.env
. "${CTX}/config/desktop/sidra.env"

[[ -n "${SIDRA_VERSION:-}" ]]    || die "SIDRA_VERSION is not set in config/desktop/sidra.env"
[[ -n "${SIDRA_DEB_SHA256:-}" ]] || die "SIDRA_DEB_SHA256 is not set in config/desktop/sidra.env"

[[ "$SIDRA_DEB_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "SIDRA_DEB_SHA256 is not a sha256 digest: ${SIDRA_DEB_SHA256}
       Re-run scripts/maintenance/update-sidra.sh to regenerate it."

DEB="Sidra-${SIDRA_VERSION}-linux-amd64.deb"
URL="https://github.com/wimpysworld/sidra/releases/download/${SIDRA_VERSION}/${DEB}"

# Only the amd64 artefact is pinned. Upstream also ships arm64, but nothing
# verifies it here, so fail rather than install the wrong architecture.
arch=$(dpkg --print-architecture)
[[ "$arch" == amd64 ]] || die "config/desktop/sidra.env pins the amd64 Sidra
       package, but this build targets ${arch}. Pin the matching artefact or
       drop 53-sidra.sh from the Containerfile for this architecture."

log "Installing Sidra ${SIDRA_VERSION}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

info "fetching ${DEB}"
curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o "${STAGE}/${DEB}" "$URL" \
    || die "cannot download ${URL}
       Check https://github.com/wimpysworld/sidra/releases and re-run
       scripts/maintenance/update-sidra.sh to move the pin."

# --- provenance (SDD §24: validate origin) ---------------------------------
# There is no upstream signature and no published digest, so this compares the
# artefact against what a human saw when the pin was written. It catches a
# corrupted download and a release re-tagged under the pin; it does not
# establish that upstream itself was not compromised.
actual=$(sha256sum "${STAGE}/${DEB}" | cut -d' ' -f1)
[[ "$actual" == "$SIDRA_DEB_SHA256" ]] || die "checksum mismatch on ${DEB}
       expected ${SIDRA_DEB_SHA256}
       actual   ${actual}
       Either the pin is stale or the artefact changed under it. Do not ship
       this image until that is explained."
info "sha256 verified: ${actual}"

# --- unpack (payload only, never maintainer scripts) -----------------------
PAYLOAD="${STAGE}/payload"
mkdir -p "$PAYLOAD"
dpkg-deb -x "${STAGE}/${DEB}" "$PAYLOAD"

# opt/ plus a small usr/ tree (the .desktop, icons, a changelog). Anything else
# means the packaging changed shape and this step would misplace or drop it.
for top in "${PAYLOAD}"/*/; do
    case "$(basename "$top")" in
        opt|usr) ;;
        *) die "the Sidra payload contains $(basename "$top")/, which this step
       does not place. Inspect it with 'dpkg-deb -c' and extend 53-sidra.sh." ;;
    esac
done
[[ -x "${PAYLOAD}/opt/Sidra/sidra" ]] \
    || die "no executable at opt/Sidra/sidra in the payload — the upstream
       layout changed and 53-sidra.sh needs updating."

# --- where it lives --------------------------------------------------------
# /opt is a symlink to var/opt here and 95-finalize.sh empties /var, so /opt
# cannot hold image content: an image built with the payload left in place
# would ship an application that vanishes on the first deployment. Only the
# .desktop names /opt/Sidra, so the tree moves into /usr with no tmpfiles
# symlink to recreate at boot (contrast 67-printer-vendor.sh, whose CUPS
# wrapper recovers the printer model from its own /opt path).
APP=/usr/lib/sidra

rm -rf "$APP"
mkdir -p "$APP"
cp -a "${PAYLOAD}/opt/Sidra/." "${APP}/"

# The icons, the desktop entry and upstream's changelog.
cp -a "${PAYLOAD}/usr/." /usr/

# Exec still points at /opt/Sidra/sidra, which will not exist. The four
# [Desktop Action] entries invoke dbus-send rather than the binary, so this is
# the only line that names the old path.
DESKTOP=/usr/share/applications/sidra.desktop
[[ -f "$DESKTOP" ]] || die "the payload shipped no ${DESKTOP}"
sed -i "s|^Exec=/opt/Sidra/sidra|Exec=${APP}/sidra|" "$DESKTOP"
grep -q "^Exec=${APP}/sidra" "$DESKTOP" \
    || die "could not rewrite Exec= in ${DESKTOP}. Upstream changed the line;
       the launcher would point at /opt/Sidra, which does not exist."
if output_matches_fixed '/opt/Sidra' cat "$DESKTOP"; then
    die "${DESKTOP} still refers to /opt/Sidra after the rewrite."
fi
info "Exec rewritten to ${APP}/sidra"

# Relative, so it stays correct however /usr is mounted.
ln -sfn ../lib/sidra/sidra /usr/bin/sidra

# The bundled AppArmor profile (resources/apparmor-profile) is deliberately not
# installed, for the same reason as draw.io's: it is the Ubuntu 24 userns stub,
# it names a path this image does not use, and Debian does not apply the
# AppArmor userns restriction that makes it necessary there.
info "AppArmor profile not installed: unconfined stub, and Debian needs no userns grant"

# --- assert what the skipped postinst would have decided -------------------
# Sidra's postinst is the draw.io one almost verbatim:
#
#     if ! { [[ -L /proc/self/ns/user ]] && unshare --user true; }; then
#         chmod 4755 '/opt/Sidra/chrome-sandbox'
#     else
#         chmod 0755 '/opt/Sidra/chrome-sandbox'
#     fi
#
# `unshare --user` always fails in a rootless build container, so running it
# would bake a setuid-root binary into the image because of a property of the
# builder rather than of the target (ADR 0008).
# Unlike draw.io's, this payload does NOT arrive at 0755: upstream ships
# opt/Sidra/sidra and opt/Sidra/chrome-sandbox as 0775, group-writable, and
# relies on the postinst to fix the sandbox helper. Since the postinst does not
# run, the mode is set here — 0755, the branch a kernel with working user
# namespaces takes. The group-write bit goes from the whole tree at the same
# time: /usr is read-only at runtime, so it grants nothing, but a
# group-writable binary in a shipped image is not something to inherit from a
# packaging slip.
chmod -R go-w "$APP"
chmod 0755 "${APP}/chrome-sandbox"

mapfile -t setuid_files < <(find "$APP" -perm /6000 -type f 2>/dev/null)
(( ${#setuid_files[@]} == 0 )) || die "setuid/setgid bits in ${APP}:
$(printf '       %s\n' "${setuid_files[@]}")
       Sidra's postinst sets chrome-sandbox 4755 when it cannot create a user
       namespace, which is always true in a rootless build container. It must
       not run here."

sandbox_mode=$(stat -c '%a' "${APP}/chrome-sandbox")
[[ "$sandbox_mode" == 755 ]] || die "${APP}/chrome-sandbox is mode ${sandbox_mode},
       expected 755. Electron uses the user-namespace sandbox on Debian and the
       setuid helper only on kernels without it."
info "chrome-sandbox is 0755: the user-namespace sandbox, not the setuid helper"

writable=$(find "$APP" -perm /022 -type f 2>/dev/null | head -5)
[[ -z "$writable" ]] || die "group- or world-writable files remain under ${APP}:
$(printf '       %s\n' "$writable")"

# --- prove it can actually start (SDD §24: dependency compatibility) -------
# Unpacking skips apt, so nothing resolves Sidra's Depends. They are declared in
# packages/desktop/packages.list — the same set draw.io needs, since both are
# electron-builder packages — and this is the check that they are complete.
log "Verifying Sidra resolves its shared libraries"
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
(( missing == 0 )) || die "Sidra cannot resolve its shared libraries. It would
       install cleanly and fail at launch. Add the missing packages to
       packages/desktop/packages.list (upstream's Depends are listed there)."

# --- caches ----------------------------------------------------------------
# What remains of the postinst's useful work. The MIME database registers
# x-scheme-handler/itms, which is how an Apple Music link opens in the app.
update-mime-database /usr/share/mime
update-desktop-database /usr/share/applications
if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -qf /usr/share/icons/hicolor 2>/dev/null || true
fi

# --- record what shipped (SDD §41, §46) ------------------------------------
mkdir -p /usr/share/ik-os
{
    echo "# Sidra baked into this image (ADR 0019)"
    echo "# Not a Flatpak: the application is on no Flatpak remote."
    echo "version=${SIDRA_VERSION}"
    echo "source=${URL}"
    echo "sha256=${SIDRA_DEB_SHA256}"
    echo "path=${APP}"
} > /usr/share/ik-os/sidra.release

log "Sidra ${SIDRA_VERSION} ready at ${APP} ($(du -sh "$APP" | cut -f1))"
