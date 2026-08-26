#!/bin/bash
# SDD §17, §51 — Docker Engine, Compose v2 and Buildx from Debian packages.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Configuring Docker"

# SDD §17 — `docker compose` must work without a manually installed binary.
# Debian ships Compose v2 as /usr/bin/docker-compose; wire it up as a CLI plugin
# so the subcommand form resolves.
mkdir -p /usr/libexec/docker/cli-plugins
for plugin in compose buildx; do
    if [[ -x "/usr/libexec/docker/cli-plugins/docker-${plugin}" ]]; then
        continue
    elif [[ -x "/usr/lib/docker/cli-plugins/docker-${plugin}" ]]; then
        ln -sf "/usr/lib/docker/cli-plugins/docker-${plugin}" \
               "/usr/libexec/docker/cli-plugins/docker-${plugin}"
    elif [[ -x "/usr/bin/docker-${plugin}" ]]; then
        ln -sf "/usr/bin/docker-${plugin}" \
               "/usr/libexec/docker/cli-plugins/docker-${plugin}"
    else
        die "docker-${plugin} not found. SDD §17 requires Compose and Buildx to
       work out of the box; refusing to ship an image without them."
    fi
done

install -Dm0644 "${CTX}/config/docker/daemon.json" /usr/lib/ik-os/docker/daemon.json
cat > /usr/lib/tmpfiles.d/ik-os-docker.conf <<'EOF'
d /etc/docker 0755 root root -
C /etc/docker/daemon.json 0644 root root - /usr/lib/ik-os/docker/daemon.json
EOF

# SDD §17 — the daemon is a system service.
systemctl enable docker.service containerd.service 2>/dev/null || true

# SDD §51 — docker group membership is root-equivalent. The group is created
# here; membership is granted by first boot according to company policy, and the
# implication is documented for the user.
groupadd -f -r docker
install -Dm0644 "${CTX}/config/docker/README.security.md" \
    /usr/share/doc/ik-os/docker-security.md
