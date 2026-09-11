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

STARTED=0
if ! redis-cli -p "$PORT" ping >/dev/null 2>&1; then
  redis-server --port "$PORT" --save '' --appendonly no --daemonize yes
  STARTED=1
  for _ in $(seq 1 20); do
    redis-cli -p "$PORT" ping >/dev/null 2>&1 && break
    sleep 0.2
  done
fi
trap '[ "$STARTED" = "1" ] && redis-cli -p "$PORT" shutdown nosave >/dev/null 2>&1 || true' EXIT

REDIS_PORT="$PORT" node run.mjs
