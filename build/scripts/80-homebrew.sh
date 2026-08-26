#!/bin/bash
# SDD §16 — Homebrew as the developer/application package manager.
# Rule 4: never used for kernel, systemd, bootloader or core system packages.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Preparing Homebrew"

# Homebrew lives in /home/linuxbrew, which is persistent state under /var/home.
# The image only carries the bootstrap and the company Brewfile; the install
# itself happens on first boot, because Homebrew refuses to run as root and
# must not become part of the immutable layer.
install -Dm0644 "${CTX}/config/desktop/Brewfile" /usr/share/ik-os/Brewfile

# Debian only sources /etc/profile.d, not /usr/lib/profile.d. /etc is shipped
# and 3-way merged by ostree, so the snippet lives there directly.
mkdir -p /etc/profile.d
cat > /etc/profile.d/ik-os-homebrew.sh <<'EOF'
# Add Homebrew to the environment when it is installed.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
EOF
chmod 0644 /etc/profile.d/ik-os-homebrew.sh

# Debian's /etc/bash.bashrc contains the /etc/profile.d loop but leaves it
# commented out, and GNOME Terminal starts an interactive NON-login shell. So a
# profile.d snippet alone puts brew on PATH under `sudo -i` and nowhere else —
# which the user experiences as "brew: command not found" in every terminal.
if ! output_matches_fixed 'ik-os-homebrew' cat /etc/bash.bashrc; then
    cat >> /etc/bash.bashrc <<'EOF'

# ik-os: Homebrew is set up in a profile.d snippet, which only login shells
# read. Source it here so interactive non-login shells get it too.
if [ -r /etc/profile.d/ik-os-homebrew.sh ]; then
    . /etc/profile.d/ik-os-homebrew.sh
fi
EOF
fi

cat > /usr/lib/tmpfiles.d/ik-os-homebrew.conf <<'EOF'
d /var/home/linuxbrew 0755 root root -
EOF

