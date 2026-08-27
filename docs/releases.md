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
