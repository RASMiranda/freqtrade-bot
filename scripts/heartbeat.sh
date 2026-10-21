#!/bin/sh
# Cron-driven liveness check. Pings the bot API, then reports to healthchecks.io
# (HC_PING_URL on success, HC_PING_URL/fail on failure). healthchecks.io sends
# the emails, so there is no mail code here.
#
# .env is sourced only if it exists; variables that are already in the
# environment (for example under `bws run`) win over it.
#
# Exit: 0 bot up (or HC_PING_URL unset), 1 bot down, 2 healthchecks unreachable.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)

env_hc=${HC_PING_URL:-}
env_api=${API_URL:-}
if [ -r "$ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
fi
[ -n "$env_hc" ] && HC_PING_URL=$env_hc
[ -n "$env_api" ] && API_URL=$env_api
API_URL=${API_URL:-http://127.0.0.1:8080}

log() { printf '%s heartbeat: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

if curl -fsS -m 10 -o /dev/null "$API_URL/api/v1/ping" 2>/dev/null; then
  state=up
else
  state=down
fi

if [ -z "${HC_PING_URL:-}" ]; then
  log "HC_PING_URL not set; api $state, nothing reported"
  [ "$state" = up ] && exit 0
  exit 1
fi

base=${HC_PING_URL%/}
if [ "$state" = up ]; then
  target=$base
else
  target=$base/fail
fi

if curl -fsS -m 10 --retry 3 -o /dev/null "$target" 2>/dev/null; then
  log "api $state; reported"
else
  log "api $state; could not reach healthchecks"
  exit 2
fi
[ "$state" = up ]
