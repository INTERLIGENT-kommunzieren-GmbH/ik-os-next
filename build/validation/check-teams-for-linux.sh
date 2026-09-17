#!/bin/bash
# Check the Teams pieces that can be checked without building (ADR 0020):
#
#   1. the background assets pair up and fit in the slots  -- FAILS
#   2. the Flatpak has not crept back into the list        -- FAILS
#   3. the pinned client is current with upstream          -- WARNS
#
# The first two are repository invariants: they are wrong now and they are
# cheap to fix now, so failing here saves a twenty-minute image build that ends
# in the same message. The third is upstream's release cadence, which has
# nothing to do with whoever is running CI — failing on it would turn every
# teams-for-linux release into a red build on unrelated work, and a check that
# blocks unrelated work gets disabled rather than acted on (same reasoning as
# check-drawio.sh).
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PIN="${REPO}/config/desktop/teams-for-linux.env"
BGS="${REPO}/branding/teams-backgrounds"
FLATPAKS="${REPO}/config/desktop/system-flatpaks.list"

[[ -r "$PIN" ]] || { echo "no teams-for-linux pin at ${PIN}"; exit 1; }

# shellcheck source=config/desktop/teams-for-linux.env
. "$PIN"

pinned="${TEAMS_VERSION:-}"
[[ -n "$pinned" ]] || { echo "TEAMS_VERSION is not set in ${PIN}"; exit 1; }

[[ "${TEAMS_DEB_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "  ✗ TEAMS_DEB_SHA256 is not a sha256 digest — the build will refuse this pin."
    echo "     Re-run scripts/maintenance/update-teams-for-linux.sh"
    exit 1
}

echo "teams-for-linux pinned at ${pinned}"

# --- 1. the backgrounds ----------------------------------------------------
fail=0
mapfile -t images < <(find "$BGS" -maxdepth 1 -name '*.jpg' ! -name '*-thumb.jpg' \
                      -printf '%f\n' | sed 's/\.jpg$//' | sort)

if (( ${#images[@]} == 0 )); then
    echo "  ✗ no images in branding/teams-backgrounds/ — the picker would show"
    echo "     Microsoft's own assets in every slot."
    fail=1
fi

for name in "${images[@]}"; do
    if [[ ! -r "${BGS}/${name}-thumb.jpg" ]]; then
        echo "  ✗ ${name}.jpg has no ${name}-thumb.jpg"
        echo "     Regenerate the pair: scripts/maintenance/render-teams-backgrounds.sh"
        fail=1
    fi
done

slots=$(grep -cv '^[[:space:]]*#\|^[[:space:]]*$' "${BGS}/slots.txt")
if (( slots < ${#images[@]} )); then
    echo "  ✗ ${slots} slots in slots.txt for ${#images[@]} images — every image past"
    echo "     the ${slots}th is installed and can never appear in the picker."
    fail=1
fi
(( fail )) || echo "  ✓ ${#images[@]} backgrounds, each with a thumbnail, in ${slots} slots"

# --- 2. one Teams, not two -------------------------------------------------
# Comments stripped first: the list explains in prose where Teams went, and
# that explanation names the id. Captured rather than piped into `grep -q`,
# which under `set -o pipefail` reports a successful match as a failure when
# the producer dies on SIGPIPE.
flatpak_ids=$(grep -v '^[[:space:]]*#' "$FLATPAKS" || true)
if grep -qF 'teams_for_linux' <<<"$flatpak_ids"; then
    echo "  ✗ com.github.IsmaelMartinez.teams_for_linux is back in system-flatpaks.list."
    echo "     First boot would install the Flatpak alongside the packaged client:"
    echo "     two launcher entries, two profiles, and only one of them reading"
    echo "     /etc/teams-for-linux/config.json."
    fail=1
else
    echo "  ✓ the Flathub build is not also installed"
fi

(( fail == 0 )) || exit 1

# --- 3. staleness (warning only) -------------------------------------------
API=https://api.github.com/repos/IsmaelMartinez/teams-for-linux/releases/latest

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

newer=$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -1)
if [[ "$newer" == "$pinned" ]]; then
    echo "  ⚠ pinned ${pinned} is NEWER than the latest release ${latest}."
    echo "     Probably a prerelease pin. Confirm that is deliberate."
    exit 0
fi

echo "  ⚠ upstream is at ${latest}, the image ships ${pinned}"
echo "     Teams no longer updates from Flathub: this pin is the only mechanism,"
echo "     and it is a chat client rendering untrusted content in its own Chromium."
echo "     To move it:  scripts/maintenance/update-teams-for-linux.sh"
