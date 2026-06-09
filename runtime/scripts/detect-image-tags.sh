#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

source runtime/scripts/engine.sh

mkdir -p runtime/generated

get_latest_tag() {
  local repo="$1"
  engine images --format '{{.Repository}} {{.Tag}}' \
    | awk -v repo="$repo" '$1 == repo && $2 != "<none>" { print $2 }' \
    | sort -rV \
    | head -n1
}

WORLD_TAG="$(get_latest_tag registry.funcom.com/funcom/self-hosting/seabass-server)"
POSTGRES_TAG="$(get_latest_tag registry.funcom.com/funcom/self-hosting/igw-postgres)"

if [ -z "$WORLD_TAG" ]; then
  echo "Could not detect seabass-server image tag"
  exit 1
fi

if [ -z "$POSTGRES_TAG" ]; then
  echo "Could not detect igw-postgres image tag"
  exit 1
fi

cat > runtime/generated/image-tags.env <<EOF
DUNE_WORLD_IMAGE_TAG=$WORLD_TAG
DUNE_POSTGRES_IMAGE_TAG=$POSTGRES_TAG
EOF

echo "Wrote runtime/generated/image-tags.env"
cat runtime/generated/image-tags.env
