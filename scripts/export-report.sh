#!/bin/sh
# Daily report. Reads the bot API (/status, /profit, /trades), writes
# reports/YYYY-MM-DD.json and reports/latest.md (profit next to Market change),
# then commits and pushes them to the private freqtrade-bot-data repo and
# nowhere else. reports/ is gitignored here.
#
# The push token (REPORTS_GH_TOKEN, fine-grained, contents:write on
# freqtrade-bot-data only) comes from the environment and reaches git through a
# credential helper, so it is never in the remote URL, argv or a file.
# Needs: curl, jq, git.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# Same rule as heartbeat.sh: .env only if present, the environment wins.
saved=$(env | sed -n '/^\(API_URL\|FREQTRADE__API_SERVER__USERNAME\|FREQTRADE__API_SERVER__PASSWORD\|REPORTS_GH_TOKEN\|REPORTS_REPO_URL\|REPORTS_BRANCH\)=/p')
if [ -r .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi
# Restore anything the environment already had (values are re-read from the
# saved lines; none of them is printed).
OLDIFS=$IFS
IFS='
'
for line in $saved; do
  export "${line%%=*}=${line#*=}"
done
IFS=$OLDIFS

API_URL=${API_URL:-http://127.0.0.1:8080}
API_USER=${FREQTRADE__API_SERVER__USERNAME:-freqtrader}
API_PASS=${FREQTRADE__API_SERVER__PASSWORD:-}
REPO_URL=${REPORTS_REPO_URL:-https://github.com/RASMiranda/freqtrade-bot-data.git}
BRANCH=${REPORTS_BRANCH:-main}
DATA_DIR=.bot/data-repo

die() { printf 'export-report: %s\n' "$*" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git >/dev/null 2>&1 || die "git is required"
[ -n "$API_PASS" ] || die "FREQTRADE__API_SERVER__PASSWORD is not set (run via ./bot run under bws)"

# Credentials go to curl through -K on stdin, not argv.
TOKEN=$(printf 'user = "%s:%s"\n' "$API_USER" "$API_PASS" |
  curl -fsS -m 20 -K - -X POST "$API_URL/api/v1/token/login" | jq -r '.access_token // empty')
[ -n "$TOKEN" ] || die "API login failed"

api() {
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -fsS -m 60 -K - "$API_URL/api/v1$1"
}

DATE=$(date -u +%Y-%m-%d)
NOW_MS=$(( $(date -u +%s) * 1000 ))

status=$(api /status)
profit=$(api /profit)
trades=$(api '/trades?limit=500')
conf=$(api /show_config)
timeframe=$(printf '%s' "$conf" | jq -r '.timeframe // "30m"')
stake=$(printf '%s' "$conf" | jq -r '.stake_currency // ""')
first_ms=$(printf '%s' "$profit" | jq -r '.first_trade_timestamp // 0')

# Market change (buy and hold): mean close-to-close change over the whitelist,
# since the first trade and over the last 24h. null when there is no data.
pair_changes='[]'
for pair in $(api /whitelist | jq -r '.whitelist[]'); do
  enc=$(printf '%s' "$pair" | sed 's|/|%2F|g')
  candles=$(api "/pair_candles?pair=$enc&timeframe=$timeframe&limit=1500") || continue
  row=$(printf '%s' "$candles" | jq -c --arg pair "$pair" --argjson first "$first_ms" --argjson day "$((NOW_MS - 86400000))" '
    def change($since):
      (.columns | index("date")) as $d | (.columns | index("close")) as $c |
      [.data[] | select((.[$d] | type) == "number" and .[$d] >= $since)] as $r |
      if ($r | length) < 2 then null else (($r[-1][$c] / $r[0][$c]) - 1) * 100 end;
    {pair: $pair, since_first_trade: (if $first > 0 then change($first) else null end), last_24h: change($day)}')
  pair_changes=$(printf '%s' "$pair_changes" | jq -c --argjson r "$row" '. + [$r]')
done
market=$(printf '%s' "$pair_changes" | jq -c '
  def avg(k): [.[] | .[k] | select(. != null)] | if length == 0 then null else add / length end;
  {since_first_trade_pct: avg("since_first_trade"), last_24h_pct: avg("last_24h"), pairs: .}')

mkdir -p reports
jq -n --arg date "$DATE" --arg stake "$stake" --argjson status "$status" --argjson profit "$profit" \
  --argjson trades "$trades" --argjson market "$market" \
  '{date: $date, stake_currency: $stake, status: $status, profit: $profit, trades: $trades, market_change: $market}' \
  > "reports/$DATE.json"

jq -r '
  def f: if . == null then "n/a" else (. * 100 | round / 100 | tostring) end;
  "# Daily report \(.date)\n",
  "| Metric | Value |",
  "| --- | --- |",
  "| Open trades | \(.status | length) |",
  "| Closed trades | \(.profit.closed_trade_count // "n/a") |",
  "| Winning / losing | \(.profit.winning_trades // "n/a") / \(.profit.losing_trades // "n/a") |",
  "| Profit, all (\(.stake_currency)) | \(.profit.profit_all_coin | f) |",
  "| Profit, all (%) | \(.profit.profit_all_percent | f) |",
  "| Profit, closed (\(.stake_currency)) | \(.profit.profit_closed_coin | f) |",
  "| Max drawdown | \(.profit.max_drawdown | f) |",
  "| Market change since first trade (%) | \(.market_change.since_first_trade_pct | f) |",
  "| Market change last 24h (%) | \(.market_change.last_24h_pct | f) |",
  "",
  "Market change is buy-and-hold over the whitelist on the bot timeframe. Profit is dry-run."
' "reports/$DATE.json" > reports/latest.md
printf 'export-report: wrote reports/%s.json and reports/latest.md\n' "$DATE"

# Publish to freqtrade-bot-data only.
export GIT_TERMINAL_PROMPT=0
case $REPO_URL in
  https://*) [ -n "${REPORTS_GH_TOKEN:-}" ] || die "REPORTS_GH_TOKEN is not set; report kept locally, not pushed" ;;
esac
export REPORTS_GH_TOKEN
# shellcheck disable=SC2016  # $REPORTS_GH_TOKEN expands inside the helper, not here
helper='!f() { echo username=x-access-token; echo "password=$REPORTS_GH_TOKEN"; }; f'
gitc() { git -c credential.helper= -c "credential.helper=$helper" "$@"; }

mkdir -p .bot
if [ ! -d "$DATA_DIR/.git" ]; then
  gitc clone -q "$REPO_URL" "$DATA_DIR"
fi
gitc -C "$DATA_DIR" fetch -q origin
if gitc -C "$DATA_DIR" rev-parse -q --verify "origin/$BRANCH" >/dev/null; then
  gitc -C "$DATA_DIR" checkout -q -B "$BRANCH" "origin/$BRANCH"
else
  gitc -C "$DATA_DIR" checkout -q -B "$BRANCH"
fi

mkdir -p "$DATA_DIR/reports"
cp "reports/$DATE.json" reports/latest.md "$DATA_DIR/reports/"
gitc -C "$DATA_DIR" add reports
if gitc -C "$DATA_DIR" diff --cached --quiet; then
  printf 'export-report: nothing new to push\n'
  exit 0
fi
gitc -C "$DATA_DIR" -c user.name=freqtrade-bot -c user.email=freqtrade-bot@users.noreply.github.com \
  commit -q -m "report $DATE"
gitc -C "$DATA_DIR" push -q origin "HEAD:$BRANCH"
printf 'export-report: pushed report %s\n' "$DATE"
