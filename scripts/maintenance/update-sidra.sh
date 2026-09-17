#!/bin/bash
# Move the Sidra pin in config/desktop/sidra.env to a newer upstream release
# (ADR 0019).
#
# Sidra ships as a .deb from GitHub releases and exists on no Flatpak remote, so
# nothing updates it on its own: the version in the image is whatever this file
# pins, and it only moves when someone runs this. Electron applications carry
# their own Chromium, so a stale pin is a stale browser engine.
#
# Usage:  scripts/maintenance/update-sidra.sh [VERSION]
#         no VERSION  -> the latest upstream release
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PIN="${REPO}/config/desktop/sidra.env"
API=https://api.github.com/repos/wimpysworld/sidra/releases

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl      >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"
[[ -w "$PIN" ]] || die "cannot write ${PIN}"

current=$(sed -nE 's/^SIDRA_VERSION=(.+)$/\1/p' "$PIN")

if (( $# )); then
    version="${1#v}"
else
    log "Resolving the latest Sidra release"
    version=$(curl -fsSL "${API}/latest" \
              | sed -nE 's/.*"tag_name": *"v?([^"]+)".*/\1/p' | head -1)
    [[ -n "$version" ]] || die "could not read the latest release tag from ${API}/latest"
fi

info "pinned now: ${current:-none}"
info "moving to : ${version}"

if [[ "$version" == "$current" ]]; then
    log "Already pinned to ${version} — nothing to do"
    exit 0
fi

# Upstream tags without a leading "v" and names the artefact after the tag.
DEB="Sidra-${version}-linux-amd64.deb"
URL="https://github.com/wimpysworld/sidra/releases/download/${version}/${DEB}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log "Downloading ${DEB}"
info "$URL"
# ~98 MiB. Downloaded in full because the checksum is the point: upstream
# publishes no signature and no digest, so what this records is "what was
# actually served when a human ran this".
curl -fL --retry 3 --retry-delay 2 --retry-all-errors --progress-bar \
     -o "${tmp}/${DEB}" "$URL" \
    || die "download failed. Check that ${version} exists and ships an amd64
       .deb: https://github.com/wimpysworld/sidra/releases/tag/${version}"

sha=$(sha256sum "${tmp}/${DEB}" | cut -d' ' -f1)
size=$(stat -c '%s' "${tmp}/${DEB}")
info "sha256: ${sha}"
info "size  : $(( size / 1024 / 1024 )) MiB"

# Sanity-check it is the package we think it is before pinning it, so a GitHub
# error page cannot become the pinned artefact.
if command -v dpkg-deb >/dev/null; then
    pkg=$(dpkg-deb -f "${tmp}/${DEB}" Package 2>/dev/null || true)
    ver=$(dpkg-deb -f "${tmp}/${DEB}" Version 2>/dev/null || true)
    [[ "$pkg" == "sidra" ]] || die "the downloaded file declares Package=${pkg:-<none>},
       expected sidra. Not pinning it."
    [[ "$ver" == "$version" ]] || die "the downloaded .deb declares Version=${ver},
       but the release is tagged ${version}. Not pinning a mismatch."
    info "verified: ${pkg} ${ver}"
else
    # dpkg-deb is absent on non-Debian hosts; the ar header is still checkable.
    head -c 8 "${tmp}/${DEB}" | grep -q '^!<arch>' \
        || die "the downloaded file is not a .deb archive. Not pinning it."
    info "no dpkg-deb here — verified the ar header only"
fi

log "Updating ${PIN}"
sed -i -e "s|^SIDRA_VERSION=.*|SIDRA_VERSION=${version}|" \
       -e "s|^SIDRA_DEB_SHA256=.*|SIDRA_DEB_SHA256=${sha}|" "$PIN"

# Both lines must have changed, or the pin is now internally inconsistent — a
# new version against an old checksum fails the build with a confusing message.
grep -q "^SIDRA_VERSION=${version}$"  "$PIN" || die "failed to write SIDRA_VERSION"
grep -q "^SIDRA_DEB_SHA256=${sha}$"   "$PIN" || die "failed to write SIDRA_DEB_SHA256"

log "Pinned Sidra ${version}"
info "review the diff and commit config/desktop/sidra.env"
info "the next image build will download and verify this exact artefact"
