# Why the container signature policy looks like this

`policy.json` cannot carry comments. containers/image validates it against a
strict schema and **rejects any unrecognised key**, including `_comment` — the
failure surfaces only when something reads the policy, e.g. part-way through
`bootc install`. Keep the rationale here instead.

## SDD §45 is expressed as a per-repository requirement, not a global reject

The obvious reading of "verify image signatures before installation" is
`"default": [{"type": "reject"}]` plus an allow-list. That is wrong here, and
breaks both of ik-os's install paths:

| Transport | Used by | Signable? |
| --- | --- | --- |
| `containers-storage:` | `bootc install to-disk` reading the local image | no |
| `oci-archive:` | the installer ISO carrying the image on the medium | no |
| `docker-archive:` | `podman save`/`load` during development | no |

None of these is a network fetch, and sigstore cannot sign any of them.
Rejecting them buys no security and stops installation dead.

So the policy defaults to `insecureAcceptAnything` and pins a `sigstoreSigned`
requirement on the ik-os repository specifically. A pull of
`ghcr.io/interligent-kommunzieren-gmbh/ik-os-next` — the thing SDD §45 is actually
about — must carry a valid cosign signature made by the CI key, verified
against `/etc/pki/containers/ghcr.io-ik-os-next.pub`. This is the same shape
Universal Blue uses.

## If you tighten this

Anything stricter must still permit `containers-storage` and `oci-archive`, or
`bootc install` and the ISO stop working. `build/validation/verify-image.sh`
asserts both, plus that the top-level keys stay within the schema.
