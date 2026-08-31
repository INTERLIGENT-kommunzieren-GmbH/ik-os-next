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

`GITHUB_TOKEN` was denied `write_package` on the first push. Three observations
fit one rule:

| push                                          | result |
| --------------------------------------------- | ------ |
| original repo → its own `ik-os` package        | works  |
| this repo → `ik-os` (exists, linked elsewhere) | denied |
| this repo → `ik-os-next` (does not exist yet)  | denied |

**The cause is not established.** What is known: both repositories declare
`packages: write`, are public, authenticate as `github.actor` with
`GITHUB_TOKEN`, and report `default_workflow_permissions=write`; the original
repository's workflow uses different tooling (`docker/login-action`,
`redhat-actions/push-to-registry`) but the same credential, so tooling is not the
variable. Every organisation-level settings endpoint that would answer this
returns 403 without `admin:org`, and GHCR write access depends on package
settings and visibility that are equally unreadable at that scope.

Two explanations were proposed and neither is confirmed: that GHCR binds the
`ik-os` package to the repository that created it (disproved — a package name
that did not exist failed identically), and that the organisation forbids package
creation (disputed, since the organisation does publish packages today).

Settling it needs either `admin:org` read access or the empirical result below.

Meanwhile a **classic personal access token with `write:packages`** stored as
`GHCR_TOKEN` gets the first image published:

    gh secret set GHCR_TOKEN -R INTERLIGENT-kommunzieren-GmbH/ik-os-next

Classic, not fine-grained: fine-grained tokens have not historically carried a
Container-registry permission. If the token creation page offers one, prefer it —
it can be scoped to this organisation alone.

Whether it stays needed is an experiment, not a prediction. The first push
creates the package; the `org.opencontainers.image.source` label in the
`Containerfile` links it to this repository, and a linked package can inherit the
repository's access. Whether it does here is exactly the unknown above.

**The experiment needs no code change: delete the secret.** `build.yml` and
`promote.yml` prefer `GHCR_TOKEN` and fall back to `GITHUB_TOKEN`, logging which
one they used. If the fallback works, the PAT was scaffolding and should be
revoked. If it does not, the push fails at the next step and the log says which
credential was tried.

Treat the PAT as the worse credential while it exists: long-lived, tied to a
person rather than to the repository, and carrying the same rights across every
organisation that person can publish to. Give it an expiry. Both workflows
authenticate with `--password-stdin`, so it never appears in the process list of
a machine running other people's code.

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
