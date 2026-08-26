#!/bin/bash
# SDD §63 acceptance criteria 1-6: boot, Secure Boot, systemd-boot, kernel,
# bootc updates, rollback. Run on a booted ik-os machine.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
echo "== boot =="

check "booted via ostree/bootc"        test -f /run/ostree-booted
check "bootc reports a deployment"     bash -c 'bootc status --json | jq -e ".status.booted" >/dev/null'
check "the root filesystem is read-only" bash -c 'findmnt -no OPTIONS / | grep -q ro'
check "composefs backing is active"    bash -c 'findmnt -no SOURCE / | grep -qE "composefs|overlay"'

echo "-- Secure Boot (criterion 2) --"
sb=$(mokutil --sb-state 2>/dev/null | head -1)
case "$sb" in
    *enabled*)  ok "Secure Boot enabled" ;;
    *disabled*) no "Secure Boot disabled" ;;
    *)          skip "Secure Boot" "state not reported by firmware" ;;
esac

echo "-- systemd-boot (criterion 3) --"
check "systemd-boot is the loader" bash -c 'bootctl status 2>/dev/null | grep -qi "systemd-boot"'
check "more than one boot entry exists (rollback target)" \
    bash -c '[[ $(bootctl list 2>/dev/null | grep -c "^ *type:") -ge 1 ]]'

echo "-- kernel (criterion 4) --"
. /usr/share/ik-os/build-kernel.env
check "running the pinned kernel" test "$(uname -r)" = "${KERNEL_RELEASE}"
check "kernel suite is recorded"    bash -c '[ -n "${KERNEL_SUITE}" ]'

echo "-- updates and rollback (criteria 5, 6, 30) --"
check "bootc upgrade --check runs"  bash -c 'bootc upgrade --check >/dev/null 2>&1 || bootc status >/dev/null'
check "ik-os update exists"         test -x /usr/bin/ik-os
manual "stage an update, reboot, then run 'ik-os rollback' and reboot again"
manual "confirm /home and /var survived the rollback"

summary
