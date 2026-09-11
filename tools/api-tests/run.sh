#!/usr/bin/env bash
# Runs the site API tests against a throwaway Redis on a non-default port, so
# it can never reach a real one.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${REDIS_PORT:-6399}"

if ! command -v redis-server >/dev/null 2>&1; then
  echo "redis-server is not installed; skipping." >&2
  echo "  macOS:  brew install redis" >&2
  exit 0
fi

# The suite starts with FLUSHALL, so it must only ever speak to a server it
# started itself. Reusing whatever happens to be listening would wipe it.
if redis-cli -p "$PORT" ping >/dev/null 2>&1; then
  echo "Something is already listening on port $PORT." >&2
  echo "These tests erase the database they run against, so they will not reuse it." >&2
  echo "Stop it, or pick another port:  REDIS_PORT=6400 $0" >&2
  exit 1
fi

redis-server --port "$PORT" --save '' --appendonly no --daemonize yes
trap 'redis-cli -p "$PORT" shutdown nosave >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 20); do
  redis-cli -p "$PORT" ping >/dev/null 2>&1 && break
  sleep 0.2
done
redis-cli -p "$PORT" ping >/dev/null 2>&1 || { echo "redis-server did not come up" >&2; exit 1; }

REDIS_PORT="$PORT" node run.mjs
