#!/bin/bash
# Behavioural test of config/company/policy.json (SDD §45).
#
# Structural checks are not enough here. The policy has cost two failed
# installs already, each surfacing only part-way through `bootc install`:
#   * "default": reject      -> containers-storage refused, install dies
#   * a "_comment" key       -> whole policy refused as an unknown key
# Both are invisible to `jq`-style validation and to `skopeo inspect`, which
# does not evaluate the policy at all. Only a `skopeo copy` does.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
POLICY="${REPO}/config/company/policy.json"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; podman rmi -f "$TEST_IMG" >/dev/null 2>&1 || true' EXIT

TEST_IMG=ik-os-policy-probe:latest
PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "== container signature policy =="
[[ -r "$POLICY" ]] || { echo "policy not found: $POLICY"; exit 1; }

# A minimal image, so the probe copies bytes rather than gigabytes.
printf 'FROM scratch\nCOPY policy.json /policy.json\n' > "${WORK}/Containerfile"
cp "$POLICY" "${WORK}/policy.json"
podman build -q -t "$TEST_IMG" "$WORK" >/dev/null

policy_error() { grep -qE 'trust policy|rejected by policy|Unknown key' "$1"; }

# Distinguish "the policy refused this" from "this environment cannot run the
# probe at all". Both print a red cross otherwise, and only one of them is a
# policy bug — which cost a CI run to work out once already.
explain() {
    if grep -q 'unshare' "$1"; then
        printf '       not a policy failure: skopeo could not create a user namespace.\n'
        printf '       Ubuntu 24.04 blocks unprivileged userns via AppArmor. Run as root.\n'
    fi
}

# 1. containers-storage — what `bootc install to-disk` reads from.
if skopeo --policy "$POLICY" copy --quiet \
      "containers-storage:localhost/${TEST_IMG}" "oci-archive:${WORK}/probe.tar" \
      >"${WORK}/e1" 2>&1 && ! policy_error "${WORK}/e1"; then
    ok "containers-storage is readable (bootc install path)"
else
    no "containers-storage refused: $(tail -1 "${WORK}/e1")"
    explain "${WORK}/e1"
fi

# 2. oci-archive — what the installer ISO carries on the medium.
if [[ ! -f "${WORK}/probe.tar" ]]; then
    # Check 1 produces the archive check 2 reads. Saying so beats reporting
    # "oci-archive refused:" with nothing after the colon.
    no "oci-archive not tested: check 1 produced no archive to read"
elif skopeo --policy "$POLICY" copy --quiet \
      "oci-archive:${WORK}/probe.tar" "dir:${WORK}/probe-dir" \
      >"${WORK}/e2" 2>&1 && ! policy_error "${WORK}/e2"; then
    ok "oci-archive is readable (installer ISO path)"
else
    no "oci-archive refused: $(tail -1 "${WORK}/e2" 2>/dev/null)"
    explain "${WORK}/e2"
fi

# 3. The policy must still actually require a signature for the ik-os repo,
#    otherwise SDD §45 is not met and check 1 passes for the wrong reason.
if jq -e '.transports.docker
          | to_entries
          | map(select(.key | test("/ik-os-next$")))
          | all(.value[0].type == "sigstoreSigned")
          and length > 0' "$POLICY" >/dev/null; then
    ok "the ik-os repository still requires a sigstore signature"
else
    no "no sigstoreSigned requirement on the ik-os repository (SDD §45)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
