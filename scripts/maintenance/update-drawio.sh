#!/bin/bash
# Move the draw.io pin in config/desktop/drawio.env to a newer upstream release
# (ADR 0016).
#
# draw.io ships as a .deb from GitHub releases rather than as a Flatpak or an APT
# package, so nothing updates it on its own: the version in the image is whatever
# this file pins, and it only moves when someone runs this. That is the standing
# cost of the ADR 0016 decision, and this script is the whole of it.
#
# Usage:  scripts/maintenance/update-drawio.sh [VERSION]
#         no VERSION  -> the latest upstream release
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PIN="${REPO}/config/desktop/drawio.env"
API=https://api.github.com/repos/jgraph/drawio-desktop/releases

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl     >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"
[[ -w "$PIN" ]] || die "cannot write ${PIN}"

current=$(sed -nE 's/^DRAWIO_VERSION=(.+)$/\1/p' "$PIN")

if (( $# )); then
    version="${1#v}"
else
    log "Resolving the latest draw.io release"
    # Prereleases are excluded: /releases/latest already skips them, and drawio
    # publishes them regularly.
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

DEB="drawio-amd64-${version}.deb"
URL="https://github.com/jgraph/drawio-desktop/releases/download/v${version}/${DEB}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log "Downloading ${DEB}"
info "$URL"
# ~127 MiB. Downloaded in full because the checksum is the point: there is no
# upstream signature or published digest to compare against, so the digest this
# records is "what was actually served when a human ran this".
curl -fL --retry 3 --retry-delay 2 --retry-all-errors --progress-bar \
     -o "${tmp}/${DEB}" "$URL" \
    || die "download failed. Check that v${version} exists and ships an amd64
       .deb: https://github.com/jgraph/drawio-desktop/releases/tag/v${version}"

sha=$(sha256sum "${tmp}/${DEB}" | cut -d' ' -f1)
size=$(stat -c '%s' "${tmp}/${DEB}")
info "sha256: ${sha}"
info "size  : $(( size / 1024 / 1024 )) MiB"

# Sanity-check it is the package we think it is before pinning it, so a GitHub
# error page or an LFS pointer cannot become the pinned artefact.
if command -v dpkg-deb >/dev/null; then
    pkg=$(dpkg-deb -f "${tmp}/${DEB}" Package 2>/dev/null || true)
    ver=$(dpkg-deb -f "${tmp}/${DEB}" Version 2>/dev/null || true)
    [[ "$pkg" == "draw.io" ]] || die "the downloaded file declares Package=${pkg:-<none>},
       expected draw.io. Not pinning it."
    [[ "$ver" == "$version" ]] || die "the downloaded .deb declares Version=${ver},
       but the release is tagged v${version}. Not pinning a mismatch."
    info "verified: ${pkg} ${ver}"
else
    # dpkg-deb is absent on non-Debian hosts; the ar header is still checkable.
    head -c 8 "${tmp}/${DEB}" | grep -q '^!<arch>' \
        || die "the downloaded file is not a .deb archive. Not pinning it."
    info "no dpkg-deb here — verified the ar header only"
fi

log "Updating ${PIN}"
sed -i -e "s|^DRAWIO_VERSION=.*|DRAWIO_VERSION=${version}|" \
       -e "s|^DRAWIO_DEB_SHA256=.*|DRAWIO_DEB_SHA256=${sha}|" "$PIN"

# Both lines must have changed, or the pin is now internally inconsistent — a new
# version against an old checksum fails the build with a confusing message.
grep -q "^DRAWIO_VERSION=${version}$"     "$PIN" || die "failed to write DRAWIO_VERSION"
grep -q "^DRAWIO_DEB_SHA256=${sha}$"      "$PIN" || die "failed to write DRAWIO_DEB_SHA256"

log "Pinned draw.io ${version}"
info "review the diff and commit config/desktop/drawio.env"
info "the next image build will download and verify this exact artefact"
