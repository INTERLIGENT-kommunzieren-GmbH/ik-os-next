#!/bin/bash
# The bootc install flags required by ADR 0005 — one definition, two callers.
#
# SDD §5 requires systemd-boot, and bootc only installs it on the composefs
# backend. On the default ostree backend it bails outright:
#
#     error: Installing to disk: bootupd is required for ostree-based installs
#
# The decision itself lives in config/image.env; this file turns it into an
# argument list so that no caller has to know which flags express it.
#
# SOURCE this file, do not execute it: it defines the INSTALL_FLAGS array, and an
# array cannot cross a process boundary.
#
# Callers:
#   - the _install-to-disk recipe in Justfile
#   - the "Install to disk" step in .github/workflows/build-disk.yml
#
# That second caller is why this file exists. It inlined its own copy of the
# logic, the copy omitted the backend flags, and because the workflow only runs
# after a successful "Build image" it had never once executed — so the drift from
# ADR 0005 stayed invisible until the first green build made the path reachable.

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if [[ ! -r "${REPO}/config/image.env" ]]; then
    echo "bootc-install-flags.sh: no config/image.env under ${REPO}" >&2
    return 1 2>/dev/null || exit 1
fi

set -a
# shellcheck source=config/image.env
. "${REPO}/config/image.env"
set +a

: "${BOOTC_BOOTLOADER:?not set in config/image.env}"
: "${BOOTC_BACKEND:?not set in config/image.env}"

INSTALL_FLAGS=(--bootloader "${BOOTC_BOOTLOADER}")

if [[ "${BOOTC_BACKEND}" == "composefs" ]]; then
    INSTALL_FLAGS+=(--composefs-backend)
fi

# ADR 0005: fs-verity is required by default, and a target that cannot provide it
# must fail the install rather than quietly drop the integrity guarantee. Setting
# this to true is a decision to be taken deliberately, not a way past an error.
if [[ "${BOOTC_ALLOW_MISSING_VERITY:-false}" == "true" ]]; then
    INSTALL_FLAGS+=(--allow-missing-verity)
fi

# The composefs backend only accepts OCI manifests. A docker v2 manifest reaches
# the install and fails there, which is a slow way to learn it.
#
# Usage: bootc_require_oci_manifest <image-ref>
#
# Set PODMAN to reach a different storage than the current user's — bootc install
# runs as root, so the image being checked usually lives in root's:
#
#     PODMAN="sudo podman" bootc_require_oci_manifest ik-os:testing
bootc_require_oci_manifest() {
    local ref="$1" mt
    local -a podman_cmd
    [[ "${BOOTC_BACKEND}" == "composefs" ]] || return 0
    read -r -a podman_cmd <<<"${PODMAN:-podman}"
    mt=$("${podman_cmd[@]}" image inspect --format '{{.ManifestType}}' "$ref" 2>/dev/null || true)
    [[ "$mt" == application/vnd.oci.image.manifest.v1+json ]] && return 0
    echo "error: ${ref} has manifest type '${mt:-unknown}'." >&2
    echo "       The composefs backend (ADR 0005) only supports OCI images." >&2
    return 1
}

# Explicit, so that sourcing this cannot hand a non-zero status to a caller
# running under `set -e`.
true
