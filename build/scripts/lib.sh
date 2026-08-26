#!/bin/bash
# Common helpers for ik-os build scripts.

set -euo pipefail

CTX="${CTX:-/ctx}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1091
load_env() {
    [[ -f "${CTX}/config/image.env" ]] || die "config/image.env missing from build context"
    set -a
    . "${CTX}/config/image.env"
    set +a
}

# Read a package list, stripping comments and blank lines.
# Justification comments live after the package name and are dropped here.
read_pkglist() {
    local f="$1"
    [[ -f "$f" ]] || die "package list not found: $f"
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$f" | grep -v '^$' || true
}

apt_install() {
    (( $# )) || return 0
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# Install every package list passed as an argument, as one transaction so apt
# can resolve conflicts across groups.
apt_install_lists() {
    local -a pkgs=()
    local f
    for f in "$@"; do
        info "reading $(basename "$(dirname "$f")")/$(basename "$f")"
        mapfile -t -O "${#pkgs[@]}" pkgs < <(read_pkglist "$f")
    done
    info "installing ${#pkgs[@]} packages"
    apt_install "${pkgs[@]}"
}

# NOTE: these helpers are for TEXT output only. Command substitution discards
# null bytes, so a binary file (a compiled dconf database, an initramfs) will
# never match. Grep such files directly with `grep -qaF pattern file`.
#
# Grep a command's output without tripping `set -o pipefail`.
# `grep -q` exits on the first match, the producer gets SIGPIPE, and pipefail
# then reports the whole pipeline as failed even though the match succeeded.
# Capture first, match second.
output_matches() {
    local pattern="$1"; shift
    local out
    out=$("$@" 2>/dev/null) || true
    grep -q -- "$pattern" <<<"$out"
}
output_matches_fixed() {
    local pattern="$1"; shift
    local out
    out=$("$@" 2>/dev/null) || true
    grep -qF -- "$pattern" <<<"$out"
}

# Resolve the kernel version actually installed into /usr/lib/modules.
installed_kver() {
    local d
    d=$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort -V | tail -1)
    [[ -n "$d" ]] || die "no kernel found under /usr/lib/modules"
    printf '%s' "$d"
}
