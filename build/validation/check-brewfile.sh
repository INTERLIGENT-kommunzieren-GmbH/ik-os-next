#!/bin/bash
# Validate config/desktop/Brewfile against the actual taps (SDD §16).
#
# Homebrew only runs on first boot, so a wrong entry here is not caught by the
# image build: it fails silently on every laptop instead. The classic mistake is
# `brew "x"` for something the tap ships as a cask, which resolves to nothing.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BREWFILE="${REPO}/config/desktop/Brewfile"
[[ -r "$BREWFILE" ]] || { echo "no Brewfile at ${BREWFILE}"; exit 1; }

# api.github.com allows 60 unauthenticated requests per hour per IP, which a
# shared CI runner will already have spent. Use GH_TOKEN when it is available.
gh_curl() {
    if [[ -n "${GH_TOKEN:-}" ]]; then
        curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" "$@"
    else
        curl -fsSL "$@"
    fi
}

# Same request, but reporting the HTTP status instead of failing on it: writes
# the body to $1 and prints the status code. A tap that ships only formulae has
# no Casks directory at all, and that 404 must not be confused with a tap that
# cannot be read (renamed, private, or a rate-limited runner).
gh_code() {
    local out="$1"; shift
    local args=(-sSL -o "$out" -w '%{http_code}')
    [[ -n "${GH_TOKEN:-}" ]] && args+=(-H "Authorization: Bearer ${GH_TOKEN}")
    curl "${args[@]}" "$@" 2>/dev/null || echo 000
}

strip() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$BREWFILE" | grep -v '^[[:space:]]*$'; }
entries() { strip | sed -nE "s/^${1} \"([^\"]+)\".*/\1/p"; }

mapfile -t TAPS  < <(entries tap)
mapfile -t BREWS < <(entries brew)
mapfile -t CASKS < <(entries cask)

echo "Brewfile: ${#TAPS[@]} tap(s), ${#BREWS[@]} formula(e), ${#CASKS[@]} cask(s)"

fail=0
note() { echo "  ✗ $*"; fail=1; }

# Casks are not served by homebrew/core. They come either from a tap this same
# file declares, or from homebrew/cask — which was macOS-only for years, but
# current Homebrew does install its font casks on Linux via the internal
# formulae.brew.sh API. So homebrew/cask is checked as a fallback below rather
# than rejected outright.

# Build the inventory of every declared third-party tap.
# Counted separately: under `set -u`, ${#assoc[@]} on an associative array that
# never had an element assigned is an unbound-variable error, not 0.
declare -A TAP_FORMULA TAP_CASK
n_formula=0 n_cask=0
for tap in "${TAPS[@]}"; do
    owner="${tap%%/*}"; name="${tap#*/}"
    # Homebrew strips the "homebrew-" prefix; the repository carries it.
    repo="homebrew-${name#homebrew-}"
    echo "  fetching ${owner}/${repo}"
    body=$(mktemp); found=no
    for kind in Formula Casks; do
        code=$(gh_code "$body" "https://api.github.com/repos/${owner}/${repo}/contents/${kind}")
        case "$code" in
            200) ;;
            # Most taps ship only one of the two. Absence is normal; report it
            # only if BOTH are missing, which means the tap name is wrong.
            404) continue ;;
            *)   note "cannot read ${owner}/${repo}/${kind} (HTTP ${code}) — tap renamed, private, or rate-limited"
                 continue ;;
        esac
        found=yes
        while IFS= read -r n; do
            if [[ "$kind" == Formula ]]; then
                TAP_FORMULA["$n"]="$tap"; n_formula=$(( n_formula + 1 ))
            else
                TAP_CASK["$n"]="$tap"; n_cask=$(( n_cask + 1 ))
            fi
        done < <(sed -nE 's/.*"name": "([^"]+)\.rb".*/\1/p' "$body")
    done
    rm -f "$body"
    [[ "$found" == yes ]] || note "tap ${tap} has neither a Formula nor a Casks directory — check the name"
done
echo "  taps provide ${n_formula} formula(e) and ${n_cask} cask(s)"

for c in "${CASKS[@]}"; do
    short="${c##*/}"
    if [[ -n "${TAP_CASK[$short]:-}" ]]; then
        echo "  ✓ cask ${short} (${TAP_CASK[$short]})"
    elif [[ -n "${TAP_FORMULA[$short]:-}" ]]; then
        note "cask \"${short}\" is a FORMULA in ${TAP_FORMULA[$short]} — use brew \"${short}\""
    elif curl -fsSL -o /dev/null "https://formulae.brew.sh/api/cask/${short}.json" 2>/dev/null; then
        echo "  ✓ cask ${short} (homebrew/cask)"
    else
        note "cask \"${short}\" is in neither homebrew/cask nor a declared tap"
    fi
done

for b in "${BREWS[@]}"; do
    short="${b##*/}"
    if [[ -n "${TAP_FORMULA[$short]:-}" ]]; then
        echo "  ✓ formula ${short} (${TAP_FORMULA[$short]})"
    elif [[ -n "${TAP_CASK[$short]:-}" ]]; then
        note "brew \"${short}\" is a CASK in ${TAP_CASK[$short]} — use cask \"${short}\""
    elif curl -fsSL -o /dev/null "https://formulae.brew.sh/api/formula/${short}.json" 2>/dev/null; then
        echo "  ✓ formula ${short} (homebrew/core)"
    else
        note "brew \"${short}\" is neither in homebrew/core nor a declared tap"
    fi
done

# A formula in one tap can depend on a formula in ANOTHER tap. Homebrew refuses
# to load that dependency unless its tap is both tapped and trusted, and
# `brew bundle install` then exits 0 having installed nothing — which is exactly
# how four PHP extensions silently failed on a booted image.
#
# The dependency is often NOT in the formula file. shivammathur's extensions
# each `require` an Abstract base class, and it is that class which declares
#
#     depends_on "shivammathur/php/php@#{@php_version}" => [:build, :test]
#
# so a tap's Abstract/ directory has to be read too. Interpolation does not
# matter here: only the tap part of the reference is needed, and that is literal.
#
# ik-os-homebrew trusts and taps every `tap` line, so declaring the other tap is
# always the fix. raw.githubusercontent is fetched WITHOUT the token — it does
# not share the API rate limit, so this costs nothing against those 60 requests.
declared_tap() {
    local t
    for t in "${TAPS[@]}"; do [[ "$t" == "$1" ]] && return 0; done
    return 1
}
# Emits every "owner/tap/formula" reference a depends_on line names.
cross_tap_deps() {
    sed -nE 's/.*depends_on "([^"]+\/[^"]+\/[^"]+)".*/\1/p' | sort -u
}
check_cross_tap() {
    local src="$1" origin="$2" dep deptap
    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        deptap="${dep%/*}"
        if declared_tap "$deptap"; then
            echo "  ✓ ${origin} needs ${deptap} (declared)"
        else
            note "${origin} depends on ${dep}, but tap \"${deptap}\" is NOT declared.
       Homebrew refuses to load a formula from an untrusted tap, and
       bundle install would report success while installing nothing.
       Add: tap \"${deptap}\""
        fi
    done < <(printf '%s' "$src" | cross_tap_deps)
}

# The Abstract base classes of every declared tap.
for tap in "${TAPS[@]}"; do
    owner="${tap%%/*}"; name="${tap#*/}"
    repo="homebrew-${name#homebrew-}"
    listing=$(gh_curl "https://api.github.com/repos/${owner}/${repo}/contents/Abstract" 2>/dev/null) || continue
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        src=$(curl -fsSL "https://raw.githubusercontent.com/${owner}/${repo}/HEAD/Abstract/${n}.rb" 2>/dev/null) \
            || { note "cannot read ${tap} Abstract/${n}.rb"; continue; }
        check_cross_tap "$src" "${tap} (${n})"
    done < <(printf '%s' "$listing" | sed -nE 's/.*"name": "([^"]+)\.rb".*/\1/p')
done

# ...and each named tap formula itself.
for b in "${BREWS[@]}"; do
    [[ "$b" == */*/* ]] || continue
    owner="${b%%/*}"; rest="${b#*/}"
    name="${rest%%/*}"; formula="${rest#*/}"
    repo="homebrew-${name#homebrew-}"
    src=$(curl -fsSL "https://raw.githubusercontent.com/${owner}/${repo}/HEAD/Formula/${formula}.rb" 2>/dev/null) \
        || { note "cannot read the source of ${b} to check its cross-tap dependencies"; continue; }
    check_cross_tap "$src" "brew \"${b}\""
done

(( fail == 0 )) || { echo "Brewfile validation failed"; exit 1; }
echo "Brewfile validation passed"
