#!/bin/bash
# SDD §39 — company configuration, kept separate from upstream Debian config.
# SDD §27 / Rule 13 — no secrets are embedded in the image.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Installing company configuration"

# --- CA trust (carried over from the Bluefin-based ik-os image) -------------
# Debian's trust store is /usr/local/share/ca-certificates + update-ca-certificates,
# but /usr/local is a symlink into /var here, so use the /usr-resident directory.
install -Dm0644 "${CTX}/config/company/CA-IK.crt" \
    /usr/share/ca-certificates/ik-os/CA-IK.crt
echo "ik-os/CA-IK.crt" >> /etc/ca-certificates.conf
update-ca-certificates
output_matches 'CN *= *CA-IK' \
    openssl x509 -in /usr/share/ca-certificates/ik-os/CA-IK.crt -noout -subject \
    || die "CA-IK certificate did not install correctly"
info "CA-IK installed into the system trust store"

# --- image signature verification (SDD §45) --------------------------------
install -Dm0644 "${CTX}/config/company/cosign.pub" \
    "/etc/pki/containers/${IK_OS_REGISTRY_HOST:-ghcr.io}-ik-os.pub"
install -Dm0644 "${CTX}/config/company/policy.json" /etc/containers/policy.json
install -Dm0644 "${CTX}/config/company/registries.d-ik-os.yaml" \
    /etc/containers/registries.d/ik-os.yaml

# --- VPN (SDD §27) ---------------------------------------------------------
# The client certificate and private key are per-device secrets and are NOT
# part of the image. Only the profile and the server CA ship here; the identity
# is provisioned at enrolment by ik-os-provision-vpn.
install -Dm0644 "${CTX}/config/company/vpn/ik-office.nmconnection.in" \
    /usr/lib/ik-os/vpn/ik-office.nmconnection.in
install -Dm0644 "${CTX}/config/company/vpn/README.md" \
    /usr/share/doc/ik-os/vpn.md

if [[ -n "$(find "${CTX}/config/company" \( -name '*key*.pem' -o -name '*.key' \) -print -quit)" ]]; then
    die "a private key is present in config/company/.
       Rule 13 forbids embedding secrets in the OCI image. Provision it at
       enrolment instead — see config/company/vpn/README.md."
fi

install -Dm0644 "${CTX}/config/company/policy.env" /usr/lib/ik-os/policy.env
