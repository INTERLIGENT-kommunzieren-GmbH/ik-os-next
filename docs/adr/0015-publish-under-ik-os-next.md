# ADR 0015 — The image publishes as `ik-os-next`, not `ik-os`

**Status:** accepted
**SDD:** §40, §45; Rules 15, 18

## Context

The first push to `main` failed at the registry:

    denied: permission_denied: write_package

The cause turned out to be a per-package access list, not a name collision and
not an organisation policy: a GHCR package is an object with its own ACL, and
this repository appeared in neither `ik-os`'s nor `ik-os-next`'s. Both packages
already existed — `ik-os-next` as an orphan from the Fedora-44 daily lineage —
so neither push created one, and creation is the only case where the ACL is
granted implicitly. `docs/releases.md` records the settings and the fix.

Two earlier readings of the error are recorded because the reasoning must not be
mistaken for the diagnosis. The first was that GHCR binds a package to the
repository that created it, so this repository could not write to `ik-os`; that
was treated as disproved when the renamed push failed identically, but the
rename was not a valid test — `ik-os-next` was already taken, so the experiment
changed nothing it was meant to change. The second was that the organisation
forbids publishing packages, which never fit the fact that the organisation
publishes three.

The conclusion survives both, because **this ADR decides the name and the reason
for it has nothing to do with permissions.** Sharing a name with the deployed
image would have been wrong even if the first push had succeeded.

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

Publishing works once the package grants this repository Actions access, which
is a settings change rather than a code one; this rename neither caused nor
cured the denial.

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

The original `ik-os` package keeps its own signing key. This ADR previously said
that key existed nowhere outside its repository secret, so no fix could be
published for machines still running that image. **The key was subsequently
recovered** — it verifies `ik-os:stable` and matches the public key that image
embeds — so a signed update for the existing fleet is possible after all, and the
migration no longer has to be a hard cutover for want of a signature.

It remains an argument for completing the migration rather than maintaining both.
The legacy key has now been handled outside a secret store, and it carries an
empty password, so the PEM is the whole secret; the fleet's trust anchor is
weaker than the new image's for as long as the old image is in service.
