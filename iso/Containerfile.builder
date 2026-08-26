# Builder for the ik-os UEFI live installer ISO.
# Debian-native on purpose: bootc-image-builder's anaconda-iso path is RPM-only
# and cannot produce a Debian installer (docs/adr/0003-installer-iso.md).
FROM docker.io/library/debian:stable

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        mmdebstrap \
        squashfs-tools \
        xorriso \
        grub-efi-amd64-bin \
        grub-common \
        dosfstools \
        mtools \
        skopeo \
        ca-certificates \
        zstd \
        rsync \
    && rm -rf /var/lib/apt/lists/*

COPY build-iso.sh /usr/local/bin/build-iso.sh
RUN chmod +x /usr/local/bin/build-iso.sh
