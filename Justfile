export image_name := env("IMAGE_NAME", "ik-os")
export default_tag := env("DEFAULT_TAG", "testing")
export output_dir := env("OUTPUT_DIR", "output")

[private]
default:
    @just --list

# --- image ----------------------------------------------------------------

# Build the ik-os container image
[group('Build')]
build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail
    BUILD_ARGS=()
    if [[ -z "$(git status -s)" ]]; then
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    fi
    BUILD_ARGS+=("--build-arg" "IK_OS_CHANNEL=${tag}")
    # Same scheme CI uses (<channel>.<YYYYMMDD>.<build>), with "local" where CI
    # puts the run number. Without this the arg defaults to "dev" and every
    # locally built image -- and every `bootc status` on every test VM -- reports
    # the same version forever.
    #
    # Date-only on purpose. The Containerfile turns this into an ENV ahead of the
    # single RUN that executes every build script, so a version that changed per
    # build would make even a no-op `just build` a full rebuild. Two builds on
    # the same day are told apart by the image digest, which `ik-os version`
    # prints and which is what actually re-triggers provisioning (ADR 0010).
    BUILD_ARGS+=("--build-arg" "IK_OS_VERSION=${tag}.$(date -u +%Y%m%d).local")
    podman build "${BUILD_ARGS[@]}" --pull=newer --tag "${target_image}:${tag}" .

    # verify-image.sh runs inside the container and so cannot see the image's own
    # labels. `skopeo inspect` on a published image is the only place these are
    # read, which is exactly where nobody would notice them being empty.
    for label in version revision; do
        # jq rather than a Go --format template: those need doubled braces,
        # which are just's own interpolation syntax and have to be escaped into
        # unreadability inside a recipe.
        key="org.opencontainers.image.${label}"
        value=$(podman inspect "${target_image}:${tag}" | jq -r ".[0].Labels[\"${key}\"] // empty")
        [[ -n "$value" ]] || { echo "${key} is empty" >&2; exit 1; }
        echo "${key}: ${value}"
    done

# Re-run only the in-image acceptance checks against an already built image
[group('Build')]
verify $target_image=image_name $tag=default_tag:
    podman run --rm --security-opt label=disable \
        -v "$PWD/build/validation:/v:ro" \
        "{{ target_image }}:{{ tag }}" /v/verify-image.sh

# --- disk images ----------------------------------------------------------
# bootc installs itself. bootc-image-builder is deliberately not used: its
# anaconda-iso path is RPM-only and cannot build a Debian installer.

# bootc install runs as root, so the image must exist in root's container
# storage. Works whether you run `just build-qcow2` or `sudo just build-qcow2`:
# under sudo the image is read from the *invoking* user's storage, not root's.
# `podman save | podman load` is used rather than `podman image scp` because it
# does not depend on podman's ssh machinery and behaves the same either way.
[private]
_rootful_load $target_image $tag:
    #!/usr/bin/env bash
    set -euo pipefail

    sudo() { if [[ $EUID -eq 0 ]]; then "$@"; else command sudo "$@"; fi; }

    # Who owns the user-level copy of the image?
    if [[ -n "${SUDO_USER:-}" ]]; then
        owner="$SUDO_USER"
    elif [[ $EUID -eq 0 ]]; then
        echo "error: running as root with no SUDO_USER, and ${target_image}:${tag}" >&2
        echo "       is not in root's storage. Run 'just build' first, or run this" >&2
        echo "       recipe as your normal user." >&2
        exit 1
    else
        owner="$USER"
    fi

    src_id=$(sudo -u "$owner" podman image inspect --format '{{ '{{.Id}}' }}' \
        "${target_image}:${tag}" 2>/dev/null || true)
    if [[ -z "$src_id" ]]; then
        echo "error: ${target_image}:${tag} not found in ${owner}'s storage." >&2
        echo "       Run 'just build' first." >&2
        exit 1
    fi

    # Compare IDs, not just existence: after a rebuild root still holds the
    # previous image under the same tag, and reusing it would silently test
    # stale bits.
    dst_id=$(sudo podman image inspect --format '{{ '{{.Id}}' }}' \
        "${target_image}:${tag}" 2>/dev/null || true)
    # The image ID is the *config* digest, which does NOT change when the
    # manifest format does. Compare the manifest type too, or a stale Docker
    # v2s2 copy looks "current" and the composefs install fails later.
    dst_fmt=$(sudo podman image inspect --format '{{ '{{.ManifestType}}' }}' \
        "${target_image}:${tag}" 2>/dev/null || true)
    if [[ "$src_id" == "$dst_id" \
       && "$dst_fmt" == application/vnd.oci.image.manifest.v1+json ]]; then
        echo "root's ${target_image}:${tag} is already current (${src_id:7:12}, OCI)"
        exit 0
    fi
    if [[ "$src_id" == "$dst_id" && -n "$dst_fmt" ]]; then
        echo "root's copy has the right ID but the wrong format (${dst_fmt});"
        echo "re-copying as OCI..."
        sudo podman rmi -f "${target_image}:${tag}" >/dev/null 2>&1 || true
    fi
    [[ -n "$dst_id" ]] && echo "root has a stale copy (${dst_id:7:12}); replacing with ${src_id:7:12}"

    # --format oci-archive is REQUIRED, not cosmetic. `podman save` defaults to
    # docker-archive, which rewrites an OCI image into Docker v2s2 on the way
    # through. bootc's composefs backend only supports OCI and fails with
    # "Invalid splitstream content type" (bootc-dev/bootc#1703).
    echo "copying ${target_image}:${tag} from ${owner} into root's storage (OCI)..."
    sudo -u "$owner" podman save --format oci-archive "${target_image}:${tag}" \
        | sudo podman load

    # Prove the format survived; a v2s2 image here breaks the install much later
    # and much less clearly.
    got=$(sudo podman image inspect --format '{{ '{{.ManifestType}}' }}' \
        "${target_image}:${tag}")
    case "$got" in
        application/vnd.oci.image.manifest.v1+json) echo "manifest: OCI ✓" ;;
        *) echo "error: root's copy is '${got}', not OCI." >&2
           echo "       bootc's composefs backend requires OCI." >&2
           exit 1 ;;
    esac

[private]
_install-to-disk $target_image $tag $name $size: (_rootful_load target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    sudo() { if [[ $EUID -eq 0 ]]; then "$@"; else command sudo "$@"; fi; }
    # Artefacts belong to the human, not to root, even under `sudo just`.
    as_user="${SUDO_USER:-$USER}"

    mkdir -p "${output_dir}"
    OUT=$(realpath "${output_dir}")
    # bootc writes into an existing file; pre-allocate it sparsely.
    rm -f "${OUT}/${name}.raw"
    truncate -s "${size}" "${OUT}/${name}.raw"

    # Backend and bootloader are project decisions, not ad-hoc flags.
    # shellcheck disable=SC1091
    set -a; . ./config/image.env; set +a
    INSTALL_FLAGS=(--bootloader "${BOOTC_BOOTLOADER}")
    [[ "${BOOTC_BACKEND}" == "composefs" ]] && INSTALL_FLAGS+=(--composefs-backend)
    [[ "${BOOTC_ALLOW_MISSING_VERITY}" == "true" ]] && INSTALL_FLAGS+=(--allow-missing-verity)
    echo "install flags: ${INSTALL_FLAGS[*]}"

    if [[ "${BOOTC_BACKEND}" == "composefs" ]]; then
        mt=$(sudo podman image inspect --format '{{ '{{.ManifestType}}' }}' \
            "${target_image}:${tag}")
        [[ "$mt" == application/vnd.oci.image.manifest.v1+json ]] || {
            echo "error: ${target_image}:${tag} is '${mt}'." >&2
            echo "       The composefs backend only supports OCI images." >&2
            exit 1; }
    fi

    sudo podman run --rm --privileged --pid=host \
        --security-opt label=type:unconfined_t \
        -v /var/lib/containers:/var/lib/containers \
        -v /dev:/dev \
        -v "${OUT}:/output" \
        "${target_image}:${tag}" \
        bootc install to-disk --via-loopback --wipe \
            --filesystem btrfs "${INSTALL_FLAGS[@]}" "/output/${name}.raw"

    sudo chown -R "${as_user}:${as_user}" "${OUT}"
    echo "wrote ${OUT}/${name}.raw"

# Build a raw disk image
[group('Build')]
build-raw $target_image=image_name $tag=default_tag size="32G": (_install-to-disk target_image tag "ik-os" size)

# Build a QCOW2 virtual machine image
[group('Build')]
build-qcow2 $target_image=image_name $tag=default_tag size="32G": (_install-to-disk target_image tag "ik-os" size)
    #!/usr/bin/env bash
    set -euo pipefail
    qemu-img convert -f raw -O qcow2 "${output_dir}/ik-os.raw" "${output_dir}/ik-os.qcow2"
    rm -f "${output_dir}/ik-os.raw"
    chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "${output_dir}/ik-os.qcow2" 2>/dev/null || true
    echo "wrote ${output_dir}/ik-os.qcow2"

# Build the UEFI live installer ISO
[group('Build')]
build-iso $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail

    sudo() { if [[ $EUID -eq 0 ]]; then "$@"; else command sudo "$@"; fi; }
    as_user="${SUDO_USER:-$USER}"

    # The ISO assembly container runs privileged, i.e. under root's podman, so
    # it has to live in root's storage too — same reason as the ik-os image.
    podman build -t ik-os-iso-builder -f iso/Containerfile.builder iso
    just _rootful_load ik-os-iso-builder latest
    # Single source of truth for the install flags, shared with build-qcow2.
    cp config/image.env iso/image.env
    trap 'rm -f iso/image.env' EXIT

    mkdir -p "${output_dir}"
    OUT=$(realpath "${output_dir}")

    # The payload is exported from the *user's* storage, where `just build`
    # leaves it.
    echo "exporting ${target_image}:${tag} as an OCI archive..."
    rm -f "${OUT}/ik-os-payload.oci"
    podman save --format oci-archive -o "${OUT}/ik-os-payload.oci" \
        "${target_image}:${tag}"

    sudo podman run --rm --privileged \
        -v "${OUT}:/output" -v "$PWD/iso:/iso:ro" \
        -e PAYLOAD=/output/ik-os-payload.oci \
        -e "TARGET_REF=${target_image}:${tag}" \
        ik-os-iso-builder /iso/build-iso.sh

    sudo chown -R "${as_user}:${as_user}" "${OUT}"
    rm -f "${OUT}/ik-os-payload.oci"
    ls -lh "${OUT}"/*.iso

# --- run ------------------------------------------------------------------

# A separate recipe because `just run-vm ssh=true` is positional and silently
# lands in ram — the failure mode is a confusing qemu error about -m.
# Boot the VM with sshd reachable at 127.0.0.1:2222 (debugging only)
[group('Run')]
run-vm-ssh ram="8G" cpus="4":
    @just run-vm "{{ ram }}" "{{ cpus }}" true

# The third argument enables the ssh forward; prefer run-vm-ssh for that.
# Boot the built qcow2 in a UEFI VM
[group('Run')]
run-vm ram="8G" cpus="4" ssh="false":
    #!/usr/bin/env bash
    set -euo pipefail
    DISK="${output_dir}/ik-os.qcow2"
    [[ -f "$DISK" ]] || { echo "no ${DISK}; run 'just build-qcow2' first"; exit 1; }

    # Locate OVMF: the path differs between Fedora and Debian hosts.
    CODE=""
    for c in /usr/share/edk2/ovmf/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
        [[ -f "$c" ]] && { CODE="$c"; break; }
    done
    [[ -n "$CODE" ]] || { echo "no OVMF firmware found; install edk2-ovmf"; exit 1; }
    VARS_SRC="${CODE%CODE*}VARS.fd"
    [[ -f "$VARS_SRC" ]] || VARS_SRC=/usr/share/OVMF/OVMF_VARS.fd

    # NVRAM must be writable: systemd-boot writes its EFI boot entry there.
    VARS="${output_dir}/OVMF_VARS.ik-os.fd"
    [[ -f "$VARS" ]] || cp "$VARS_SRC" "$VARS"

    # QEMU user-mode networking puts the guest behind NAT on 10.0.2.15 with no
    # inbound path, so sshd running inside the VM is unreachable from the host
    # without this. Debugging aid only: SDD §50 masks ssh.service in the image,
    # and enabling it inside a VM is a deliberate, temporary deviation. Never do
    # it on a deployed machine, and do not leave a VM with a weak password
    # running on a network you do not control.
    NETDEV="user,id=n0"
    if [[ "{{ ssh }}" == "true" ]]; then
        NETDEV="user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22"
        echo "ssh: forwarding 127.0.0.1:2222 -> guest:22 (bound to loopback only)"
        echo "     inside the VM: sudo systemctl unmask ssh && sudo systemctl enable --now ssh"
    fi

    echo "firmware: ${CODE}"
    exec qemu-system-x86_64 \
        -machine q35,accel=kvm -cpu host \
        -m "{{ ram }}" -smp "{{ cpus }}" \
        -drive if=pflash,format=raw,readonly=on,file="$CODE" \
        -drive if=pflash,format=raw,file="$VARS" \
        -drive file="$DISK",format=qcow2,if=virtio \
        -device virtio-vga -display gtk,gl=on \
        -device virtio-net,netdev=n0 -netdev "$NETDEV" \
        -device virtio-rng-pci

# --- checks ---------------------------------------------------------------

# Shellcheck every script in the repository
[group('Check')]
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t files < <(
        find build scripts migration iso tests -type f \
             \( -name '*.sh' -o -name 'ik-os' -o -name 'ik-os-*' \) \
             ! -name '*.service' | sort
    )
    (( ${#files[@]} )) || { echo "no scripts found"; exit 1; }
    printf '  %s\n' "${files[@]}"
    shellcheck -x -S warning "${files[@]}"
    echo "shellcheck clean (${#files[@]} files)"

# Verify every package list resolves against the current Debian archive
[group('Check')]
check-packages:
    podman run --rm --security-opt label=disable -v "$PWD:/repo:ro" \
        docker.io/library/debian:forky \
        bash /repo/build/validation/check-packages.sh

# Check the Brewfile resolves against homebrew/core and the declared taps
[group('Check')]
check-brewfile:
    ./build/validation/check-brewfile.sh

# Check every Flatpak in system-flatpaks.list resolves on Flathub
[group('Check')]
check-flatpaks:
    ./build/validation/check-flatpaks.sh

# Behaviourally test the container signature policy
[group('Check')]
check-policy:
    ./build/validation/check-policy.sh

# Check Justfile formatting
[group('Check')]
check:
    just --unstable --fmt --check -f Justfile

# Format the Justfile
[group('Check')]
fix:
    just --unstable --fmt -f Justfile

# Remove build artefacts
[group('Utility')]
clean:
    rm -rf "{{ output_dir }}" _build*
