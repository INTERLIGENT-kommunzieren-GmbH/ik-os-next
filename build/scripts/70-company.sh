#!/bin/bash
# SDD §39 — company configuration, kept separate from upstream Debian config.
# SDD §27 / Rule 13 — no secrets come from the build context. The one credential
# the image does carry, the ik-office VPN identity, arrives as a build secret and
# is a documented exception (ADR 0018).
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
    "/etc/pki/containers/${IK_OS_REGISTRY_HOST:-ghcr.io}-ik-os-next.pub"
install -Dm0644 "${CTX}/config/company/policy.json" /etc/containers/policy.json
install -Dm0644 "${CTX}/config/company/registries.d-ik-os.yaml" \
    /etc/containers/registries.d/ik-os.yaml

# --- VPN (SDD §27) ---------------------------------------------------------
install -Dm0644 "${CTX}/config/company/vpn/ik-office.nmconnection.in" \
    /usr/lib/ik-os/vpn/ik-office.nmconnection.in
install -Dm0644 "${CTX}/config/company/vpn/README.md" \
    /usr/share/doc/ik-os/vpn.md

# The identity ships in the image. "Provision it later" produced machines with
# no VPN at all: the mode was `manual`, whose entire implementation was a log
# line, and the identity it deferred is CN=client1 -- one shared certificate for
# the whole fleet, so deferring it bought no per-device isolation.
#
# The certificates are committed to this repository, which is public, and that
# is deliberate rather than an oversight (ADR 0018). The same material is
# already public in the predecessor repo and image, and the profile is
# password-tls: the certificate is one factor of two, and the username and
# password are in neither the repository nor the image (password-flags=4).
#
# /usr, not /var: 95-finalize.sh empties /var, so anything installed there is
# gone from the image by the end of the build.
VPN_CERT_SRC="${CTX}/config/company/vpn/certs"
VPN_CERT_DIR=/usr/lib/ik-os/vpn/certs
# 0755, not 0700. GNOME Settings and nm-connection-editor run as the user, and
# their certificate pickers have to be able to list this directory -- a 0700
# directory makes the Identity tab fail with "Could not read the contents of
# certs / Permission denied" even though the connection itself would work,
# because NetworkManager reads the files as root. This is what the predecessor
# image did (a plain mkdir -p) and it is the combination known to work.
install -d -m0755 "$VPN_CERT_DIR"
for f in ca cert key tls-crypt; do
    [[ -r "${VPN_CERT_SRC}/ik-office-${f}.pem" ]] \
        || die "missing ${VPN_CERT_SRC}/ik-office-${f}.pem.
       The image ships the ik-office VPN identity; see
       config/company/vpn/README.md."
done
# All four are 0644, the key and tls-crypt included. The GUI editors run as the
# user and read these files, not just reference their paths -- libnma inspects a
# key to work out whether it is encrypted, which is what drives the "User key
# password" field -- so a 0600 key leaves the Identity tab unable to validate
# it. Restricting them would in any case protect nothing: this material is
# committed to a public repository and baked into a public image, so a local
# user who wanted the key could simply download it (ADR 0018).
install -m0644 "${VPN_CERT_SRC}/ik-office-key.pem"       "${VPN_CERT_DIR}/"
install -m0644 "${VPN_CERT_SRC}/ik-office-tls-crypt.pem" "${VPN_CERT_DIR}/"
install -m0644 "${VPN_CERT_SRC}/ik-office-ca.pem"        "${VPN_CERT_DIR}/"
install -m0644 "${VPN_CERT_SRC}/ik-office-cert.pem"      "${VPN_CERT_DIR}/"
openssl x509 -in "${VPN_CERT_DIR}/ik-office-cert.pem" -noout -checkend 0 \
    || die "config/company/vpn/certs/ik-office-cert.pem has expired.
       Replace it before building; the VPN cannot connect with it."
info "ik-office VPN identity installed ($(openssl x509 -in "${VPN_CERT_DIR}/ik-office-cert.pem" -noout -subject | sed 's/^subject=//'))"

# The ik-office bundle is the one credential this repository carries, and
# 0018 is explicit that the exception does not generalise. Anything else --
# a cosign key, a MOK key, a Lansweeper relay token -- is still forbidden.
while IFS= read -r k; do
    die "a private key is present at ${k}.
       Only config/company/vpn/certs/ may carry one (ADR 0018). Rule 13
       forbids embedding any other secret in the image."
done < <(command grep -rlE 'BEGIN [A-Z0-9 ]*PRIVATE KEY' "${CTX}/config" 2>/dev/null \
         | command grep -v '^'"${CTX}"'/config/company/vpn/certs/')

# --- asset inventory (SDD §38, ADR 0017) -----------------------------------
# LsAgent is NOT installed here: it writes AssetId/LastSent back into its own
# directory and self-updates, so its prefix must be writable -- it is installed
# into /var at first boot instead (contrast ADR 0008, where the Brother tree
# could live in /usr/lib/opt precisely because it is read-only).
#
# What the image carries is the pin, the reachability hook and the documentation.
install -Dm0644 /dev/stdin /usr/lib/ik-os/lansweeper.env <<EOF
# Generated by build/scripts/70-company.sh from config/image.env -- do not edit.
# Read by /usr/libexec/ik-os/ik-os-lansweeper alongside policy.env.
LSAGENT_VERSION="${LSAGENT_VERSION:-}"
LSAGENT_URL="${LSAGENT_URL:-}"
LSAGENT_SHA256="${LSAGENT_SHA256:-}"
LSAGENT_SIZE="${LSAGENT_SIZE:-}"
EOF

# The reachability trigger. NetworkManager reads /usr/lib as well as /etc, so
# this ships as image content; NM ignores scripts that are group- or
# world-writable, hence the explicit 0755 root:root.
install -Dm0755 "${CTX}/config/network/50-ik-os-lansweeper" \
    /usr/lib/NetworkManager/dispatcher.d/50-ik-os-lansweeper

install -Dm0644 /dev/stdin /usr/share/doc/ik-os/lansweeper.md <<'EOF'
# Asset inventory (LsAgent)

This machine reports itself to the company Lansweeper scanning server. See
docs/adr/0017-lansweeper-agent-in-var.md for why it is an agent and not
agentless scanning.

## Where things are

    /var/opt/LansweeperAgent          the agent (machine state, not image content)
    /var/opt/LansweeperAgent/LsAgent.ini   config + AssetId/LastScan/LastSent
    /var/lib/ik-os/lansweeper/        ik-os state: installed version, last-reachable
    /usr/lib/ik-os/lansweeper.env     the pinned installer version and checksum

## Nothing appears in Lansweeper — why?

The scanning server is reachable **only over a VPN** (ik-office, or a tunnel to
the datacenter). Without one, the agent is installed and idle by design. Bring a
tunnel up and NetworkManager triggers a reachability probe within seconds:

    journalctl -u ik-os-lansweeper-report -b
    ik-os diagnostics          # Asset inventory section

A device that never connects to a VPN never appears. There is deliberately no
cloud-relay fallback.

## Turning it off

Set LANSWEEPER_ENABLED="false" in config/company/policy.env and publish a new
image. That stops and disables the service but does not uninstall it -- removing
the directory would discard the AssetId, so re-enabling would register the
machine as a new asset. To remove it for real:

    sudo /var/opt/LansweeperAgent/uninstall

and retire the asset on the server side.
EOF

install -Dm0644 "${CTX}/config/company/policy.env" /usr/lib/ik-os/policy.env
