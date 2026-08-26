#!/bin/bash
# Capture Brother printer driver packages for vendoring (SDD §22 Level 3, §24).
#
# Brother's linux-brprinter-installer is interactive, downloads at run time, and
# calls lpadmin — none of which belongs in an image build. But the resolution it
# performs is deterministic, so this script does the same lookup offline:
#
#     model -> normalised name -> .inf listing -> exact .deb filenames
#
# The .debs land in packages/printing/vendor/brother/ with their checksums and
# the .inf that named them, so the build installs pinned local files and every
# release records exactly which driver went in.
#
# Usage:  scripts/maintenance/fetch-brother-driver.sh MFC-L3740CDWE [MODEL...]
set -euo pipefail

HOST=download.brother.com          # HOSTDEFAULT in the vendor installer
BASE="https://${HOST}/pub/com/linux/linux"
DEST="${DEST:-packages/printing/vendor/brother}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

(( $# )) || die "usage: $0 MODEL [MODEL...]
       e.g. $0 MFC-L3740CDWE
       The model string is what is printed on the device, hyphens and all."

command -v curl >/dev/null || die "curl is required"
mkdir -p "$DEST"

for model in "$@"; do
    # Same normalisation the vendor installer does: uppercase, hyphens removed.
    norm=$(printf '%s' "$model" | tr '[:lower:]' '[:upper:]' | tr -d '-')
    log "Resolving ${model} (${norm})"

    # Brother indexes some models without their regional suffix — MFC-L3740CDWE
    # is published as MFCL3740CDW. The vendor installer handles this by
    # stripping trailing letters and retrying against a suffix list; do the
    # same, so the model printed on the device is what you type here.
    inf="${DEST}/${norm}.inf"
    # Try the full name first, then progressively drop trailing characters:
    # MFCL3740CDWE -> MFCL3740CDW. (The vendor installer strips all trailing
    # letters and re-appends from a suffix table; dropping one char at a time
    # reaches the same answer without carrying its list.)
    resolved=""
    candidates=( "$norm" )
    for n in 1 2 3 4 5; do
        candidates+=( "${norm:0:${#norm}-n}" )
    done
    for candidate in "${candidates[@]}"; do
        [[ -n "$candidate" ]] || continue
        if curl -fsS -o "$inf" "${BASE}/infs/${candidate}" 2>/dev/null \
           && [[ -s "$inf" ]] && grep -q '^\[' "$inf"; then
            resolved="$candidate"
            break
        fi
    done
    if [[ -z "$resolved" ]]; then
        rm -f "$inf"
        die "no driver index for '${model}' (tried: ${candidates[*]})
       at ${BASE}/infs/
       Check the exact model string, or the printer may be driverless-only —
       in which case it needs no vendor driver at all (SDD §21)."
    fi
    if [[ "$resolved" != "$norm" ]]; then
        info "indexed as ${resolved} (Brother drops the regional suffix)"
        mv "$inf" "${DEST}/${resolved}.inf"
        inf="${DEST}/${resolved}.inf"
    fi

    product=$(grep -o '\[.*\]' "$inf" | tr -d '[]' | head -1)
    info "product: ${product:-unknown}"

    # The build only consumes .deb; the .rpm fields are Brother's Fedora path.
    mapfile -t debs < <(
        grep -E '^(PRN_DRV_DEB|PRN_CUP_DEB|PRN_LPD_DEB)=' "$inf" \
        | cut -d= -f2- | grep -v '^$' || true
    )
    (( ${#debs[@]} )) || die "the index for ${model} lists no .deb packages.
       Contents:
$(sed 's/^/         /' "$inf")"

    if grep -q '^REQUIRE32LIB=yes' "$inf"; then
        info "NOTE: this driver needs 32-bit libraries (REQUIRE32LIB=yes)."
        info "      The build links the native binaries only, so it will fail"
        info "      the ldd check unless matching :i386 libraries are added to"
        info "      packages/printing/packages.list."
    fi

    for deb in "${debs[@]}"; do
        info "fetching ${deb}"
        curl -fsS -o "${DEST}/${deb}" "${BASE}/packages/${deb}" \
            || die "could not download ${BASE}/packages/${deb}"
    done

    # Scanner drivers are MFC-only and are not installed by the image; report
    # them rather than silently ignoring a half-captured device.
    scanner=$(grep -E '^SCANNER_DRV=' "$inf" | cut -d= -f2- || true)
    [[ -n "$scanner" ]] && info "scanner driver available but NOT vendored: ${scanner}"
done

log "Recording checksums"
( cd "$DEST" && sha256sum ./*.deb > SHA256SUMS )
info "$(grep -c . "${DEST}/SHA256SUMS") package(s) in ${DEST}"
ls -la "$DEST"/*.deb | sed 's/^/      /'

cat <<EOF

Next steps:
  1. Review the .debs above and commit them together with their .inf and
     SHA256SUMS — they are the pinned driver for this release (SDD §47).
  2. Record the printer model in docs/printing.md (SDD §22 requires a documented
     reason for every Level 2/3 driver).
  3. just build && just verify
EOF
