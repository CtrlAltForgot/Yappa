#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

if [[ $# -ne 4 ]]; then
  echo "Use: run-server-runtime-container.sh IMAGE PACKAGE_MANAGER BACKEND NAME" >&2
  exit 64
fi
BASE_IMAGE="$1"
PACKAGE_MANAGER="$2"
BACKEND="$3"
NAME="$4"
REPOSITORY_ROOT="$(git rev-parse --show-toplevel)"
IMAGE_TAG="yappa-runtime-contract:${NAME//[^a-zA-Z0-9_.-]/-}"
CONTAINER_NAME="yappa-runtime-${NAME//[^a-zA-Z0-9_.-]/-}-$$"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker build \
  --file "$REPOSITORY_ROOT/.github/runtime-fixtures/linux-systemd.Dockerfile" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  --build-arg "PACKAGE_MANAGER=$PACKAGE_MANAGER" \
  --tag "$IMAGE_TAG" \
  "$REPOSITORY_ROOT/.github/runtime-fixtures"
docker run --detach \
  --name "$CONTAINER_NAME" \
  --privileged \
  --cgroupns=host \
  --tmpfs /run \
  --tmpfs /run/lock \
  --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --volume "$REPOSITORY_ROOT:/workspace:ro" \
  "$IMAGE_TAG"
for _ in {1..40}; do
  if docker exec "$CONTAINER_NAME" systemctl is-system-running \
    >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
docker exec "$CONTAINER_NAME" \
  /workspace/.github/scripts/test-server-runtime-contract.sh "$BACKEND"
