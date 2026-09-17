#!/bin/bash
# SDD §37, §40, §50 — units and the service preset.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Installing systemd units"
for u in "${CTX}"/systemd/services/*.service "${CTX}"/systemd/timers/*.timer \
         "${CTX}"/systemd/paths/*.path; do
    install -Dm0644 "$u" "/usr/lib/systemd/system/$(basename "$u")"
    info "$(basename "$u")"
done

# User units run inside the graphical session. Post-login provisioning UI has to
# live here: the system services that do that work are triggered by an account
# being created, which is before that account has a session to draw in.
log "Installing systemd user units"
for u in "${CTX}"/systemd/user/*.service; do
    [[ -e "$u" ]] || continue
    name=$(basename "$u")
    install -Dm0644 "$u" "/usr/lib/systemd/user/${name}"
    # Enablement is a baked symlink rather than a user preset, because a preset
    # only takes effect if `systemctl --user preset-all` ever runs for that
    # account, and nothing guarantees it does. This is how pipewire enables
    # itself and it works from the first login.
    target=$(awk -F= '/^WantedBy=/{print $2; exit}' "$u")
    [[ -n "$target" ]] || die "${name} has no WantedBy=, so it would never start"
    install -d "/usr/lib/systemd/user/${target}.wants"
    ln -sf "../${name}" "/usr/lib/systemd/user/${target}.wants/${name}"
    info "${name} -> ${target}.wants"
done

install -Dm0644 "${CTX}/config/systemd/ik-os.preset" \
    /usr/lib/systemd/system-preset/50-ik-os.preset
systemctl preset-all 2>/dev/null || true

log "Applying the security baseline"
install -Dm0644 "${CTX}/config/security/ik-os-hardening.conf" \
    /usr/lib/sysctl.d/90-ik-os.conf
install -Dm0644 "${CTX}/config/security/firewalld-ik-os.xml" \
    /usr/lib/firewalld/zones/ik-os.xml

# SDD §50 — no unnecessary listening ports. Verified in tests/image/.
#
# openssh-server is installed now (ADR 0023) and this no longer masks it. A
# masked ssh.service is precisely why "Remote Login" in GNOME Settings could
# not be switched on: masking makes the unit unstartable, and the panel has no
# way to say so. Unmask explicitly rather than assume nothing did: an image
# built on top of an older layer would inherit the mask and the toggle would
# fail again, for a reason nobody would find twice.
systemctl unmask ssh.service 2>/dev/null || true

# What keeps a stock machine silent instead:
#
#   * these two disables. openssh-server's postinst runs in 20-packages.sh,
#     BEFORE 50-ik-os.preset exists, so it enables ssh.service with no preset
#     to stop it. `systemctl preset-all` above should undo that, but it runs in
#     a build container where systemd is not pid 1 and is allowed to fail, so
#     the outcome is not something to take on trust.
#   * the ik-os firewalld zone, which does not open 22.
#   * the drop-in below, which opens it only while sshd runs, and only at
#     runtime -- so "closed" is the state a reboot returns to.
systemctl disable ssh.service ssh.socket 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/ssh.service \
      /etc/systemd/system/sockets.target.wants/ssh.socket

# Whether this machine listens on 22 out of the box is not a question worth
# leaving to a best-effort systemctl in a container, so assert the answer.
for w in /etc/systemd/system/multi-user.target.wants/ssh.service \
         /etc/systemd/system/sockets.target.wants/ssh.socket; do
    [[ -e "$w" ]] && die "ssh is enabled by default (${w}).
       This image would listen on port 22 on every machine. See ADR 0023."
done

# Opens the firewall for as long as sshd runs, and no longer. Without it the
# GNOME toggle starts sshd behind a closed port and reports success.
install -Dm0644 "${CTX}/config/security/ssh-firewalld.conf" \
    /usr/lib/systemd/system/ssh.service.d/10-ik-os-firewall.conf
install -Dm0644 "${CTX}/config/security/ssh-socket-firewalld.conf" \
    /usr/lib/systemd/system/ssh.socket.d/10-ik-os-firewall.conf

# Host keys. openssh-server's postinst generates them at BUILD time, which
# would put the same four private keys on every machine this image ever
# installs -- the whole point of a host key being that it is not that. Delete
# them here; verify-image.sh fails the build if any survive.
rm -f /etc/ssh/ssh_host_*

# Something then has to create them per machine. Debian's sshd-keygen.service
# is meant to, and is already wanted by every path that starts sshd, but it is
# conditioned on ConditionFirstBoot -- which on an image that ships SSH
# disabled is never true at a moment when it matters. The drop-in clears that
# condition; enabling the unit is what creates the .wants symlinks its
# [Install] section describes.
install -Dm0644 "${CTX}/config/security/sshd-keygen-always.conf" \
    /usr/lib/systemd/system/sshd-keygen.service.d/10-ik-os-always.conf
systemctl enable sshd-keygen.service 2>/dev/null || true
