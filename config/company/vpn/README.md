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

## The exposure on the existing Bluefin image, and why it is accepted

`ik-office-key.pem` and `ik-office-tls-crypt.pem` are committed to the **public**
`ik-os` repository, and `build.sh` there copies all four files into
`/etc/openvpn/certs/` in the **public** `ghcr.io/.../ik-os` image. Anyone can
read both without authenticating.

That is not an open door, and an earlier version of this file was wrong to imply
it. The profile is `connection-type=password-tls`: the certificate is one of two
factors, and the other is a username and password that `password-flags=4` and
`username-flags=4` keep out of the connection file entirely. Neither is in the
repository or the image. Holding the key gets you as far as the login prompt.

What the exposure does cost:

- **`tls-crypt` stops doing its job.** Its purpose is to make the endpoint drop
  unauthenticated traffic before the TLS stack ever sees it — invisible to
  scanners, immune to handshake-level abuse. With the pre-shared key public,
  `80.147.28.39:11194` is a reachable login prompt: open to online password
  guessing against whatever directory backs `auth-user-pass`, and to account
  lockout used as a denial of service.
- **The certificate never identified anything.** It is `CN=client1` — one shared
  identity for the whole fleet, issued 2026-04-27 and valid until 2028-07-30.
  Revoking it could not isolate a device, because there has only ever been one.
  The issuing CA (`CN=cn_1na03EvSKMunS1sI`) is valid until 2034.
- **The reconnaissance is free.** The same files and profile disclose the VPN
  endpoint and port, the internal DNS server `192.168.77.10`, and four internal
  search domains.

**Decision (2026-08-31):** the material is not being reissued. Password
authentication is the control that actually gates access, and it is unaffected
by the exposure. If the endpoint's openness to guessing is later judged
unacceptable, rotating the `tls-crypt` key alone restores the
refuse-before-TLS property and needs no PKI work — but it has to change on the
server and on every client inside one maintenance window, and the new key must
not land in a public repository.

None of this changes what ik-os does. Shipping an identity inside an image is
wrong regardless of what that particular identity is worth, which is why the
per-device provisioning above exists.
