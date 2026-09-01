#!/bin/bash
# SDD §43, §57, §58 — ik-os CLI, first-boot helpers and the migration tool.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Installing ik-os tooling"

install -Dm0755 "${CTX}/scripts/diagnostics/ik-os"          /usr/bin/ik-os
install -Dm0755 "${CTX}/migration/bluefin/ik-os-migrate"    /usr/bin/ik-os-migrate
install -Dm0755 "${CTX}/scripts/firstboot/ik-os-firstboot"  /usr/libexec/ik-os/ik-os-firstboot
install -Dm0755 "${CTX}/scripts/firstboot/ik-os-provision-vpn" /usr/libexec/ik-os/ik-os-provision-vpn
install -Dm0755 "${CTX}/scripts/firstboot/ik-os-enroll"     /usr/libexec/ik-os/ik-os-enroll
install -Dm0755 "${CTX}/scripts/firstboot/ik-os-user-groups" /usr/libexec/ik-os/ik-os-user-groups
install -Dm0755 "${CTX}/scripts/firstboot/ik-os-lansweeper"  /usr/libexec/ik-os/ik-os-lansweeper
install -Dm0755 "${CTX}/scripts/firstboot/ik-os-lansweeper-report" /usr/libexec/ik-os/ik-os-lansweeper-report
install -Dm0755 "${CTX}/scripts/firstboot/ik-os-homebrew"    /usr/libexec/ik-os/ik-os-homebrew
install -Dm0755 "${CTX}/scripts/firstboot/ik-os-hostname"    /usr/libexec/ik-os/ik-os-hostname
install -Dm0755 "${CTX}/scripts/firstboot/ik-os-notify"      /usr/libexec/ik-os/ik-os-notify
# Runs in the user's graphical session, not at boot -- see systemd/user/.
install -Dm0755 "${CTX}/scripts/desktop/ik-os-provisioning-monitor" \
    /usr/libexec/ik-os/ik-os-provisioning-monitor

# /etc/hostname is bind-mounted by the container runtime, so it cannot be read
# back during verification. Keep a copy of what the image actually ships.
install -Dm0644 "${CTX}/config/hostname" /usr/share/ik-os/hostname

# SDD §63 — ship the booted-system suites so any deployed machine can be
# validated without a checkout. `ik-os selftest` runs them.
install -d /usr/share/ik-os/tests
install -Dm0644 "${CTX}/tests/lib.sh" /usr/share/ik-os/tests/lib.sh
for suite in boot docker printing provisioning hardware; do
    src="${CTX}/tests/${suite}/test-${suite}.sh"
    [[ -f "$src" ]] || die "tests/${suite}/test-${suite}.sh is missing; ik-os
       selftest would silently skip it."
    install -Dm0755 "$src" "/usr/share/ik-os/tests/${suite}/test-${suite}.sh"
done
# image/ runs on the build host and migration/ on a Bluefin machine, so neither
# belongs on a deployed system.
ln -sf /usr/libexec/ik-os/ik-os-provision-vpn /usr/bin/ik-os-provision-vpn

for t in "${CTX}"/scripts/maintenance/*; do
    [[ -f "$t" ]] || continue
    install -Dm0755 "$t" "/usr/libexec/ik-os/$(basename "$t")"
done

# SDD §40 — make the unsupported path explain itself instead of half-working.
mkdir -p /usr/lib/ik-os
cat > /usr/lib/ik-os/apt-immutable-notice <<'EOF'
ik-os is an immutable, image-based operating system (SDD §40).

Changes to the host are made by publishing a new OS image, not by installing
packages into the running system. `apt upgrade` and `apt dist-upgrade` are not
supported here and their effects are discarded on the next update.

  Update the OS ............ ik-os update
  Roll back ................ ik-os rollback
  GUI application .......... flatpak install <app>
  CLI developer tool ....... brew install <tool>
  Project dependency ....... a container (Containerfile / compose.yaml)
  Something the OS needs ... change the image, open a PR

See /usr/share/doc/ik-os/ and SDD §54.
EOF

/usr/bin/ik-os --help >/dev/null || die "the ik-os CLI does not run"
info "ik-os CLI installed"
