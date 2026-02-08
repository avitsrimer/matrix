#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <username> [--admin]"
    echo "Example: $0 ivan"
    echo "Example: $0 ivan --admin"
    exit 1
fi

USERNAME="$1"
ADMIN_FLAG=""
if [ "${2:-}" = "--admin" ]; then
    ADMIN_FLAG="--admin"
fi

echo "Creating user: $USERNAME"
echo "Enter password when prompted."
echo ""

docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec synapse \
    register_new_matrix_user \
    -c /data/homeserver.yaml \
    -u "$USERNAME" \
    $ADMIN_FLAG \
    http://localhost:8008
