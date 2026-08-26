#!/bin/bash
# Runs the in-image acceptance checks against a built image.
set -euo pipefail
IMAGE="${1:-ik-os:testing}"
exec podman run --rm -v "$(dirname "$0")/../../build/validation:/v:ro" \
    "$IMAGE" /v/verify-image.sh
