# ik-os — company-managed immutable Debian developer workstation.
# SDD: docs/SDD.md. Rule 1: the base is Debian and stays Debian.

# --------------------------------------------------------------------------
# Build context. Kept in its own stage so the build scripts and configuration
# are readable during the build without ending up in the shipped image.
# --------------------------------------------------------------------------
FROM scratch AS ctx
COPY build     /build
COPY config    /config
COPY packages  /packages
COPY desktop   /desktop
COPY systemd   /systemd
COPY scripts   /scripts
COPY migration /migration
COPY branding  /branding
COPY hardware  /hardware
COPY tests     /tests

# --------------------------------------------------------------------------
# bootc is the only component Debian does not package. On Debian 14, ostree
# (2026.2) and composefs (1.0.8) are both provided by the archive and are new
# enough for bootc, so only bootc is built from a pinned upstream tag.
# See docs/adr/0001-bootc-from-source.md.
# --------------------------------------------------------------------------
FROM docker.io/library/debian:forky AS bootc-builder

ARG BOOTC_VERSION=v1.16.9
ENV DEBIAN_FRONTEND=noninteractive

# bootc links against Debian's libostree and libcomposefs — the same libraries
# the final image ships, so there is no version skew between build and runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git pkgconf \
        libostree-dev libcomposefs-dev libzstd-dev libssl-dev \
        go-md2man \
    && rm -rf /var/lib/apt/lists/*

ENV CARGO_HOME=/tmp/rust RUSTUP_HOME=/tmp/rust
ENV PATH=/tmp/rust/bin:$PATH
# Download then run, rather than curl | sh: a pipeline hides curl's exit status.
RUN curl --proto '=https' --tlsv1.2 -sSfo /tmp/rustup.sh https://sh.rustup.rs \
    && sh /tmp/rustup.sh --profile minimal --default-toolchain stable -y \
    && rm -f /tmp/rustup.sh

WORKDIR /src/bootc
RUN git clone --depth 1 --branch "${BOOTC_VERSION}" \
        https://github.com/bootc-dev/bootc.git . \
    && make bin \
    && make install-all DESTDIR=/output

# Fail here rather than three stages later if the layout is not what we expect.
RUN test -x /output/usr/bin/bootc \
    && echo "bootc: $(/output/usr/bin/bootc --version)"

# --------------------------------------------------------------------------
# Flatpaks baked into the image (config/desktop/preinstalled-flatpaks.list).
# A stage of its own for the same reason bootc has one: this downloads ~2.4 GB,
# and it must not be repeated every time an unrelated build script changes.
# See docs/adr/0014-preinstalled-flatpaks.md.
# --------------------------------------------------------------------------
FROM docker.io/library/debian:forky AS flatpak-preinstall

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        flatpak ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    CTX=/ctx /ctx/build/scripts/preinstall-flatpaks.sh

# --------------------------------------------------------------------------
# ik-os itself.
# --------------------------------------------------------------------------
FROM docker.io/library/debian:forky AS ik-os

ARG IK_OS_VERSION=dev
ARG IK_OS_BUILD_ID=local
ARG IK_OS_CHANNEL=testing
ARG SHA_HEAD_SHORT=unknown

ENV DEBIAN_FRONTEND=noninteractive \
    CTX=/ctx \
    IK_OS_VERSION=${IK_OS_VERSION} \
    IK_OS_BUILD_ID=${IK_OS_BUILD_ID} \
    IK_OS_CHANNEL=${IK_OS_CHANNEL} \
    SHA_HEAD_SHORT=${SHA_HEAD_SHORT}

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# systemd expects SIGRTMIN+3 to mean "shut down".
STOPSIGNAL SIGRTMIN+3

# No apt cache mount here on purpose: 95-finalize.sh has to empty /var, and a
# live mount under /var/cache cannot be unlinked from inside the build. The
# archive re-download is ~80 MB and keeps the build self-contained.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=bootc-builder,source=/output,target=/prebuilt \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/scripts/00-preflight.sh \
 && /ctx/build/scripts/10-ostree-layout.sh \
 && /ctx/build/scripts/20-packages.sh \
 && /ctx/build/scripts/25-kernel.sh \
 && PREBUILT=/prebuilt /ctx/build/scripts/30-bootc.sh \
 && /ctx/build/scripts/40-boot.sh \
 && /ctx/build/scripts/50-desktop.sh \
 && /ctx/build/scripts/55-branding.sh \
 && /ctx/build/scripts/57-initramfs.sh \
 && /ctx/build/scripts/60-docker.sh \
 && /ctx/build/scripts/65-printing.sh \
 && /ctx/build/scripts/67-printer-vendor.sh \
 && /ctx/build/scripts/70-company.sh \
 && /ctx/build/scripts/75-flatpak.sh \
 && /ctx/build/scripts/80-homebrew.sh \
 && /ctx/build/scripts/85-systemd.sh \
 && /ctx/build/scripts/90-cli.sh \
 && /ctx/build/scripts/95-finalize.sh

# After the RUN above, because 95-finalize.sh empties /var: anything copied here
# earlier would be deleted, and anything present during that step would be
# captured into tmpfiles.d as 2.4 GB of directory entries. This is the one thing
# in /var the image ships deliberately -- bootc applies it at install time, and
# ik-os-firstboot installs the rest.
COPY --from=flatpak-preinstall /var/lib/flatpak /var/lib/flatpak

# The Debian base image ships /etc/hostname = "debuerreotype" (the tool Debian
# builds its images with), so without this every machine in the fleet answers to
# that name. It has to be COPY: podman bind-mounts /etc/hostname over every RUN,
# so a build script cannot write it (the change lands in the mount, not the
# layer) and cannot remove it (EBUSY). ik-os-firstboot replaces this placeholder
# with a per-machine name.
COPY config/hostname /etc/hostname

LABEL containers.bootc="1" \
      ostree.bootable="1" \
      org.opencontainers.image.title="ik-os" \
      org.opencontainers.image.description="Interligent immutable Debian developer workstation" \
      org.opencontainers.image.vendor="Interligent Kommunizieren GmbH" \
      org.opencontainers.image.base.name="docker.io/library/debian:forky" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${IK_OS_VERSION}" \
      org.opencontainers.image.revision="${SHA_HEAD_SHORT}"

# Upstream's own check that the image is a valid bootc target.
RUN bootc container lint

# ik-os's acceptance checks: the SDD requirements a container can verify
# without booting (SDD §63). Booted checks live in tests/boot and tests/hardware.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/build/validation/verify-image.sh
