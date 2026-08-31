# Releases and channels

## Channels (SDD §8)

    ghcr.io/interligent-kommunzieren-gmbh/ik-os-next:testing
    ghcr.io/interligent-kommunzieren-gmbh/ik-os-next:stable
    ghcr.io/interligent-kommunzieren-gmbh/ik-os-next:stable-previous
    ghcr.io/interligent-kommunzieren-gmbh/ik-os-next:<version>

`testing` is built on every push to `main` and weekly. `stable` is only ever
written by the **Promote testing to stable** workflow, which requires a
reviewer approval and a hardware-validation ticket reference, and which copies
the outgoing stable image to `stable-previous` first so rollback stays possible
(SDD §8).

Versions look like `testing.20260823.42` — channel, build date, run number.
Deployments should pin by digest where possible (SDD §7).

## What every release records (SDD §41, §46)

`/usr/share/ik-os/release.env` in the image, and the workflow artefacts:

- OCI image digest
- source git commit
- resolved Debian codename and point release
- kernel package version and release
- bootc, composefs and ostree versions (ostree is a pinned upstream build, not
  the Debian package — see ADR 0001)
- Secure Boot signing state
- `packages.manifest` — every package and version
- `ik-os.spdx.json` — SBOM, attested to the image with cosign

## Publishing credentials

`GITHUB_TOKEN` cannot publish to this organisation's container registry. It is
denied `write_package` for **any** package name — the same error appears for a
package that does not exist yet — while both this repository and the original one
declare `packages: write`, are public, and report
`default_workflow_permissions=write`. The organisation-level policy behind it
needs `admin:org` to read.

So registry authentication uses a **classic personal access token with
`write:packages`**, stored as the repository secret `GHCR_TOKEN`:

    gh secret set GHCR_TOKEN -R INTERLIGENT-kommunzieren-GmbH/ik-os-next

Classic, not fine-grained: fine-grained tokens have not historically carried a
Container-registry permission. If the token creation page offers one, prefer it —
it can be scoped to this organisation alone.

Used by `build.yml` (push) and `promote.yml` (retagging). Both fail with an
explicit message when the secret is missing rather than attempting the push, and
both authenticate with `--password-stdin` so the credential never appears in the
process list of a machine running other people's code. Everything else still uses
`GITHUB_TOKEN`.

This is a worse credential than `GITHUB_TOKEN` and should be treated as one: it
is long-lived, tied to a person rather than to the repository, and carries the
same rights across every organisation that person can publish to. Give it an
expiry and diarise the rotation. Removing the org restriction and reverting to
`GITHUB_TOKEN` is the better end state.

**After the first successful push, set the package's visibility to public.** A
new GHCR package is private even when the repository is public, and a private
package cannot be pulled by `build-disk.yml`, by `build-iso.yml`, or by any
machine following a channel — none of which authenticate.

## Image signing and key rotation (SDD §45)

Every image pushed from `main` is signed with the key in the `SIGNING_SECRET`
repository secret, and each image embeds the matching **public** key at
`/etc/pki/containers/ghcr.io-ik-os-next.pub` (from `config/company/cosign.pub`). A
machine verifies the image it is about to deploy against the public key its
*current* image carries.

The two halves must therefore be rotated together, and `build.yml` checks that
they match in the first seconds of the job rather than after the build:

    cosign public-key --key env://COSIGN_PRIVATE_KEY  ==  config/company/cosign.pub

**The private key cannot be read back out of GitHub.** Repository secrets are
write-only: not by the API, not by a workflow log, not by the owner. If the only
copy was the one uploaded at `gh secret set` time, it is gone, and the only
remedy is rotation. This has already happened once — the key the original ik-os
repository signs with exists nowhere outside its own secret store.

To rotate:

    COSIGN_PASSWORD="" cosign generate-key-pair          # empty password: CI cannot type one
    cosign public-key --key cosign.key                   # sanity-check the pair
    gh secret set SIGNING_SECRET < cosign.key
    cp cosign.pub config/company/cosign.pub              # commit this
    # then store cosign.key somewhere durable, NOT only in the secret

Generate it outside the repository. `cosign.key` is in `.gitignore`, but the
Rule 13 check in `validate.yml` greps the whole tree for `BEGIN … PRIVATE KEY`
and will flag it locally.

Rotation is safe here because migration is a reinstall rather than a
`bootc switch` (`docs/migration.md`): the installer carries both the new image
and the new public key, so a new key never has to be verified by an old one.
An in-place switch across a key change would be refused.

## Debian release transitions (SDD §47)

The image tracks the floating `stable` suite. `build/scripts/00-preflight.sh`
compares what `stable` resolved to against `EXPECTED_DEBIAN_CODENAME` in
`config/image.env` and **fails the build** when they differ.

That failure is the point: it turns a silent major-release transition into a
red build. Bump `EXPECTED_DEBIAN_CODENAME` only alongside an approved
release-transition ticket and a full hardware validation pass.

## Kernel promotion (SDD §9)

Kernel updates enter `testing` first. A kernel reaches `stable` only after
`tests/hardware/test-hardware.sh` has been run and signed off on every hardware
class in `docs/hardware.md`.
