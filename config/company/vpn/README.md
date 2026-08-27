# ik-office VPN on ik-os

## Why the certificates are not in the image

The Bluefin-based `ik-os` image copied four files into every published layer:

    /etc/openvpn/certs/ik-office-ca.pem
    /etc/openvpn/certs/ik-office-cert.pem
    /etc/openvpn/certs/ik-office-key.pem      <-- private key
    /etc/openvpn/certs/ik-office-tls-crypt.pem <-- pre-shared key

SDD §27 and Rule 13 forbid this: anyone who can pull the image — which on a
public GHCR package is anyone at all — gets the company VPN identity. ik-os
therefore ships the *profile* but not the *identity*.

## How provisioning works instead

`ik-os-provision-vpn` (run by `ik-os-firstboot.service`, and re-runnable by
hand) fetches the per-device certificate bundle and installs it into
`/var/lib/ik-os/vpn/`, which is persistent machine state and never part of the
image. The source is configured in `/usr/lib/ik-os/policy.env`:

    VPN_PROVISION_MODE=enrollment   # fetch from the enrolment service
    VPN_PROVISION_MODE=manual       # an administrator drops the bundle in place
    VPN_PROVISION_MODE=disabled     # no company VPN on this machine

Until the bundle is present, the `ik-office` connection is created but flagged
as unprovisioned, and `ik-os diagnostics` reports it.

## Required action on the existing Bluefin image

`ik-office-key.pem` and `ik-office-tls-crypt.pem` are committed to the
`ik-os` repository and published inside `ghcr.io/.../ik-os-next`. Both must be
treated as compromised: reissue the client certificate, regenerate the
`tls-crypt` pre-shared key, and purge the old material from git history. Nothing
in this repository can undo that exposure.
