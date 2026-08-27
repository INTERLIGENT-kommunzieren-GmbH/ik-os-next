# ADR 0015 — The image publishes as `ik-os-next`, not `ik-os`

**Status:** accepted
**SDD:** §40, §45; Rules 15, 18

## Context

The first push to `main` failed at the registry:

    denied: permission_denied: write_package

The initial reading of that error was that
`ghcr.io/interligent-kommunzieren-gmbh/ik-os` already exists — published by the
**original** repository, whose `IMAGE_NAME` is
`${{ github.event.repository.name }}` — and that GHCR binds a package to the
repository that created it, so this repository could not write to it.

**That reading was wrong**, and it is recorded here because the conclusion
survives it and the reasoning must not be mistaken for the diagnosis. Renaming
the image produced exactly the same error on `ik-os-next`, a package that did
not yet exist:

    /v2/interligent-kommunzieren-gmbh/ik-os-next/blobs/uploads/ … denied: permission_denied: write_package

So the denial is not about the old package. It is an organisation-level
restriction on publishing packages, and it applies to every name. That is
tracked separately; it is not what this ADR decides.

What this ADR decides is the name, and the reason for it has nothing to do with
permissions. Sharing a name with the deployed image would have been wrong even
if the push had succeeded on the first attempt.

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

Publishing is still blocked, by the organisation policy above. That is a
credential and settings problem with its own fix, and this rename neither causes
nor cures it.

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
