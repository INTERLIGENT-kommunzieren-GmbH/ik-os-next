#!/bin/bash
# bootc comes from the builder stage; ostree and composefs come from Debian.
#
# On Debian 14 the archive provides ostree 2026.2 and composefs 1.0.8, both new
# enough for bootc (which needs the ostree crate's v2025_3 feature). Only bootc
# itself is unpackaged. See docs/adr/0001-bootc-from-source.md.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Installing bootc ${BOOTC_VERSION}"

PREBUILT="${PREBUILT:-/prebuilt}"
[[ -d "$PREBUILT" ]] || die "builder stage output missing at ${PREBUILT}"

cp -a "${PREBUILT}/." /
ldconfig

command -v bootc       >/dev/null || die "bootc not on PATH after install"
command -v ostree      >/dev/null || die "ostree not installed (packages/base)"
command -v mkcomposefs >/dev/null || die "composefs tools not installed (packages/base)"

# bootc requires ostree >= 2025.3. Debian 14 satisfies this, but assert it: a
# base that silently regressed would fail much later, during `bootc install`.
OSTREE_VERSION=$(ostree --version | awk -F"'" '/Version/{print $2}')
info "ostree: ${OSTREE_VERSION} (Debian package)"
[[ -n "$OSTREE_VERSION" ]] || die "could not determine the ostree version"
awk -v v="$OSTREE_VERSION" 'BEGIN{split(v,a,".");exit !(a[1]>2025 || (a[1]==2025 && a[2]>=3))}' \
    || die "ostree ${OSTREE_VERSION} is older than the 2025.3 bootc requires."

# ostree must be built with libarchive or bootc cannot import container layers;
# it fails part-way through `bootc install`, not at build time.
for feat in libarchive composefs selinux systemd; do
    output_matches_fixed "$feat" ostree --version \
        || die "Debian's ostree lacks '${feat}'.
       Features present: $(ostree --version | tr -d '\n')"
done
info "ostree features verified: libarchive composefs selinux systemd"

info "bootc: $(bootc --version)"

# Update policy is owned by systemd/timers/ik-os-update.timer (SDD §40), not by
# bootc's own timer.
systemctl disable bootc-fetch-apply-updates.timer 2>/dev/null || true

mkdir -p /usr/share/ik-os
cat > /usr/share/ik-os/build-bootc.env <<EOF
BOOTC_VERSION="${BOOTC_VERSION}"
OSTREE_VERSION="${OSTREE_VERSION}"
OSTREE_SOURCE="debian"
COMPOSEFS_SOURCE="debian"
EOF
