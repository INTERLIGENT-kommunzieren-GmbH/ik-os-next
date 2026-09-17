#!/bin/bash
# Move the DevPod pin in config/desktop/devpod.env to a newer upstream release
# (ADR 0021).
#
# The Flathub build is end-of-life, so nothing updates DevPod but this script.
# Note that upstream's own release cadence stopped: 0.6.15 is from 2025-03-10
# and everything since is a v0.7.0-alpha prerelease. If that has not changed by
# the time you read this, the question is not "which version" but "is DevPod
# still worth shipping" — see the ADR.
#
# Usage:  scripts/maintenance/update-devpod.sh [VERSION]
#         no VERSION  -> the latest stable upstream release (prereleases are
#                        excluded by /releases/latest, deliberately)
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PIN="${REPO}/config/desktop/devpod.env"
API=https://api.github.com/repos/loft-sh/devpod/releases

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl      >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"
[[ -w "$PIN" ]] || die "cannot write ${PIN}"

current=$(sed -nE 's/^DEVPOD_VERSION=(.+)$/\1/p' "$PIN")

if (( $# )); then
    version="${1#v}"
else
    log "Resolving the latest DevPod release"
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

DEB="DevPod_${version}_amd64.deb"
URL="https://github.com/loft-sh/devpod/releases/download/v${version}/${DEB}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

log "Downloading ${DEB}"
info "$URL"
curl -fL --retry 3 --retry-delay 2 --retry-all-errors --progress-bar \
     -o "${tmp}/${DEB}" "$URL" \
    || die "download failed. Check that v${version} exists and ships an amd64
       .deb: https://github.com/loft-sh/devpod/releases/tag/v${version}
       The prereleases publish an AppImage but not always a .deb."

sha=$(sha256sum "${tmp}/${DEB}" | cut -d' ' -f1)
size=$(stat -c '%s' "${tmp}/${DEB}")
info "sha256: ${sha}"
info "size  : $(( size / 1024 / 1024 )) MiB"

if command -v dpkg-deb >/dev/null; then
    pkg=$(dpkg-deb -f "${tmp}/${DEB}" Package 2>/dev/null || true)
    ver=$(dpkg-deb -f "${tmp}/${DEB}" Version 2>/dev/null || true)
    # Upstream's package name is "dev-pod", not "devpod". That is not a typo
    # here; it is what the control file says.
    [[ "$pkg" == "dev-pod" ]] || die "the downloaded file declares
       Package=${pkg:-<none>}, expected dev-pod. Not pinning it."
    [[ "$ver" == "$version" ]] || die "the downloaded .deb declares Version=${ver},
       but the release is tagged v${version}. Not pinning a mismatch."
    info "verified: ${pkg} ${ver}"
else
    head -c 8 "${tmp}/${DEB}" | grep -q '^!<arch>' \
        || die "the downloaded file is not a .deb archive. Not pinning it."
    info "no dpkg-deb here — verified the ar header only"
fi

log "Updating ${PIN}"
sed -i -e "s|^DEVPOD_VERSION=.*|DEVPOD_VERSION=${version}|" \
       -e "s|^DEVPOD_DEB_SHA256=.*|DEVPOD_DEB_SHA256=${sha}|" "$PIN"

grep -q "^DEVPOD_VERSION=${version}$" "$PIN" || die "failed to write DEVPOD_VERSION"
grep -q "^DEVPOD_DEB_SHA256=${sha}$"  "$PIN" || die "failed to write DEVPOD_DEB_SHA256"

log "Pinned DevPod ${version}"
info "review the diff and commit config/desktop/devpod.env"
