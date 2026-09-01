#!/bin/bash
# Regenerate the LsAgent pin in config/image.env (ADR 0017).
#
# Modelled on fetch-brother-driver.sh, with one deliberate difference: it does
# NOT vendor the payload into the repo. The .run is 33 MB, ~250x the largest
# binary this repo carries, and first boot downloads it directly.
#
# Usage:
#   scripts/maintenance/fetch-lsagent.sh              # re-verify the current pin
#   scripts/maintenance/fetch-lsagent.sh 10.4.2.1     # pin a specific version
#   scripts/maintenance/fetch-lsagent.sh --latest     # what the vendor points at
#
# IMPORTANT: --latest is informational. The constraint on this pin is what the
# on-prem scanning server accepts, not what the vendor publishes -- the version
# lines are per-platform and the CDN carries builds ahead of the download page.
# Confirm with IT before changing LSAGENT_VERSION.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
ENVFILE="${REPO}/config/image.env"
BASE=https://cdn.lansweeper.com/build/lsagent
LATEST_REDIRECT=https://content.lansweeper.com/lsagent-linux/

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1090
. "$ENVFILE"

case "${1:-}" in
    --latest)
        log "Asking the vendor what it considers latest for Linux"
        loc=$(curl -sI -m 20 "$LATEST_REDIRECT" \
              | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')
        [[ -n "$loc" ]] || die "no redirect from ${LATEST_REDIRECT}"
        info "vendor latest: ${loc##*/}"
        info "currently pinned: LsAgent-linux-x64_${LSAGENT_VERSION}.run"
        info ""
        info "These differ on purpose if IT pinned an older build. Do not bump"
        info "without confirming the scanning server accepts it (ADR 0017)."
        exit 0
        ;;
    "") VERSION="$LSAGENT_VERSION" ;;
    *)  VERSION="$1" ;;
esac

URL="${BASE}/LsAgent-linux-x64_${VERSION}.run"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RUN="${WORK}/lsagent.run"

log "Fetching LsAgent ${VERSION}"
info "$URL"
curl -fsSL -m 600 -o "$RUN" "$URL" \
    || die "not available at ${URL}.
       Not every version is published under this path. Check the vendor
       download page for what exists, and confirm with IT which build the
       scanning server accepts."

SIZE=$(stat -c '%s' "$RUN")
SHA=$(sha256sum "$RUN" | cut -d' ' -f1)

# A payload that first boot will execute as root: prove it is what we think it
# is before printing a checksum somebody will paste into the image.
FILETYPE=$(file -b "$RUN")
case "$FILETYPE" in
    *ELF*64-bit*x86-64*) info "payload: ${FILETYPE}" ;;
    *) die "unexpected payload type: ${FILETYPE}
       Expected a 64-bit x86-64 ELF self-extractor. Do not pin this." ;;
esac

log "Pin values for config/image.env"
cat <<EOF
LSAGENT_VERSION=${VERSION}
LSAGENT_URL="${URL}"
LSAGENT_SHA256=${SHA}
LSAGENT_SIZE=${SIZE}
EOF

if [[ "$VERSION" == "$LSAGENT_VERSION" ]]; then
    echo
    if [[ "$SHA" == "$LSAGENT_SHA256" ]]; then
        log "Unchanged: the pinned checksum still matches the vendor build"
    else
        die "THE VENDOR REPLACED THIS BUILD IN PLACE.
       pinned: ${LSAGENT_SHA256}
       now:    ${SHA}
       Same version, different bytes. Do not update the pin until that is
       explained -- first boot executes this as root."
    fi
fi
