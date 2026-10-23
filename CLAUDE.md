# freqtrade-bot
Freqtrade (Docker) crypto bot: dry-run by default, config via .env, shareable template.

## Commands
- ./bot up | down | logs | status | update | nightly | doctor | rollback
- ./bot data [days] | run <command...>   # helpers: download history; run a command under the secrets backend (cron)
- ./bot test        # ruff + pytest + fixture backtest eval + dry_run check
- ./bot backtest <Strategy> [timerange]

## Layout
- user_data/config.json   committed, dry_run true, no secrets
- user_data/strategies/   strategies (HopperBaseline = baseline)
- .env                    never committed, never read or printed: non-secret FREQTRADE__* overrides, plus (only with SECRETS_BACKEND=env) the generated API password and JWT secret at mode 600; with bws all secrets live in Bitwarden
- tests/data/             fixture candles for CI; evals/thresholds.json
- docs/changes/<issue>-<slug>/{intent,spec,plan}.md   one folder per issue
- scripts/, infra/, bands.yaml, REVIEW.md

## Invariants
- No LLM or Claude call anywhere in the trading path
- dry_run stays true in git; live mode is set only in .env on the VM, by a human
- Every strategy has a stoploss and protections (MaxDrawdown, StoplossGuard, CooldownPeriod)
- Backtests use real exchange fees and report Market change (buy-and-hold)
- Never read or print .env, keys or tokens, and never run bws; the API binds to 127.0.0.1 only

## Workflow
- Nothing is built without an approved plan.md (plan mode first)
- Branch claude/<slug>, CI green, squash-merge; footers from the session reminder
- Agents in .claude/agents run only at their stage; verbose output stays in verifier

## Known mistakes
- Binance blocks some server countries (incl. US): CI uses fixture data only
- Kraken's API returns only 720 candles: download history with --dl-trades
- The Freqtrade image is pinned to a release tag; Dependabot bumps it, never switch to :stable
