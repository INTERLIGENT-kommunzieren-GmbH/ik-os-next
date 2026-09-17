#!/bin/bash
# Check the pinned Sidra release against upstream (ADR 0019).
#
# Sidra is on no Flatpak remote, so nothing updates it on its own: the version in
# the image is whatever config/desktop/sidra.env pins, and it only moves when
# someone runs scripts/maintenance/update-sidra.sh. It is an Electron
# application, so a stale pin is a stale Chromium.
#
# It WARNS rather than fails, for the same reason as check-drawio.sh: failing
# would turn every upstream release into a red build on unrelated work, and a
# check that blocks unrelated work gets disabled rather than acted on.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PIN="${REPO}/config/desktop/sidra.env"
[[ -r "$PIN" ]] || { echo "no Sidra pin at ${PIN}"; exit 1; }

# shellcheck source=config/desktop/sidra.env
. "$PIN"

pinned="${SIDRA_VERSION:-}"
[[ -n "$pinned" ]] || { echo "SIDRA_VERSION is not set in ${PIN}"; exit 1; }

[[ "${SIDRA_DEB_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "  ✗ SIDRA_DEB_SHA256 is not a sha256 digest — the build will refuse this pin."
    echo "     Re-run scripts/maintenance/update-sidra.sh"
    exit 1
}

echo "Sidra pinned at ${pinned}"

API=https://api.github.com/repos/wimpysworld/sidra/releases/latest

# An unreachable API is "unknown", never "up to date": a rate-limited GitHub
# must not read as a clean result.
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
# release is a prerelease or a hand-edited version, which is a different problem
# and should not read as "please update".
newer=$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -1)
if [[ "$newer" == "$pinned" ]]; then
    echo "  ⚠ pinned ${pinned} is NEWER than the latest release ${latest}."
    echo "     /releases/latest excludes prereleases, so this is probably a"
    echo "     prerelease pin. Confirm that is deliberate."
    exit 0
fi

echo "  ⚠ upstream is at ${latest}, the image ships ${pinned}"
echo "     Sidra bundles its own Chromium and nothing updates it but this pin."
echo "     To move it:  scripts/maintenance/update-sidra.sh"
