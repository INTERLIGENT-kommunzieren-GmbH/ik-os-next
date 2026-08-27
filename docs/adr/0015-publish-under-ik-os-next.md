# ADR 0015 — The image publishes as `ik-os-next`, not `ik-os`

**Status:** accepted
**SDD:** §40, §45; Rules 15, 18

## Context

The first push to `main` failed at the registry:

    denied: permission_denied: write_package

`ghcr.io/interligent-kommunzieren-gmbh/ik-os` already exists. It is public, and
it was published by the **original** repository — whose `IMAGE_NAME` is
`${{ github.event.repository.name }}`, i.e. `ik-os`. It carries `latest`,
`stable`, dated variants of both, and cosign `.sig` attachments, last built
2025-09-26. GHCR binds a package to the repository that created it, so
`ik-os-next`'s `GITHUB_TOKEN` has no write access to it however many
`packages: write` permissions the workflow requests.

Granting the new repository write access to that package is a two-click change
in the organisation's package settings, and it was the obvious fix. It is the
wrong one, for a reason that has nothing to do with permissions.

One package name is one tag namespace. The moment this project published
`stable`, it would replace the tag that every deployed machine follows for
updates — and hand a Debian image, signed with a different key (ADR 0014's
rotation), to machines whose embedded public key is the original one. They would
refuse it, which is the correct behaviour and the worst possible presentation of
it: an update path that stops with a signature error pointing at the signature
rather than at the tag it should never have been given.

`testing` does not collide today. That is not a safeguard, it is a coincidence
of which channel is being built first.

## Decision

Publish as `ghcr.io/interligent-kommunzieren-gmbh/ik-os-next`. The **container
image** is renamed; the operating system is not. `os-release` still says ik-os,
the CLI is still `ik-os`, the artefacts are still `ik-os.raw` and `ik-os.iso`,
and `/etc/pki/containers` now holds `ghcr.io-ik-os-next.pub` only because that
file is named after the image it verifies.

Renamed together, since a signature policy that names the wrong repository
silently verifies nothing:

    .github/workflows/{build,build-disk,build-iso,promote}.yml   IMAGE_NAME
    config/company/policy.json                                   transport key + keyPath
    config/company/registries.d-ik-os.yaml                       sigstore attachments
    config/company/policy.env                                    IK_OS_REGISTRY
    build/scripts/70-company.sh                                  the installed key filename
    build/validation/verify-image.sh                             three policy lookups
    build/validation/check-policy.sh                             the `/ik-os$` match
    migration/bluefin/ik-os-migrate                              the target image
    Justfile                                                     the local build tag

`check-policy.sh` asserts `length > 0` on that match, so a rename that missed
the check itself would fail rather than pass vacuously.

## Consequences

The deployed fleet is untouched. Nothing this repository builds can overwrite a
tag the running image follows, whichever channel is published, and that property
holds by construction rather than by remembering.

The two images can therefore coexist for as long as the migration takes — which
matters, because migration is a reinstall rather than a `bootc switch`
(`docs/migration.md`) and will not be simultaneous across the company.

The name is not temporary-sounding by accident, and it is worth deciding
deliberately later whether the eventual production image reclaims `ik-os`. If it
does, that is a fleet-wide cutover: the old repository's workflows must be
disabled first, or a Fedora-based build can publish to that name again long after
anyone expects it to.

The original `ik-os` package keeps its own signing key, which no longer exists
outside its repository secret (ADR 0014). Publishing a fix for machines still on
that image is therefore not possible without rotating a key those machines
cannot be told about — an argument for completing the migration rather than
maintaining both.
