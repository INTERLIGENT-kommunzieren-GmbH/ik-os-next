#!/bin/bash
# SDD §44 — package validation. Every name in packages/*.list must exist and be
# installable together, so a typo fails CI in seconds instead of mid-build.
set -euo pipefail
REPO="${REPO:-/repo}"
export DEBIAN_FRONTEND=noninteractive

install -Dm0644 "${REPO}/config/apt/debian.sources"          /etc/apt/sources.list.d/debian.sources
install -Dm0644 "${REPO}/config/apt/99-ik-os-backports.pref" /etc/apt/preferences.d/99-ik-os
rm -f /etc/apt/sources.list

# The vendor repositories the image uses must be configured here too, or their
# packages look "missing" and the validation is a false negative. The vendor
# repo is HTTPS, so ca-certificates has to come from the Debian archive first.
# shellcheck disable=SC1090
. "${REPO}/config/image.env"
apt-get update -qq
if [[ "${CLAUDE_DESKTOP:-false}" == "true" ]]; then
    apt-get install -y -qq ca-certificates gnupg >/dev/null
    install -Dm0644 "${REPO}/config/apt/keyrings/claude-desktop-archive-keyring.asc" \
        /usr/share/keyrings/claude-desktop-archive-keyring.asc
    install -Dm0644 "${REPO}/config/apt/claude-desktop.sources" \
        /etc/apt/sources.list.d/claude-desktop.sources
fi

apt-get update -qq

mapfile -t pkgs < <(cat "${REPO}"/packages/*/*.list \
    | sed -e 's/#.*//' -e 's/[[:space:]]*$//' | grep -v '^$' | sort -u)

echo "validating ${#pkgs[@]} packages"
missing=()
for p in "${pkgs[@]}"; do
    apt-cache show "$p" >/dev/null 2>&1 || missing+=("$p")
done
if (( ${#missing[@]} )); then
    printf 'not in the Debian archive:\n'; printf '  %s\n' "${missing[@]}"
    exit 1
fi
echo "all package names resolve; checking that they install together"
apt-get install -s -y --no-install-recommends "${pkgs[@]}" > /tmp/sim.txt || {
    tail -30 /tmp/sim.txt; echo "dependency resolution failed"; exit 1; }

# shellcheck disable=SC1090
. "${REPO}/config/image.env"
# Capture before matching: `grep -q` would SIGPIPE apt-cache and pipefail
# would then report a successful match as a failure.
madison=$(apt-cache madison "${KERNEL_PACKAGE}" || true)
if ! grep -qF -- "${KERNEL_VERSION}" <<<"$madison"; then
    echo "pinned kernel ${KERNEL_VERSION} is no longer available"
    echo "$madison"
    exit 1
fi
echo "kernel ${KERNEL_PACKAGE}=${KERNEL_VERSION} available"
echo "package validation passed"
