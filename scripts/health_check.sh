#!/usr/bin/env bash
set -euo pipefail
URL="$1"
TRIES=30
SLEEP=3
for i in $(seq 1 $TRIES); do
  if curl -fsS "$URL" >/dev/null; then
    echo "healthy"
    exit 0
  fi
  echo "waiting for app... ($i/$TRIES)"
  sleep $SLEEP
done
echo "unhealthy"
exit 1