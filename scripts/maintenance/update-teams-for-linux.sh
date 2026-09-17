#!/bin/bash
# Move the teams-for-linux pin in config/desktop/teams-for-linux.env to a newer
# upstream release (ADR 0020).
#
# Teams used to come from Flathub and updated itself. It does not any more: the
# version in the image is whatever this file pins, and it only moves when
# someone runs this. That is the standing cost of taking it off Flathub, and it
# lands on a communication client that renders untrusted content in its own
# bundled Chromium — so this is the one pin worth moving promptly.
#
# Usage:  scripts/maintenance/update-teams-for-linux.sh [VERSION]
#         no VERSION  -> the latest upstream release
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PIN="${REPO}/config/desktop/teams-for-linux.env"
API=https://api.github.com/repos/IsmaelMartinez/teams-for-linux/releases

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl      >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"
[[ -w "$PIN" ]] || die "cannot write ${PIN}"

current=$(sed -nE 's/^TEAMS_VERSION=(.+)$/\1/p' "$PIN")

if (( $# )); then
    version="${1#v}"
else
    log "Resolving the latest teams-for-linux release"
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

# Upstream tags with a leading "v" but names the .deb without it.
DEB="teams-for-linux_${version}_amd64.deb"
URL="https://github.com/IsmaelMartinez/teams-for-linux/releases/download/v${version}/${DEB}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log "Downloading ${DEB}"
info "$URL"
# ~108 MiB. Downloaded in full because the checksum is the point: upstream
# publishes no signature and no digest, so what this records is "what was
# actually served when a human ran this".
curl -fL --retry 3 --retry-delay 2 --retry-all-errors --progress-bar \
     -o "${tmp}/${DEB}" "$URL" \
    || die "download failed. Check that v${version} exists and ships an amd64
       .deb: https://github.com/IsmaelMartinez/teams-for-linux/releases/tag/v${version}"

sha=$(sha256sum "${tmp}/${DEB}" | cut -d' ' -f1)
size=$(stat -c '%s' "${tmp}/${DEB}")
info "sha256: ${sha}"
info "size  : $(( size / 1024 / 1024 )) MiB"

if command -v dpkg-deb >/dev/null; then
    pkg=$(dpkg-deb -f "${tmp}/${DEB}" Package 2>/dev/null || true)
    ver=$(dpkg-deb -f "${tmp}/${DEB}" Version 2>/dev/null || true)
    [[ "$pkg" == "teams-for-linux" ]] || die "the downloaded file declares
       Package=${pkg:-<none>}, expected teams-for-linux. Not pinning it."
    [[ "$ver" == "$version" ]] || die "the downloaded .deb declares Version=${ver},
       but the release is tagged v${version}. Not pinning a mismatch."
    info "verified: ${pkg} ${ver}"
else
    head -c 8 "${tmp}/${DEB}" | grep -q '^!<arch>' \
        || die "the downloaded file is not a .deb archive. Not pinning it."
    info "no dpkg-deb here — verified the ar header only"
fi

log "Updating ${PIN}"
sed -i -e "s|^TEAMS_VERSION=.*|TEAMS_VERSION=${version}|" \
       -e "s|^TEAMS_DEB_SHA256=.*|TEAMS_DEB_SHA256=${sha}|" "$PIN"

grep -q "^TEAMS_VERSION=${version}$"  "$PIN" || die "failed to write TEAMS_VERSION"
grep -q "^TEAMS_DEB_SHA256=${sha}$"   "$PIN" || die "failed to write TEAMS_DEB_SHA256"

log "Pinned teams-for-linux ${version}"
info "review the diff and commit config/desktop/teams-for-linux.env"
info "the next image build will download and verify this exact artefact"
