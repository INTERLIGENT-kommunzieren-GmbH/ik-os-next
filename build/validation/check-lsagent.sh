#!/bin/bash
# Validate the pinned LsAgent installer against the vendor (ADR 0017).
#
# LsAgent is downloaded at FIRST BOOT, not at build time, so a withdrawn or
# replaced vendor build cannot fail the image build — it fails on every laptop
# instead, silently, because the checksum guard refuses to install and the step
# just retries forever. This check moves that failure into CI.
#
# Deliberately does NOT download the 33 MB body: a HEAD is enough to prove the
# URL still resolves and the artefact is the same size. The sha256 is verified
# on the machine before the payload is executed.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck disable=SC1091
. "${REPO}/config/image.env"

PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "== LsAgent pin =="

if [[ "${LANSWEEPER_ENABLED_HINT:-}" == "false" ]]; then
    echo "  (informational only)"
fi

for v in LSAGENT_VERSION LSAGENT_URL LSAGENT_SHA256 LSAGENT_SIZE; do
    if [[ -n "${!v:-}" ]]; then ok "${v} is set"; else no "${v} is empty"; fi
done

# The checksum is what stands between the fleet and an arbitrary root-executed
# payload, so its shape is checked rather than assumed.
if [[ "${LSAGENT_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]; then
    ok "the checksum looks like a sha256"
else
    no "LSAGENT_SHA256 is not 64 hex characters"
fi

# The URL must be the public vendor one: first boot has internet but NOT the
# company VPN, so an internal mirror is the one source guaranteed to fail.
case "${LSAGENT_URL:-}" in
    https://cdn.lansweeper.com/*) ok "the URL is the public vendor CDN" ;;
    https://*.interligent.com/*)
        no "the URL points at internal infrastructure.
       First boot runs before any VPN exists and cannot reach it (ADR 0017)." ;;
    https://*) no "unexpected download host: ${LSAGENT_URL}" ;;
    *)         no "the URL is not https: ${LSAGENT_URL:-<empty>}" ;;
esac

# The version in the URL and the pinned version must agree, or a bump that edits
# one and not the other ships a different binary than the one it claims.
if [[ "${LSAGENT_URL:-}" == *"_${LSAGENT_VERSION}.run" ]]; then
    ok "the URL matches LSAGENT_VERSION"
else
    no "LSAGENT_URL does not end in _${LSAGENT_VERSION}.run"
fi

echo "-- vendor availability --"
HEAD=$(curl -sI -m 30 -L "$LSAGENT_URL" 2>/dev/null || true)
STATUS=$(awk 'tolower($1) ~ /^http/ {s=$2} END {print s}' <<<"$HEAD")
LENGTH=$(awk -F': ' 'tolower($1)=="content-length" {v=$2} END {print v}' <<<"$HEAD" | tr -d '\r')

if [[ "$STATUS" == 200 ]]; then
    ok "the pinned build is still published (HTTP 200)"
else
    no "the vendor returned HTTP ${STATUS:-no response} for the pinned build.
       Not every version stays on the CDN. Re-run
       scripts/maintenance/fetch-lsagent.sh and confirm with IT which build the
       scanning server accepts before changing the pin."
fi

if [[ -n "$LENGTH" && -n "${LSAGENT_SIZE:-}" ]]; then
    if [[ "$LENGTH" == "$LSAGENT_SIZE" ]]; then
        ok "the artefact is still ${LSAGENT_SIZE} bytes"
    else
        # Same version, different bytes: the vendor replaced a build in place.
        # First boot would refuse to install it and retry forever, so this is a
        # hard failure here rather than a surprise in the field.
        no "SIZE CHANGED: pinned ${LSAGENT_SIZE}, vendor now serves ${LENGTH}.
       The vendor replaced this build in place. Do not update the pin until that
       is explained — first boot executes this payload as root."
    fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || { echo "LsAgent pin validation FAILED"; exit 1; }
