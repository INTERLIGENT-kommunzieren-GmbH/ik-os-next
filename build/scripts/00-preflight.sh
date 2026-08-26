#!/bin/bash
# SDD §3 + §47 — resolve and record what the floating `stable` suite became.
# The build fails on an unapproved major-release transition.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Preflight: resolving the Debian stable suite"

install -Dm0644 "${CTX}/config/apt/debian.sources"          /etc/apt/sources.list.d/debian.sources
install -Dm0644 "${CTX}/config/apt/99-ik-os-backports.pref" /etc/apt/preferences.d/99-ik-os-backports
install -Dm0644 "${CTX}/config/apt/99-ik-os-immutable.conf" /etc/apt/apt.conf.d/99-ik-os
install -Dm0644 "${CTX}/config/apt/ik-os-dpkg.cfg"          /etc/dpkg/dpkg.cfg.d/ik-os

rm -f /etc/apt/sources.list

# Debian's archive is plain HTTP, so this first update works on a bare base
# image. The vendor repository below is HTTPS and needs ca-certificates, and
# the key check needs gnupg — neither is in debian:*-slim by default.
apt-get update
apt_install ca-certificates gnupg

# --- Anthropic's Claude Desktop repository (ADR 0007) ---------------------
if [[ "${CLAUDE_DESKTOP:-false}" == "true" ]]; then
    install -Dm0644 "${CTX}/config/apt/keyrings/claude-desktop-archive-keyring.asc" \
        /usr/share/keyrings/claude-desktop-archive-keyring.asc

    # Verify the shipped key really is Anthropic's before trusting anything it
    # signs. gpg needs a writable homedir, which /root is not at this point.
    GPG_HOME=$(mktemp -d)
    ACTUAL_FPR=$(gpg --homedir "$GPG_HOME" --show-keys --with-colons \
        /usr/share/keyrings/claude-desktop-archive-keyring.asc 2>/dev/null \
        | awk -F: '/^fpr/{print $10; exit}')
    KEY_UID=$(gpg --homedir "$GPG_HOME" --show-keys --with-colons \
        /usr/share/keyrings/claude-desktop-archive-keyring.asc 2>/dev/null \
        | awk -F: '/^uid/{print $10; exit}')
    rm -rf "$GPG_HOME"

    [[ "$ACTUAL_FPR" == "$CLAUDE_DESKTOP_KEY_FPR" ]] || die \
        "the Claude Desktop signing key does not match the pinned fingerprint.
       expected: ${CLAUDE_DESKTOP_KEY_FPR}
       actual:   ${ACTUAL_FPR:-<no key found>}
       Re-fetch it from https://downloads.claude.ai/claude-desktop/key.asc and
       check the fingerprint against https://code.claude.com/docs/en/desktop-linux"
    info "Claude Desktop signing key: ${KEY_UID}"

    install -Dm0644 "${CTX}/config/apt/claude-desktop.sources" \
        /etc/apt/sources.list.d/claude-desktop.sources
else
    info "CLAUDE_DESKTOP=false; Anthropic repository not configured"
fi

apt-get update

RESOLVED_CODENAME=$(awk -F= '/^VERSION_CODENAME=/{print $2}' /etc/os-release)
RESOLVED_VERSION=$(awk -F'"' '/^VERSION=/{print $2}' /etc/os-release)
[[ -n "$RESOLVED_CODENAME" ]] || die "could not determine the Debian codename"

info "stable resolved to: ${RESOLVED_CODENAME} (${RESOLVED_VERSION:-unknown})"

if [[ "$RESOLVED_CODENAME" != "$EXPECTED_DEBIAN_CODENAME" ]]; then
    die "Debian stable now resolves to '${RESOLVED_CODENAME}' but config/image.env pins
       EXPECTED_DEBIAN_CODENAME=${EXPECTED_DEBIAN_CODENAME}.

       This is a Debian major-release transition. SDD §47 forbids letting it reach
       the stable channel unvalidated. Open a release-transition ticket, validate on
       the hardware matrix, then bump EXPECTED_DEBIAN_CODENAME."
fi

mkdir -p /usr/share/ik-os
# Values are quoted: Debian's VERSION can be e.g. `14 (forky)` and these files
# are sourced by shell.
cat > /usr/share/ik-os/build-base.env <<EOF
DEBIAN_CODENAME="${RESOLVED_CODENAME}"
DEBIAN_VERSION="${RESOLVED_VERSION:-}"
DEBIAN_SUITE="${DEBIAN_SUITE}"
EOF
