#!/usr/bin/env bash
set -euo pipefail

# Run the ProjectFTS stack from this directory.
# Usage:
#   ./scripts/run-project.sh [hub|local] [namespace] [tag]
# Examples:
#   ./scripts/run-project.sh                 # hub mode, NS=tabahi1, TAG=v1 (defaults)
#   ./scripts/run-project.sh hub myns v2     # pull images from myns with tag v2
#   ./scripts/run-project.sh local           # build from source using docker-compose.yml

MODE="${1:-hub}"
NS="${2:-tabahi1}"
TAG="${3:-v1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Missing required command: $1" >&2
    exit 1
  }
}

need docker
# Check docker compose plugin
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: 'docker compose' plugin not found. Please install Docker Compose v2." >&2
  exit 1
fi

SQL_SEED="${ROOT_DIR}/LatestDBExport.sql"

fetch_seed_if_missing() {
  if [[ ! -f "$SQL_SEED" ]]; then
    echo "LatestDBExport.sql not found. Attempting to download..."
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "https://raw.githubusercontent.com/utkarshX-dev/ProjectFTS/main/LatestDBExport.sql" -o "$SQL_SEED" || {
        echo "ERROR: Failed to download LatestDBExport.sql. Please place it at: $SQL_SEED" >&2
        exit 1
      }
      echo "Downloaded LatestDBExport.sql"
    else
      echo "ERROR: curl not available and LatestDBExport.sql missing. Please add the file to repo root." >&2
      exit 1
    fi
  fi
}

case "$MODE" in
  hub)
    # Use Hub images and prod compose
    fetch_seed_if_missing
    if [[ ! -f "docker-compose.prod.yml" ]]; then
      echo "docker-compose.prod.yml not found. Attempting to download..."
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL "https://raw.githubusercontent.com/utkarshX-dev/ProjectFTS/main/docker-compose.prod.yml" -o docker-compose.prod.yml || {
          echo "ERROR: Failed to download docker-compose.prod.yml" >&2
          exit 1
        }
        echo "Downloaded docker-compose.prod.yml"
      else
        echo "ERROR: curl not available and docker-compose.prod.yml missing." >&2
        exit 1
      fi
    fi
    echo "Starting using Docker Hub images: NS=$NS TAG=$TAG"
    DOCKERHUB_NS="$NS" TAG="$TAG" docker compose -f docker-compose.prod.yml up -d
    ;;
  local)
    # Build from source using dev compose
    fetch_seed_if_missing
    echo "Building and starting from local sources (docker-compose.yml)"
    docker compose up -d --build
    ;;
  *)
    echo "Usage: $0 [hub|local] [namespace] [tag]" >&2
    exit 1
    ;;
esac

# Brief status
echo
echo "Services running. Quick status:"
docker compose ps

echo
cat <<EOF
Endpoints:
- Frontend: http://localhost:5173
- Backend API: http://localhost:3000
Postgres is internal on 5432 (mapped).

Notes:
- DB will be seeded from LatestDBExport.sql on first run via the migrate container.
- To stop: docker compose down
- To view logs: docker compose logs -f --tail=100
EOF
