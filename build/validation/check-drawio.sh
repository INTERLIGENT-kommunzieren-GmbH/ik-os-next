#!/bin/bash
# Check the pinned draw.io release against upstream (ADR 0016).
#
# draw.io is the one GUI application not delivered by Flathub, so nothing updates
# it on its own: the version in the image is whatever config/desktop/drawio.env
# pins, and it only moves when someone runs
# scripts/maintenance/update-drawio.sh.
#
# The whole reason for choosing the .deb over the end-of-life Flatpak was to stop
# shipping a frozen Electron runtime. A pin nobody notices going stale rebuilds
# that exact problem, minus the Flathub warning that would have said so — so this
# check exists to say so.
#
# It WARNS rather than fails. Upstream releases every few days; failing would turn
# every one of them into a red build on work that has nothing to do with draw.io,
# and a check that blocks unrelated work gets disabled rather than acted on.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PIN="${REPO}/config/desktop/drawio.env"
[[ -r "$PIN" ]] || { echo "no draw.io pin at ${PIN}"; exit 1; }

# shellcheck source=config/desktop/drawio.env
. "$PIN"

pinned="${DRAWIO_VERSION:-}"
[[ -n "$pinned" ]] || { echo "DRAWIO_VERSION is not set in ${PIN}"; exit 1; }

[[ "${DRAWIO_DEB_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "  ✗ DRAWIO_DEB_SHA256 is not a sha256 digest — the build will refuse this pin."
    echo "     Re-run scripts/maintenance/update-drawio.sh"
    exit 1
}

echo "draw.io pinned at ${pinned}"

API=https://api.github.com/repos/jgraph/drawio-desktop/releases/latest

# Same three-way handling as check-brewfile.sh: an unreachable API is "unknown",
# never "up to date". A rate-limited GitHub must not read as a clean result.
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
if [[ -z "$latest" ]]; then
    echo "  ? the releases API returned no tag_name — upstream layout changed?"
    exit 0
fi

if [[ "$latest" == "$pinned" ]]; then
    echo "  ✓ up to date with upstream (${latest})"
    exit 0
fi

# sort -V decides which way the difference runs: a pin *ahead* of the latest
# release means a prerelease or a hand-edited version, which is a different
# problem and should not read as "please update".
newer=$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -1)
if [[ "$newer" == "$pinned" ]]; then
    echo "  ⚠ pinned ${pinned} is NEWER than the latest release ${latest}."
    echo "     /releases/latest excludes prereleases, so this is probably a"
    echo "     prerelease pin. Confirm that is deliberate."
    exit 0
fi

echo "  ⚠ upstream is at ${latest}, the image ships ${pinned}"
echo "     draw.io bundles its own Chromium and nothing updates it but this pin."
echo "     To move it:  scripts/maintenance/update-drawio.sh"
