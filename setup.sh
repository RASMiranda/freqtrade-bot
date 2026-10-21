#!/bin/sh
# One-command setup: checks prerequisites, creates .env, generates the API
# password and JWT secret, starts the bot (dry-run) and fetches some data.
#
#   SECRETS_BACKEND=env (default)  secrets are written to .env at mode 600.
#   SECRETS_BACKEND=bws            secrets are printed once, to your terminal,
#                                  so you can save them in Bitwarden. Nothing
#                                  secret is written to disk.
#
# Options (environment): SETUP_DATA=live|fixture|skip (default live),
# SETUP_DATA_DAYS (default 14), SETUP_REGENERATE=1 to issue new secrets.
set -eu

cd "$(dirname "$0")"

die() { printf 'setup: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------ prerequisites
say "== prerequisites"
if grep -qi microsoft /proc/version 2>/dev/null; then
  say "WSL detected: Docker Desktop needs 'Use the WSL 2 based engine' and WSL integration enabled for this distro."
fi
have docker || die "Docker is not installed. Install Docker Engine (Linux) or Docker Desktop with WSL2 (Windows)."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is missing ('docker compose', not 'docker-compose')."
docker info >/dev/null 2>&1 || die "Cannot reach the Docker daemon. Is it running, and is your user in the docker group?"
have curl || die "curl is required."
have jq || die "jq is required (apt install jq / brew install jq)."
case $(uname -m) in
  x86_64|amd64|aarch64|arm64) ;;
  *) die "unsupported architecture $(uname -m) (need amd64 or arm64)" ;;
esac
say "ok"

# --------------------------------------------------------------------- .env
say "== .env"
umask 077
if [ ! -f .env ]; then
  cp .env.example .env
  say "created .env from .env.example"
else
  say ".env already exists, keeping it"
fi
chmod 600 .env

# Replace or append KEY=VALUE (non-secret values only).
set_env() {
  if grep -q "^$1=" .env; then
    tmp=$(mktemp .env.XXXXXX)
    sed "s|^$1=.*|$1=$2|" .env > "$tmp"
    cat "$tmp" > .env
    rm -f "$tmp"
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}

if [ -n "${SECRETS_BACKEND:-}" ]; then
  case $SECRETS_BACKEND in env|bws) set_env SECRETS_BACKEND "$SECRETS_BACKEND" ;; *) die "SECRETS_BACKEND must be env or bws" ;; esac
fi
BACKEND=$(sed -n 's/^SECRETS_BACKEND=//p' .env | tail -n 1)
BACKEND=${BACKEND:-env}
say "secrets backend: $BACKEND"

# ------------------------------------------------------------------ secrets
say "== API password and JWT secret"
rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

PW_KEY=FREQTRADE__API_SERVER__PASSWORD
JWT_KEY=FREQTRADE__API_SERVER__JWT_SECRET_KEY
mkdir -p .bot
started=1

if [ "$BACKEND" = env ]; then
  if grep -q "^$PW_KEY=" .env && grep -q "^$JWT_KEY=" .env && [ "${SETUP_REGENERATE:-0}" != 1 ]; then
    say "already present in .env, not regenerating"
  else
    pw=$(rand_hex 24)
    jwt=$(rand_hex 32)
    set_env "$PW_KEY" "$pw"
    set_env "$JWT_KEY" "$jwt"
    chmod 600 .env
    say "generated and written to .env (mode 600)"
  fi
else
  if [ -f .bot/secrets-issued ] && [ "${SETUP_REGENERATE:-0}" != 1 ]; then
    say "secrets were already issued on this machine; not printing again (SETUP_REGENERATE=1 issues new ones)"
  else
    [ -t 1 ] || die "bws mode prints the secrets once, so it needs an interactive terminal (run ./setup.sh from a shell, not a pipe or cloud-init)"
    pw=$(rand_hex 24)
    jwt=$(rand_hex 32)
    say ""
    say "Save these two values in Bitwarden Secrets Manager now. They are shown once and not stored anywhere else."
    say ""
    say "  $PW_KEY=$pw"
    say "  $JWT_KEY=$jwt"
    say ""
    say "Also add HC_PING_URL (healthchecks.io) and REPORTS_GH_TOKEN there when you have them."
    if [ -t 0 ]; then
      printf 'Press Enter once they are saved... '
      read -r _ || true
      # Clear the screen so the values do not linger in scrollback.
      printf '\033[2J\033[H'
    fi
    unset pw jwt
    : > .bot/secrets-issued
  fi
  if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
    say ""
    say "BWS_ACCESS_TOKEN is not set in this shell. Export it (and make sure the bws project holds the values above), then run ./bot up."
    started=0
  fi
fi

# -------------------------------------------------------------------- start
if [ "$started" -eq 1 ]; then
  say "== starting the bot (dry-run)"
  ./bot up
  i=0
  until curl -fsS -m 3 -o /dev/null http://127.0.0.1:8080/api/v1/ping 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -le 40 ] || { say "API did not answer within ~2 minutes; check ./bot logs"; break; }
    sleep 3
  done
  ./bot status || true
fi

# --------------------------------------------------------------------- data
case ${SETUP_DATA:-live} in
  skip) ;;
  fixture)
    say "== fixture data"
    if [ -d tests/data ]; then
      mkdir -p user_data/data
      cp -R tests/data/. user_data/data/
      say "copied tests/data into user_data/data"
    else
      say "tests/data not present in this checkout; skipped"
    fi
    ;;
  live)
    if [ "$started" -eq 1 ]; then
      say "== market data (${SETUP_DATA_DAYS:-14} days; on Kraken the first download works from trades and can take a while)"
      ./bot data "${SETUP_DATA_DAYS:-14}" || say "data download failed; the bot runs without it, ./bot nightly retries"
    fi
    ;;
  *) die "SETUP_DATA must be live, fixture or skip" ;;
esac

say ""
say "Done. The bot runs in dry-run mode. Next: ./bot doctor"
