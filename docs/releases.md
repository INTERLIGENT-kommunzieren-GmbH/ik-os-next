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

`GITHUB_TOKEN` was denied `write_package` on the first pushes, to both `ik-os`
and `ik-os-next`. The cause is a per-package access list, and it is visible on
one screen — *Packages → the package → Package settings*:

| | `ik-os` | `ik-os-next`, before the fix |
| ----------------------- | ---------------------------- | ------- |
| Repository source       | `…/ik-os`, via the OCI label | none    |
| Manage Actions access   | `ik-os`, role Admin          | *empty* |
| Visibility              | public                       | public  |

A repository's `GITHUB_TOKEN` may write a container package in exactly three
cases: the push **creates** the package, the package names that repository as its
**source** (the `org.opencontainers.image.source` label), or the repository is
listed under **Manage Actions access**. `ik-os-next` matched none of them, so
`packages: write` in the workflow was necessary and not sufficient — the
repository had the permission, the package did not grant it.

The trap was that `ik-os-next` is **not a free name**. It already existed as an
orphaned package from the Fedora-44 daily lineage (`stable-daily-44.*`, last
published 2026-08-02, 209 downloads), created without the source label and so
linked to nothing. Renaming from `ik-os` therefore moved the push from one
package with no grant to another, which is why the rename looked like it
disproved the diagnosis. Check `/orgs/<org>/packages` before assuming a name is
new.

Two explanations were wrong and are recorded because both were stated with more
confidence than the evidence carried: that the *repository* owns the package name
(no — a package is a separate object with its own ACL), and that visibility
governs write (no — `ik-os-next` was already public and still refused).

**The fix, applied 2026-08-31:** on the `ik-os-next` package, *Manage Actions
access → Add Repository → `ik-os-next`*, then raise the role from the default
**Read** to **Admin**. Read is what the picker grants and it cannot push. Admin
rather than Write so the same credential can prune old versions; Write alone
covers upload and download. This mirrors `ik-os` exactly.

This was **confirmed** by run `33374113914` on 2026-08-31: `Log in to GHCR` and
`Push` both succeeded with `GITHUB_TOKEN` and no PAT, against the same package
that had refused three earlier attempts. The only change between them was the
ACL entry above.

No PAT is required. `build.yml` and `promote.yml` prefer a `GHCR_TOKEN` secret
and fall back to `GITHUB_TOKEN`, logging which one they used — so if the ACL is
ever lost the failure names the credential that was tried. Leave `GHCR_TOKEN`
unset: a classic PAT is long-lived, tied to a person rather than the repository,
and carries the same rights across every organisation that person can publish
to. The two-field ACL entry above does the same job with none of that.

Reusing the orphan is safe only because the tag namespaces do not overlap: the
Fedora lineage tagged `stable-daily`, `stable-daily-<date>` and `44.<date>`,
while this build pushes `<channel>` and `<channel>.<date>.<run>`. No push
overwrites a tag anything could still be following — the same property ADR 0015
protects for `ik-os`. The old versions can be pruned once nothing pulls them;
the Admin role granted above is what permits that.

Visibility needs no action either — the package is already public, which
`build-disk.yml`, `build-iso.yml` and every machine following a channel depend
on, none of them authenticating. Confirm it stays public after the first push;
a *newly created* GHCR package would default to private even from a public
repository.

## Image signing and key rotation (SDD §45)

Every image pushed from `main` is signed with the key in the `SIGNING_SECRET`
repository secret, and each image embeds the matching **public** key at
`/etc/pki/containers/ghcr.io-ik-os-next.pub` (from `config/company/cosign.pub`). A
machine verifies the image it is about to deploy against the public key its
*current* image carries.

The two halves must therefore be rotated together, and `build.yml` checks that
they match in the first seconds of the job rather than after the build:

    cosign public-key --key env://COSIGN_PRIVATE_KEY  ==  config/company/cosign.pub

### One credential file, two tools that disagree about where it is

`podman push` can succeed and `cosign sign` fail with `UNAUTHORIZED:
unauthenticated` in the same job, against the same registry, seconds apart. They
read different files:

| tool | credential file |
| ---------------- | ------------------------------------------ |
| podman / skopeo  | `$REGISTRY_AUTH_FILE`, default `$XDG_RUNTIME_DIR/containers/auth.json` |
| cosign           | `$DOCKER_CONFIG/config.json` (go-containerregistry) |

The original repository never hit this because `docker/login-action` writes
`~/.docker/config.json`, which is what cosign looks for. Moving to `podman
login` broke signing while leaving the push working — so the build pushed an
image and then failed to sign it, which is the right failure (Rule 18) reported
in a misleading place.

Both workflows now point `DOCKER_CONFIG` and `REGISTRY_AUTH_FILE` at one file in
`$RUNNER_TEMP` and log in with `--authfile`. The formats are compatible. The
login step then asserts that the file actually contains a `ghcr.io` entry, so
this fails in the first seconds rather than after a 24-minute build and a
completed push.

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
