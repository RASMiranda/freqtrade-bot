#!/bin/bash
# Oracle Cloud Always Free (Ubuntu, arm64) first-boot script. Paste it as the
# instance's cloud-init user data, or run it once as root.
#
# Installs Docker and Tailscale, clones the repo, installs cron for heartbeat /
# nightly / report, and sets ufw to deny all inbound except SSH.
# The bot API stays on 127.0.0.1; remote access is `tailscale serve`.
#
# Optional environment:
#   REPO_URL       repo to clone (default: the upstream repo; use your fork)
#   BOT_USER       Linux user that runs the bot (default: ubuntu)
#   TS_AUTHKEY     Tailscale auth key. Passed in the environment, never committed.
#                  Without it, run `sudo tailscale up` and `tailscale serve --bg 8080` by hand.
#   SECRETS_BACKEND  env (default) or bws. env: this script runs setup.sh. bws: it does not,
#                  because setup.sh prints the generated secrets once and needs a terminal;
#                  SSH in and run ./setup.sh yourself.
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/RASMiranda/freqtrade-bot.git}
BOT_USER=${BOT_USER:-ubuntu}
SECRETS_BACKEND=${SECRETS_BACKEND:-env}
case $SECRETS_BACKEND in env|bws) ;; *) echo "SECRETS_BACKEND must be env or bws" >&2; exit 1 ;; esac
APP_DIR=/home/$BOT_USER/freqtrade-bot
CRON_ENV=/etc/freqtrade-bot/cron.env

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
id "$BOT_USER" >/dev/null 2>&1 || { echo "user $BOT_USER does not exist" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

echo "== packages"
apt-get update -y
apt-get install -y ca-certificates curl git jq cron ufw docker.io docker-compose-v2
systemctl enable --now docker cron
usermod -aG docker "$BOT_USER"

echo "== tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled

echo "== firewall"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
# Tailscale traffic arrives on tailscale0; this is what lets `tailscale serve`
# reach the tailnet. The API itself is still bound to 127.0.0.1 and needs its login.
ufw allow in on tailscale0
ufw --force enable

echo "== repo"
if [ ! -d "$APP_DIR/.git" ]; then
  sudo -u "$BOT_USER" -H git clone "$REPO_URL" "$APP_DIR"
fi

echo "== setup"
if [ "$SECRETS_BACKEND" = env ]; then
  sudo -u "$BOT_USER" -H sh -c "cd '$APP_DIR' && SETUP_DATA=skip ./setup.sh"
else
  echo "SECRETS_BACKEND=bws: setup.sh not run (it needs a terminal to show the secrets once)."
  echo "SSH in and run ./setup.sh:  cd $APP_DIR && SECRETS_BACKEND=bws ./setup.sh"
fi

echo "== cron"
# Secrets for cron jobs (BWS_ACCESS_TOKEN, HC_PING_URL, REPORTS_GH_TOKEN) go in
# this file, owned by the bot user, mode 600. It is never in the repo.
mkdir -p "$(dirname "$CRON_ENV")"
if [ ! -f "$CRON_ENV" ]; then
  cat > "$CRON_ENV" <<'EOF'
# Sourced by the cron jobs. Add lines like:
# export HC_PING_URL=https://hc-ping.com/<uuid>
# export REPORTS_GH_TOKEN=<fine-grained token, contents:write on freqtrade-bot-data only>
# export BWS_ACCESS_TOKEN=<only with SECRETS_BACKEND=bws>
EOF
fi
chown "$BOT_USER":"$BOT_USER" "$CRON_ENV"
chmod 600 "$CRON_ENV"

LOG_DIR=/home/$BOT_USER/freqtrade-bot-logs
sudo -u "$BOT_USER" mkdir -p "$LOG_DIR"
{
  echo "SHELL=/bin/sh"
  echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  echo "*/5 * * * * . $CRON_ENV; cd $APP_DIR && ./bot run scripts/heartbeat.sh >> $LOG_DIR/heartbeat.log 2>&1"
  echo "0 1 * * * . $CRON_ENV; cd $APP_DIR && ./bot nightly >> $LOG_DIR/nightly.log 2>&1"
  echo "55 23 * * * . $CRON_ENV; cd $APP_DIR && ./bot run scripts/export-report.sh >> $LOG_DIR/report.log 2>&1"
} | crontab -u "$BOT_USER" -

echo "== tailscale up"
if [ -n "${TS_AUTHKEY:-}" ]; then
  tailscale up --authkey "$TS_AUTHKEY"
  tailscale serve --bg 8080
  echo "API published to your tailnet: see 'tailscale serve status'."
else
  echo "TS_AUTHKEY not given. Run: sudo tailscale up && tailscale serve --bg 8080"
fi

echo "== done"
echo "Next: edit $CRON_ENV (HC_PING_URL, REPORTS_GH_TOKEN), then as $BOT_USER run ./bot doctor in $APP_DIR."
