#!/bin/bash
# ADR 0024 — the persistent package overlay on /usr. Run as root on a booted
# ik-os machine. Installs and removes a small package (sl), so it is not part of
# the default `ik-os selftest` set; run it with `ik-os selftest overlay`.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
echo "== package overlay =="

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 2; }
PROBE=sl

check "/ is still read-only"               bash -c 'findmnt -no OPTIONS / | grep -q "^ro"'
check "the sysroot is still read-only"     grep -q 'readonly = true' /usr/lib/ostree/prepare-root.conf
check "booted with a composefs digest"     grep -q 'composefs=' /proc/cmdline

echo "-- guards --"
check "a base package is refused"          bash -c '! ik-os pkg install bash'
check "a denylisted package is refused"    bash -c '! ik-os pkg install dkms'
check "a local .deb is refused"            bash -c '! ik-os pkg install ./x.deb'

echo "-- install --"
if grep -qxF "$PROBE" <<<"$(ik-os pkg list)"; then
    skip "install ${PROBE}" "already in the overlay; remove it first"
else
    check "ik-os pkg install ${PROBE}"     ik-os pkg install "$PROBE"
fi
check "${PROBE} runs"                      test -x "/usr/games/${PROBE}"
check "${PROBE} is in packages.list"       grep -qxF "$PROBE" /var/lib/ik-os/usr-overlay/packages.list
check "/usr is the ik-os overlay"          bash -c '[[ "$(findmnt -no SOURCE /usr)" == ik-os-usr-overlay ]]'
check "the overlay is ready for this image" \
    bash -c 'd=$(tr " " "\n" </proc/cmdline | sed -n "s/^composefs=?\{0,1\}//p"); test -e "/var/lib/ik-os/usr-overlay/$d/ready"'
# Match the guard's own message, not the exit status: apt and dpkg fail for
# other reasons too (a read-only /usr, no package lists), and the check would
# pass for the wrong one.
check "plain apt install points at ik-os pkg" \
    bash -c 'o=$(apt-get install -y sl 2>&1); grep -q "ik-os pkg install" <<<"$o"'
check "plain apt upgrade points at ik-os update" \
    bash -c 'o=$(apt-get upgrade -y 2>&1); grep -q "ik-os update" <<<"$o"'
check "ik-os pkg search finds packages"    bash -c 'o=$(ik-os pkg search "^${PROBE}\$"); grep -q "^${PROBE} " <<<"$o"'
check "plain apt update is refused by the guard" \
    bash -c 'o=$(apt-get update 2>&1); grep -q "not used directly" <<<"$o"'
# Harmless if the guard were missing: there is nothing left to configure.
check "plain dpkg is refused by the guard" \
    bash -c 'o=$(dpkg --configure -a 2>&1); grep -q "not used directly" <<<"$o"'

echo "-- remove --"
check "ik-os pkg remove ${PROBE}"          ik-os pkg remove "$PROBE"
check "${PROBE} is gone"                   bash -c "! test -e /usr/games/${PROBE}"
check "${PROBE} left packages.list"        bash -c "! grep -qxF ${PROBE} /var/lib/ik-os/usr-overlay/packages.list"

manual "install a package, reboot: it is still there, with no replay in the journal"
manual "install a package, update to a new image, reboot: the desktop comes up without it, then 'Your extra packages are back'"
manual "then bootc rollback and reboot: the old image's overlay mounts, with no replay"
manual "ik-os pkg reset, reboot: /usr is not an overlay and ik-os pkg list is empty"

summary
