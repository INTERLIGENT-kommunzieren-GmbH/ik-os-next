#!/bin/bash
# Check the pinned DevPod release against upstream (ADR 0021).
#
# Two questions, and for this application the second one matters more:
#
#   1. is the pin behind upstream?     -- WARNS
#   2. has upstream stopped shipping?  -- WARNS, loudly, after a year
#
# DevPod came into the image because its Flathub build went end-of-life frozen
# at 0.6.10. Replacing one frozen copy with another frozen copy would be no
# better, so this check exists to notice if that is what has happened. It warns
# rather than fails: upstream going quiet is not a reason to redden somebody
# else's pull request, it is a reason to make a decision.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PIN="${REPO}/config/desktop/devpod.env"
FLATPAKS="${REPO}/config/desktop/system-flatpaks.list"
[[ -r "$PIN" ]] || { echo "no DevPod pin at ${PIN}"; exit 1; }

# shellcheck source=config/desktop/devpod.env
. "$PIN"

pinned="${DEVPOD_VERSION:-}"
[[ -n "$pinned" ]] || { echo "DEVPOD_VERSION is not set in ${PIN}"; exit 1; }

[[ "${DEVPOD_DEB_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "  ✗ DEVPOD_DEB_SHA256 is not a sha256 digest — the build will refuse this pin."
    echo "     Re-run scripts/maintenance/update-devpod.sh"
    exit 1
}

echo "DevPod pinned at ${pinned}"

# The end-of-life Flatpak must not come back: it would install alongside the
# package and sit in the launcher frozen at 0.6.10.
flatpak_ids=$(grep -v '^[[:space:]]*#' "$FLATPAKS" || true)
if grep -qF 'loft.devpod' <<<"$flatpak_ids"; then
    echo "  ✗ sh.loft.devpod is back in system-flatpaks.list. It is end-of-life on"
    echo "     Flathub and would install a second, frozen DevPod (ADR 0021)."
    exit 1
fi
echo "  ✓ the end-of-life Flathub build is not also installed"

API=https://api.github.com/repos/loft-sh/devpod/releases/latest

body=$(mktemp); trap 'rm -f "$body"' EXIT
code=$(curl -sSL -o "$body" -w '%{http_code}' \
       --retry 3 --retry-delay 2 --retry-all-errors --max-time 30 \
       ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
       "$API" 2>/dev/null || echo 000)

if [[ "$code" != 200 ]]; then
    echo "  ? cannot reach the GitHub releases API (HTTP ${code})"
    echo "     Not treated as up to date — re-run when the network allows."
    exit 0
fi

latest=$(sed -nE 's/.*"tag_name": *"v?([^"]+)".*/\1/p' "$body" | head -1)
published=$(sed -nE 's/.*"published_at": *"([0-9-]+)T.*/\1/p' "$body" | head -1)
if [[ -z "$latest" ]]; then
    echo "  ? the releases API returned no tag_name — upstream layout changed?"
    exit 0
fi

# Age of upstream's newest STABLE release. This is the signal that matters for
# DevPod: a pin that matches a release nobody has moved in a year is current
# and abandoned at the same time.
if [[ -n "$published" ]]; then
    age_days=$(( ( $(date -u +%s) - $(date -u -d "$published" +%s) ) / 86400 ))
    if (( age_days > 365 )); then
        echo "  ⚠ upstream's newest stable release (${latest}) is ${age_days} days old."
        echo "     DevPod is in the image because its Flatpak was frozen. If upstream"
        echo "     has stopped too, pinning a newer commit is not the answer —"
        echo "     decide whether to keep shipping it at all (ADR 0021)."
    else
        echo "  ✓ upstream released ${latest} ${age_days} days ago"
    fi
fi

if [[ "$latest" == "$pinned" ]]; then
    echo "  ✓ the pin matches the newest stable release (${latest})"
    exit 0
fi

newer=$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -1)
if [[ "$newer" == "$pinned" ]]; then
    echo "  ⚠ pinned ${pinned} is NEWER than the latest stable release ${latest}."
    echo "     Upstream publishes v0.7.0-alpha prereleases; confirm a prerelease"
    echo "     pin is deliberate."
    exit 0
fi

echo "  ⚠ upstream is at ${latest}, the image ships ${pinned}"
echo "     To move it:  scripts/maintenance/update-devpod.sh"
