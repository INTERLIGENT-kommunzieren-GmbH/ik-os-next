# ADR 0018 — the ik-office VPN identity ships in the image

**Status:** accepted
**SDD:** §27 (secrets), §37 (first boot), §38 (enrolment), §39 (company
configuration); Rules 12, 13, 15
**Supersedes:** the provisioning design described in `config/company/vpn/README.md`
before 2026-09-02

## Context

This is a deliberate, documented exception to **Rule 13** ("Never embed secrets
in the OCI image"), recorded under Rule 15.

ik-os-next shipped the `ik-office` NetworkManager profile but not the identity it
references. `ik-os-provision-vpn` was to install the certificate bundle into
`/var/lib/ik-os/vpn/` at enrolment, keeping the key out of every published layer.
The predecessor Bluefin image had copied all four files into
`/etc/openvpn/certs/` in a public GHCR package, and this was the correction.

Held up against what was actually built, the correction does not survive contact
with three facts.

**1. No mode of it delivers a VPN.** `VPN_PROVISION_MODE` defaulted to `manual`,
and the whole of that branch was:

```bash
manual)
    log "manual mode: expecting an administrator to place the bundle in ${DEST}" ;;
```

It logs and returns. There is no procedure behind it, no tooling, and no
documented copy step. The `enrollment` alternative needs `ENROLLMENT_URL`, which
is `""` with `ENROLLMENT_ENABLED="false"`, and no enrolment service exists. So
every installed workstation got an `ik-office` entry in GNOME Settings that could
never connect, and the failure was invisible until a user tried it.

**2. What was being deferred is not a per-device secret.** The bundle is
`CN=client1` — one shared certificate for the entire fleet, issued 2026-04-27,
valid to 2028-07-30, under a CA valid to 2034. Deferring a fleet-wide credential
to enrolment yields no per-device isolation and makes no individual machine
revocable, because there is only one identity to revoke. The design paid for a
security property it never had.

**3. The exposure it was avoiding has already happened and is not being undone.**
`ik-office-key.pem` and `ik-office-tls-crypt.pem` are committed to the public
`ik-os` repository and baked into the public `ghcr.io/.../ik-os` image; an
anonymous manifest pull of `ik-os:stable` returns HTTP 200 as of 2026-09-02. The
decision of 2026-08-31 was not to reissue the material, on the grounds that
password authentication is the control that actually gates access. Withholding
the same certificate from ik-os-next's image therefore protects nothing that is
not already public.

A workstation that cannot reach the company network is not a finished
workstation, and the asset-inventory step (ADR 0017) needs the tunnel too.

## Decision

The identity ships in the image, at `/usr/lib/ik-os/vpn/certs/`, and
`VPN_PROVISION_MODE` defaults to `image`.

The four certificates are **committed to this repository** at
`config/company/vpn/certs/`, and `70-company.sh` installs them from the build
context. There is no build secret, no CI secret and no bundle-packing step: the
VPN works from a plain `git clone && just build`.

That the repository is public does not change the analysis, for the same reasons
the identity ships at all. The material is already public — committed to the
predecessor `ik-os` repository and baked into its image, which answers an
anonymous manifest pull with HTTP 200. And the certificate is one factor of two:
the profile is `connection-type=password-tls`, and `password-flags=4` /
`username-flags=4` keep the username and password out of the connection file,
the repository and the image. Publishing the material again in a second public
repository discloses nothing that is not already disclosed, and withholding it
protects nothing.

An earlier revision of this ADR routed the certificates through a podman build
secret to keep them out of git, arguing that git history is permanent while an
image tag is not, so a future `tls-crypt` rotation would stay cheap. That was
rejected: it added a CI secret, a `just vpn-bundle` step and a build that fails
without them, all to withhold material that is already published and that cannot
authenticate anyone on its own. The rotation point survives only as a note — if
the key is ever rotated, the superseded one stays in this history, as it already
does in the predecessor's.

A bundle in `/var/lib/ik-os/vpn/` overrides the image's, in every mode. If
per-device certificates are ever issued, that is the path, and no image change is
needed to use it.

`/usr` and not `/var` because `95-finalize.sh` empties `/var`: anything installed
there is gone from the image by the end of the build.

## Consequences

**The image does not have to be private, and is not.** An earlier draft of this
ADR made private visibility a prerequisite. That was wrong, and the reasoning
was circular: it treated the certificate as a secret whose disclosure had to be
contained, when the premise of this whole decision is that it is not one. Three
things follow, and each is independently sufficient:

- The material is already public. `ik-office-key.pem` and
  `ik-office-tls-crypt.pem` are committed to the public `ik-os` repository and
  baked into the public `ik-os` image, which answers an anonymous manifest pull
  with HTTP 200. A private ik-os-next would withhold nothing.
- The certificate is not an authenticator on its own. The profile is
  `connection-type=password-tls`; `password-flags=4` and `username-flags=4` keep
  the username and password out of the connection file, the repository, and the
  image. Possession of the bundle gets an attacker to a login prompt.
- Nothing else in the image is sensitive. A scan of the built image found the
  VPN key as the only private key present — every other match is a binary
  containing the literal string (`ssh`, `gpg`, `libgnutls`, mime magic files).
  No SSH host keys are baked in, no tokens, and the only signing material is the
  cosign **public** key at `/etc/pki/containers/`.

So publishing ik-os-next discloses nothing that is not already disclosed, and
ik-os-next stays public like its predecessor.

**Every build produces a working VPN.** There is no configuration a build can be
missing, no secret CI can lose, and no difference between a maintainer's build
and a fork's. The failure this ADR exists to fix — publishing an image whose VPN
silently cannot work — is now unreachable rather than guarded against.

**The Rule 13 gate is narrowed by path, not disabled.** `validate.yml` still
greps the whole tree for `BEGIN … PRIVATE KEY` and still fails; it now excludes
exactly `config/company/vpn/certs/`. Two further gates stop that exclusion
widening on its own: the directory must hold exactly the four `ik-office-*.pem`
files and nothing else, so a second credential cannot inherit the allowance
without review; and the certificate must have more than 30 days left.
`70-company.sh` enforces the same boundary at build time, refusing to build if a
private key appears anywhere else under `config/`.

**The modes are 0755 on the directory and 0644 on all four files, private key
included, and that is not an oversight.** It looks like the wrong permission set
for a directory holding a private key, and two earlier attempts tightened it —
first 0700 on the directory, then 0600 on the key and `tls-crypt`. Both broke
the GUI, and both broke it in a way that a connection test does not catch.

The reason is that GNOME's editors are not merely storing a path. gnome-control-
center and nm-connection-editor run as the *user*, and libnma's certificate
chooser opens the files: it lists the directory to populate the picker, and it
inspects the private key to determine whether it is encrypted, which is what
drives the *"User key password"* field. With the directory at 0700 the Identity
tab failed outright with *"Could not read the contents of certs — Permission
denied"*. With the key at 0600 the directory lists but the key cannot be
validated. In both cases NetworkManager, which is root, would still have brought
the tunnel up — so the VPN "works" while its configuration UI does not, which is
exactly what makes this class of failure easy to miss in testing and baffling in
the field.

Nothing is given away by the looser modes. The identity is committed to a public
repository and baked into a public image; a local user who wanted the key could
download it from GitHub without touching the filesystem. A 0600 key here would
not have been a control, only an inconvenience with the appearance of one.

`verify-image.sh` asserts the directory is 0755 and all four files are 0644,
along with the bundle being complete, the certificate unexpired, and the key
still matching the certificate. The assertions exist so that a future attempt to
"harden" these modes surfaces as a failing check sitting next to this reasoning,
rather than as a bug report about the VPN dialog. The same modes apply to
`/var/lib/ik-os/vpn` on the manual-override path.

**Certificate expiry becomes a release concern.** `validate.yml` fails 30 days
out, `70-company.sh` refuses to build with an expired certificate,
`verify-image.sh` checks the copy in the image, and `ik-os diagnostics` reports
the date. The current certificate expires 2028-07-30. Renewing it is a commit.

**Rule 13 is narrowed, not abandoned.** The exception is one credential, already
public, that is one of two authentication factors — the username and password
remain out of both the repository and the image (`password-flags=4`,
`username-flags=4`). It is not a licence to ship the Lansweeper relay key
(ADR 0017), the cosign private key, or MOK keys, none of which have any of those
properties.
