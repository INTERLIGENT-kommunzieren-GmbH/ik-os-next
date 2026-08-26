#!/bin/bash
# SDD §17 validation and acceptance criteria 13-15.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
echo "== docker =="

check "docker version"        docker version
check "docker compose version" docker compose version
check "docker buildx version"  docker buildx version
check "hello-world runs"       docker run --rm docker.io/library/hello-world

echo "-- SDD §18: Podman must not have replaced Docker --"
check "docker is the primary runtime" test -x /usr/bin/docker
check "podman is present but secondary" bash -c 'command -v podman && ! docker version 2>&1 | grep -qi podman'

echo "-- SDD §19: project dependencies come from containers --"
check "a compose project can start" bash -c '
  d=$(mktemp -d); cd "$d"
  printf "services:\n  t:\n    image: docker.io/library/debian:forky-slim\n    command: true\n" > compose.yaml
  docker compose up --quiet-pull --exit-code-from t t; rc=$?; docker compose down -v >/dev/null 2>&1; cd /; rm -rf "$d"; exit $rc'

echo "-- SDD §51: the security implication is documented --"
check "docker security note shipped" test -f /usr/share/doc/ik-os/docker-security.md

summary
