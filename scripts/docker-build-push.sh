#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/docker-build-push.sh <dockerhub-namespace> [tag]
NS="${1:-}"
TAG="${2:-latest}"

if [[ -z "$NS" ]]; then
  echo "Usage: $0 <dockerhub-namespace> [tag]"
  exit 1
fi

images=( projectfts-migrate projectfts-backend projectfts-frontend )

# Build local images using docker-compose targets
export DOCKER_BUILDKIT=1

echo "[1/3] Building images via docker compose..."
docker compose build

# Tag and push each image
for img in "${images[@]}"; do
  local_tag="${img}:latest"
  remote_tag="${NS}/${img}:${TAG}"
  echo "[2/3] Tagging $local_tag -> $remote_tag"
  docker tag "$local_tag" "$remote_tag"
  echo "[3/3] Pushing $remote_tag"
  docker push "$remote_tag"
done

echo "Done. Pushed: ${images[*]} with tag ${TAG} to ${NS}"
