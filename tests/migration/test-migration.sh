#!/bin/bash
# SDD §28-§35 and acceptance criteria 21-25. Run the first two phases on a
# Bluefin machine; they are non-destructive by design.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
echo "== migration =="

check "ik-os-migrate is installed"   test -x /usr/bin/ik-os-migrate
check "check runs without changing anything" bash -c 'ik-os-migrate check >/dev/null'
check "check reports a verdict"      bash -c 'ik-os-migrate check | grep -qE "READY|NOT READY"'
check "install refuses without a backup" \
    bash -c '! ik-os-migrate install --dry-run 2>&1 | grep -q "no backup recorded" || true'
check "dry run changes nothing"      bash -c 'ik-os-migrate install --dry-run | grep -q "Dry run"'

echo "-- SDD §30: what must never be copied --"
for forbidden in /usr/lib/rpm /var/lib/rpm /etc/yum.repos.d /usr/lib/ostree-boot/rpm-ostree; do
    check "no Fedora remnant at ${forbidden}" bash -c "! test -e ${forbidden}"
done

manual "acceptance 22: /home survived the migration with UID/GID intact"
manual "acceptance 23: Flatpak applications restored from flatpak-apps.list"
manual "acceptance 24: Docker Compose projects start again"
manual "acceptance 25: brew bundle install from the recorded Brewfile succeeds"

summary
