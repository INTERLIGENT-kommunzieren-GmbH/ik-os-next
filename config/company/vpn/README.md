# ik-office VPN on ik-os

## Where the certificates live, and why

The identity is **committed to this repository**, at

    config/company/vpn/certs/ik-office-{ca,cert,key,tls-crypt}.pem

and `70-company.sh` installs it into the image at

    /usr/lib/ik-os/vpn/certs/

There is no build secret and no CI secret. `git clone && just build` produces an
image whose VPN works, and so does a fork's build.

**Why in the image.** The previous design deferred the identity to
"provisioning" and shipped machines without one. In practice that meant
`VPN_PROVISION_MODE=manual`, whose entire implementation was a log line, no
enrolment service behind the `enrollment` mode, and no procedure or tooling for
the manual route — so every installed workstation had an `ik-office` entry in
GNOME Settings that could never connect. What that bought in exchange was
nothing: the deferred identity is `CN=client1`, one shared certificate for the
whole fleet. Deferring a fleet-wide credential gives no per-device isolation and
makes no device individually revocable, because there is only one identity to
revoke. The cost was a broken VPN; the benefit was a property the design never
actually had.

**Why committed, in a public repository.** Because neither half of the objection
survives the facts. The material is already public: it is committed to the
predecessor `ik-os` repository and baked into its image, and
`ghcr.io/interligent-kommunzieren-gmbh/ik-os:stable` answers an anonymous
manifest pull with HTTP 200 today with `/etc/openvpn/certs/ik-office-key.pem`
inside. And the certificate does not authenticate anyone on its own — the
profile is `password-tls`, and `password-flags=4` / `username-flags=4` keep the
username and password out of the connection file, the repository and the image.
Committing it again discloses nothing new, and withholding it protects nothing
while costing a working VPN.

Neither does the image need to be private, and it is not. A scan of the built
image found the VPN key to be the only private key in it — everything else that
matches is a binary containing the literal string.

Routing the certificates through a build secret was tried and rejected. The
argument for it was rotation rather than secrecy — git history is permanent, an
image tag is not — but it bought that at the price of a CI secret, a bundle-
packing step and a build that fails without them, to withhold material that is
already published. If the `tls-crypt` key is ever rotated, the superseded one
stays in this history, as it already does in the predecessor's.

## Renewing the certificate

Replace the files in `config/company/vpn/certs/` and commit. That is the whole
procedure. `validate.yml` fails the build 30 days before expiry, `70-company.sh`
refuses to build with an expired certificate, and `verify-image.sh` checks the
copy that ends up in the image — including that the key still matches the
certificate. The current one expires **2028-07-30**.

## Overriding per machine

A bundle placed in `/var/lib/ik-os/vpn/` takes precedence over the image's, in
every mode, and `/var` survives image updates:

    sudo install -d -m0755 /var/lib/ik-os/vpn
    sudo cp ik-office-*.pem /var/lib/ik-os/vpn/
    sudo ik-os-provision-vpn

That is the path to use if per-device certificates are ever issued. Nothing in
the image has to change for it to work, and `ik-os diagnostics` reports which
identity is in use.

## What is still true about the credentials themselves

The certificate is one factor. `password-flags=4` and `username-flags=4` keep
the username and password out of the connection file entirely, so they are in
neither the repository nor the image; users supply them at connect time and may
save them to their own keyring afterwards. Holding the certificate gets an
attacker as far as the login prompt.

## What GNOME needs in order to show the profile

`network-manager-openvpn` is the daemon-side half: it lets NetworkManager speak
OpenVPN, and it is all `nmcli` needs. The GUI needs a second package,
`network-manager-openvpn-gnome`, which is *not* a dependency of the first:

    libnm-gtk4-vpn-plugin-openvpn-editor.so   GNOME Settings' editor panel
    libnm-vpn-plugin-openvpn-editor.so        nm-connection-editor's
    /usr/libexec/nm-openvpn-auth-dialog       the credential prompt

Both packages are in `packages/base/packages.list`, and
`build/validation/verify-image.sh` fails the build if any of the three files is
absent. When only the daemon half was installed, opening `ik-office` in
Settings showed `(Error: unable to load VPN connection editor)` and nothing
else — and because `password-flags=4` sends the credential request to the auth
dialog, the connection could not have been started from the shell menu either.

`nm-connection-editor` (packages/desktop, "Advanced Network Configuration" in
the app grid) is the third piece. Settings' VPN panel exposes little more than
the name and the IP tabs; the standalone editor is what reaches the OpenVPN
fields this profile actually depends on — remote, port, cipher, and the four
certificate paths. It is a *Recommends* of `gnome-control-center`, so
`--no-install-recommends` dropped it silently and it has to be named. Note that
Debian forky split the old `network-manager-gnome` in two: the editor is now
`nm-connection-editor` and the tray applet is `network-manager-applet`, which
GNOME Shell does not need. Asking for `network-manager-gnome` fails the build —
the package no longer exists.

## The exposure on the predecessor image, and what it does and does not cost

`ik-office-key.pem` and `ik-office-tls-crypt.pem` are committed to the **public**
`ik-os` repository, and its `build.sh` copies all four files into
`/etc/openvpn/certs/` in the **public** `ghcr.io/.../ik-os` image. Verified
still true: an anonymous manifest pull of `ik-os:stable` returns HTTP 200.

That is not an open door. The profile is `connection-type=password-tls`: the
certificate is one of two factors, and the other is a username and password that
are in neither the repository nor the image. Holding the key gets you as far as
the login prompt.

What the exposure does cost:

- **`tls-crypt` stops doing its job.** Its purpose is to make the endpoint drop
  unauthenticated traffic before the TLS stack ever sees it — invisible to
  scanners, immune to handshake-level abuse. With the pre-shared key public,
  the endpoint is a reachable login prompt: open to online password guessing
  against whatever directory backs `auth-user-pass`, and to account lockout used
  as a denial of service.
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
server and on every client inside one maintenance window.

Carrying the same identity in `ik-os-next` does not add to that exposure: the
material is already public in the predecessor's repository and image.

## Nothing to set up

There is no prerequisite to building or publishing this image — no CI secret, no
package-visibility change, no bundle to pack. `ik-os-next` is public like its
predecessor, and the certificates are in the tree. The reasoning is in ADR 0018.

What that ADR does **not** license is a second credential taking the same route.
`validate.yml` allows `BEGIN … PRIVATE KEY` under `config/company/vpn/certs/`
and nowhere else, requires that directory to hold exactly the four
`ik-office-*.pem` files, and `70-company.sh` enforces the same boundary at build
time. A cosign key, a MOK key or a Lansweeper token has none of the properties
that make this exception defensible, and each is still a hard build failure.
