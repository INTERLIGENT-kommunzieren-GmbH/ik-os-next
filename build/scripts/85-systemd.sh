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
# Note this masks a unit that is NOT installed: the image ships openssh-client
# only, never openssh-server. That is deliberate defence-in-depth, not an
# oversight — if openssh-server is ever pulled in as somebody's dependency, it
# arrives already masked rather than quietly listening. The mask is what makes
# `systemctl unmask ssh` report "Unit ssh.service does not exist", which is the
# correct answer.
systemctl mask ssh.service 2>/dev/null || true
