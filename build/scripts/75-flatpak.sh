#!/bin/bash
# SDD §15 — Flatpak with Flathub as the default application source.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Configuring Flatpak"

# The remote is added to the *system* installation at first boot. It is also
# baked into the /var/lib/flatpak the Containerfile copies in, so this is
# belt-and-braces for machines that already had a /var (ADR 0014).
install -Dm0644 "${CTX}/config/desktop/flathub.flatpakrepo" \
    /usr/lib/ik-os/flatpak/flathub.flatpakrepo
install -Dm0644 "${CTX}/config/desktop/system-flatpaks.list" \
    /usr/share/ik-os/system-flatpaks.list
# Shipped so the booted system can say which apps came with the image rather
# than from first boot -- verify-image.sh and support both need to know.
install -Dm0644 "${CTX}/config/desktop/preinstalled-flatpaks.list" \
    /usr/share/ik-os/preinstalled-flatpaks.list

# Every preinstalled app must be in the approved list too. The Containerfile
# stage checks this as well, but it runs in a separate stage that a
# `podman build --target` can skip, and this is the file the image ships.
while read -r app; do
    grep -qxF "$app" <(read_pkglist /usr/share/ik-os/system-flatpaks.list) \
        || die "${app} is in config/desktop/preinstalled-flatpaks.list but not in
       config/desktop/system-flatpaks.list. The approved list is the definition
       of the desktop; preinstalling is only a delivery decision."
done < <(read_pkglist /usr/share/ik-os/preinstalled-flatpaks.list)

cat > /usr/lib/tmpfiles.d/ik-os-flatpak.conf <<'EOF'
d /var/lib/flatpak 0755 root root -
EOF

info "system flatpak list:"
read_pkglist /usr/share/ik-os/system-flatpaks.list | sed 's/^/      /'
info "preinstalled in the image:"
read_pkglist /usr/share/ik-os/preinstalled-flatpaks.list | sed 's/^/      /'

# The shipped Flathub repo definition must carry a real signing key. A malformed
# or truncated key does not fail here — it fails at first boot, on every single
# install, with a signature error nobody connects back to this file.
log "Validating the Flathub repository definition"
FLATHUB_KEY=$(awk -F= '/^GPGKey=/{print substr($0, index($0,"=")+1)}' \
    /usr/lib/ik-os/flatpak/flathub.flatpakrepo)
[[ -n "$FLATHUB_KEY" ]] || die "flathub.flatpakrepo has no GPGKey"
KEY_UID=$(printf '%s' "$FLATHUB_KEY" | base64 -d 2>/dev/null \
    | gpg --show-keys --with-colons 2>/dev/null | awk -F: '/^uid/{print $10; exit}')
[[ -n "$KEY_UID" ]] || die "the GPGKey in flathub.flatpakrepo is not a usable
       OpenPGP key. Re-fetch it with:
         curl -sfL https://dl.flathub.org/repo/flathub.flatpakrepo \\
              -o config/desktop/flathub.flatpakrepo"
info "Flathub signing key: ${KEY_UID}"

# --- Claude Desktop -------------------------------------------------------
# Installed as an ordinary apt package from Anthropic's own repository
# (see packages/desktop/packages.list and 00-preflight.sh). Nothing to do here
# beyond confirming it landed.
if [[ "${CLAUDE_DESKTOP:-false}" == "true" ]]; then
    compgen -G '/usr/share/applications/*[Cc]laude*.desktop' >/dev/null \
        || die "CLAUDE_DESKTOP=true but no Claude Desktop launcher is installed.
       Check that 'claude-desktop' is in packages/desktop/packages.list and that
       Anthropic's repository resolved during 20-packages.sh."
    # dpkg's database is still at its default location here; 95-finalize.sh
    # relocates it to /usr/lib/dpkg only at the very end of the build.
    info "Claude Desktop $(dpkg-query -W -f='${Version}' claude-desktop)"
fi
