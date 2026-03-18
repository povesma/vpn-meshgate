#!/usr/bin/env bash
# Run E2E tests from a local Tailscale container on Mac.
# Usage: ./tests/run-e2e.sh [--rebuild]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONTAINER="ts-local-test"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.test.yml"

# Load .env
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
else
    echo "ERROR: .env not found at $PROJECT_DIR/.env"
    exit 1
fi

# Rebuild if requested or if image doesn't exist
if [ "${1:-}" = "--rebuild" ] || ! docker image inspect ts-local-test-image >/dev/null 2>&1; then
    echo "Building test client image..."
    docker compose -f "$COMPOSE_FILE" --env-file "$PROJECT_DIR/.env" build
fi

# Check if container is running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "Container $CONTAINER is running."
else
    echo "Starting $CONTAINER..."
    docker compose -f "$COMPOSE_FILE" --env-file "$PROJECT_DIR/.env" up -d
    echo "Waiting for Tailscale to connect..."
    for i in $(seq 1 30); do
        if docker exec "$CONTAINER" tailscale status >/dev/null 2>&1; then
            echo "  Connected after ${i}s"
            break
        fi
        sleep 1
        if [ "$i" -eq 30 ]; then
            echo "ERROR: Tailscale did not connect within 30s"
            docker logs "$CONTAINER" --tail 20
            exit 1
        fi
    done
fi

# Show current tailscale status
echo ""
echo "Tailscale status:"
docker exec "$CONTAINER" tailscale status
echo ""

# Run the test suite
echo "Running E2E tests..."
echo "============================================"
docker exec "$CONTAINER" /usr/local/bin/e2e-test.sh
EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "E2E tests completed successfully."
else
    echo "E2E tests had failures (exit code: $EXIT_CODE)"
fi

exit $EXIT_CODE
