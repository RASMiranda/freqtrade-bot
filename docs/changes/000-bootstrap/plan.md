# Plan 000: bootstrap freqtrade-bot

## Context
`freqtrade-bot` holds only LICENSE and README.md. The intent (docs/changes/000-bootstrap/intent.md) wants a free, always-on Freqtrade dry-run bot that restarts itself, emails when down, writes a daily report, and can be handed to friends after one setup command. This plan covers every item in the intent's Deliverables list, in build order, under the CLAUDE.md invariants: no LLM in the trading path, dry_run true in git, stoploss and protections on every strategy, real fees, API on 127.0.0.1, image pinned to a tag, never read .env or run bws.

**Step 0 (prerequisite).** CLAUDE.md and the intent were added in 3fdca04 and reverted in b772abe (PR #2), so they are not on main or on this branch. Implementation restores only those two files with `git checkout 3fdca04 -- CLAUDE.md docs/changes/000-bootstrap/intent.md`. The revert of the other starter files (verifier agent, settings.json, live-gate.sh) was deliberate, so they are not restored. They are built fresh, as described below (settings.json deny rules in PR 1, the rest in PR 5).

**Caveat (from PR 5 on).** The live-gate hook, once built, blocks any Edit, Write or Bash whose text matches `dry_run` followed by `false`. The CI dry_run check and docs must be written to avoid that literal pattern, for example `jq -e '.dry_run == true'`.

## Deliverables

### 1. Runtime core
- **docker-compose.yml**: `freqtradeorg/freqtrade:<release-tag>` (latest stable tag looked up at build time, never `:stable`), ports `127.0.0.1:8080:8080`, `restart: unless-stopped`, healthcheck on `/api/v1/ping`, an `autoheal` sidecar (`willfarrell/autoheal`, pinned) with the label on the bot. Mounts `./user_data`. Env comes from `.env`.
- **user_data/config.json**: committed, dry_run true, no secrets, `dry_run_wallet`, stake in EUR/USDT, `api_server` listening on 0.0.0.0 inside the container (host binding is the 127.0.0.1 mapping), pairlist StaticPairList with a few majors, real fee handling (no fee override).
- **.env.example**: non-secret `FREQTRADE__*` overrides only (exchange name, stake, API username), comments pointing to Bitwarden for secrets, and `SECRETS_BACKEND=env|bws`. `.gitignore` excludes `.env`, `reports/`, `user_data/{data,backtest_results,logs}`, `*.sqlite`.
- **SECRETS_BACKEND in ./bot**: `env` runs `docker compose` directly. `bws` runs `bws run -- docker compose …`. Only the script calls bws; Claude never does.

### 2. Strategy
- **user_data/strategies/HopperBaseline.py**: 30m, `talib.MAMA` with MAMA/FAMA cross for entry/exit and Parabolic SAR as confirmation. Shift-safe indicators only, with no future data. Fixed `stoploss`, `minimal_roi`, and a `protections` property with MaxDrawdown, StoplossGuard and CooldownPeriod. `startup_candle_count` set.

### 3. CLI and ops scripts
- **./bot** (POSIX sh): `up | down | logs | status | update | nightly | doctor | rollback | test | backtest <Strategy> [timerange]`.
  - `test` runs ruff, pytest, a fixture backtest with threshold eval, and the dry_run check.
  - `update` does the pull: fetches the pinned image, records the previous tag, and recreates.
  - `nightly` refreshes market data, then runs a walk-forward backtest for about 2 hours (a `timeout`-bounded loop over rolling windows). It keeps the Oracle VM busy and does no pulling. It must **resume, not restart**: it keeps a state file under `user_data/` (completed windows and download progress), skips finished work on the next run, and relies on Freqtrade's incremental data download. **Risk:** the first Kraken `--dl-trades` history download can exceed the 2-hour window, so the first nights may only download. The loop stops at the time limit, saves progress, and continues next night. The walk-forward phase starts only once the data is complete.
  - `doctor` checks docker, compose, arch, `.env` present (existence only, never content), API bound to loopback, healthcheck state, dry_run true in config, and disk.
  - `rollback` restores the previous image tag, which `update` records in `.bot/last-tag`.
- **setup.sh**: one command that checks prerequisites (Docker, compose v2, WSL2 hint), creates `.env` from the example, downloads fixture or live data, and starts the bot. amd64 and arm64 safe.
- **scripts/heartbeat.sh**: cron-driven. Checks `/api/v1/ping`, then curls `$HC_PING_URL` on success and `$HC_PING_URL/fail` on failure. healthchecks.io sends the emails, so there is no SMTP and no mail code. It must tolerate a missing `.env` (it sources the file only if it exists, and otherwise relies on the environment) and work under `bws run` (variables arrive via the environment). With `HC_PING_URL` unset it logs and exits 0.
- **scripts/export-report.sh**: daily. Reads the API `/status`, `/profit` and `/trades`, and writes `reports/YYYY-MM-DD.json` and `reports/latest.md` (profit against Market change included). It then commits and pushes them to **freqtrade-bot-data** (private) and nowhere else. `reports/` is gitignored in this repo, so reports never land in freqtrade-bot. The push uses a fine-grained GitHub token limited to that one repo (contents write), read from the environment (for example `REPORTS_GH_TOKEN`) and supplied to git through a credential helper, never stored in the remote URL or in committed files.
- **bands.yaml**: sigma alert thresholds. 1σ is logged, 2σ goes to Telegram, 3σ pauses entries through the API's stop-entry endpoint (`/stopentry`; the name is confirmed against the pinned Freqtrade release before use, and the test asserts it). It lists the metrics the thresholds apply to (daily profit, drawdown, trade rate). The weekly review and quant-reviewer compare changes against it. The 3σ action only stops new entries, and it never touches dry_run or open trades.

### 4. Infra
- **infra/oracle-cloud-init.sh**: Ubuntu arm64 Always Free. Installs Docker and Tailscale, clones the repo, runs `setup.sh`, installs cron for heartbeat, nightly and report, and sets ufw to deny all inbound except SSH. Remote access is Tailscale: after `tailscale up`, `tailscale serve --bg 8080` publishes the loopback-only API to the tailnet, with no public port and no SSH tunnel. The auth key, if used, is passed in the environment and never committed. `./bot doctor` checks that Tailscale is up and that the API is still bound to 127.0.0.1 only.

### 5. Dependency automation
- **.github/dependabot.yml**: ecosystems `docker-compose` (the Freqtrade image), `github-actions`, `pip` (dev requirements), weekly.
- **.github/workflows/dependabot-automerge.yml**: on Dependabot PRs for the Freqtrade image only, then `gh pr merge --auto --squash` once CI passes. Policy depends on a repo Actions variable `BOT_LIVE` that a human sets (unset means dry-run):
  - dry-run on (`BOT_LIVE` unset): auto-merge **all** Freqtrade releases;
  - live (`BOT_LIVE=1`): auto-merge **patch only**, and leave everything else for review.
  - Freqtrade uses calendar versions (`YYYY.M`, `YYYY.M.N`), which do not map cleanly to semver, so Dependabot's `update-type` can mislabel them. The workflow therefore classifies by comparing the old and new tags itself: same `YYYY.M` with a higher `N` is a patch, and anything else is not. A unit test covers the classifier.

### 6. Tests and CI
- **tests/**: `tests/data/` fixture candles (committed, small, 30m, the strategy's pairs), `tests/test_config.py` (dry_run true, no secrets, API loopback mapping in compose, stoploss and protections present, image tag pinned and not `stable`), `tests/test_strategy.py` (populate_* on fixture data, no lookahead columns).
- **evals/thresholds.json**: minimum trades, max drawdown, and a "must not trail Market change by more than X" bound. `./bot test` compares the fixture backtest result against it.
- **.github/workflows/ci.yml**: ruff, pytest, fixture backtest (`--userdir` with fixture data, no network exchange calls), `lookahead-analysis`, and a dry_run check (`jq -e '.dry_run == true'`). Runs on PR and main.

### 7. Release workflow (reused from RASMiranda/motion-blueprint-app)
- **.github/workflows/create-release.yml**: copied from motion-blueprint-app (`workflow_dispatch`, concurrency group, tag validation `^v\d+\.\d+\.\d+$`, refuses existing tag or release, notes from the matching CHANGELOG.md section with fallback to generated notes, `gh release create --target main`). Only change is the version source:
  - replace `node -p "require('./package.json').version"` with `tr -d '[:space:]' < VERSION`, after checking that `VERSION` exists and matches `^[0-9]+\.[0-9]+\.[0-9]+$`;
  - update the header comment and the `tag` input description to say VERSION file instead of package.json.
- **VERSION** file containing `0.1.0`. No Node step is needed, and the rest of the workflow is unchanged.

### 8. Claude agents and settings
- **.claude/agents/**: product-owner, scrum-master, tech-lead, quant-reviewer, security-reviewer, support-l2, support-l3, plus the verifier, which is built fresh in PR 5 (not restored from 3fdca04). Each is one short file with name, description saying when it runs, a minimal tool list, and a cheap model where the job allows. The quant-reviewer checks stoploss, protections, fees, lookahead and bands.yaml. The security-reviewer checks secrets, port binding and the invariants. support-l2 reads the diagnostics from `./bot doctor` and logs. support-l3 may propose fixes via a plan.
- **.claude/settings.json**: added in **PR 1** with the deny rules only (`Read(./.env)`, `Bash(bws:*)`, `Read(./user_data/data/**)`, `Read(./user_data/backtest_results/**)`, `Read(./user_data/logs/**)`, `Read(./**/*.sqlite)`), and no hook yet.
- **PR 5** adds, built fresh and not restored from 3fdca04, the **verifier agent** (`.claude/agents/verifier.md`), **`.claude/hooks/live-gate.sh`**, and the PreToolUse hook entry in settings.json. The verifier and hook are written against the final `./bot` and test layout. The hook is tested with a case that blocks the live setting and a case that allows ordinary edits.
- **REVIEW.md**: review checklist built from the CLAUDE.md invariants.
- **RUNBOOK.md**: start, stop, alerts, update, rollback, backups, Oracle reclaim risk, Tailscale access, and how a human goes live. The live section is written in words and never spells out the literal dry_run/false pattern, so the live-gate hook is not tripped. It says to set the config's dry-run switch to its opposite through a `FREQTRADE__` override in `.env` on the VM, by a human, then set `BOT_LIVE=1` in repo variables and run `./bot up`. Going live is never committed.
- **.github/pull_request_template.md**, **.github/ISSUE_TEMPLATE/intent.yml**, **.github/ISSUE_TEMPLATE/help.yml** (the Help form takes `./bot doctor` output, with a warning not to paste .env or keys).

### 9. Diagnostics and triage
- `./bot doctor` and `./bot rollback` are in section 3.
- **.github/workflows/l1-triage.yml**: no AI. On issue open it checks the form fields, adds labels (`intent`, `help`, `needs-info`) from the form type and keywords, and replies with a fixed checklist (run `./bot doctor`, paste the output, link RUNBOOK).

### 10. README
Sections for local setup, Oracle Cloud setup and friend setup (fork, `./setup.sh`, dry-run only), a command table, a "not financial advice, dry-run by default" disclaimer, and the exchange note below.

## Decision
**Default exchange: Kraken**, confirmed. It is a single `FREQTRADE__EXCHANGE__NAME` in `.env.example`. Binance is documented as an option but is blocked in some countries, including the US. Kraken only returns 720 candles, so the setup script and `./bot nightly` download history with `--dl-trades`. CI is unaffected because it uses fixtures only.

## Build order and PRs
Squash-merged PRs on `claude/<slug>` branches, each with green CI: (1) Step 0, runtime core, strategy, and `.claude/settings.json` with deny rules only; (2) CLI, scripts, infra; (3) tests, evals, CI; (4) dependabot, auto-merge and release workflow with VERSION; (5) agents including the new verifier, live-gate.sh and its hook entry, docs, templates, triage. Nothing is built until this plan is approved.

## Verification

### In this session (no Docker daemon, no exchange, no secrets)
- `./bot test` pieces that run offline: ruff, pytest (config, strategy and classifier tests), fixture backtest against thresholds, lookahead-analysis, and the dry_run check, if Freqtrade installs here. Otherwise they run in CI on the PR.
- `docker compose config` validates, if docker is available. Otherwise a pytest parses the YAML, asserting the `127.0.0.1:8080` mapping and a pinned tag that is not `stable`.
- `shellcheck` on ./bot, setup.sh, scripts/*, infra/*. `actionlint` on all workflows.
- heartbeat.sh with a stub HTTP server: pings on success and `/fail` on failure, runs with no `.env`, and runs under a fake `bws run` wrapper.
- export-report.sh against a stub API, pushing to a local bare repo that stands in for freqtrade-bot-data. It writes `YYYY-MM-DD.json` and `latest.md`, and `git status` in this repo shows nothing under `reports/`.
- The release workflow logic with the shell steps run locally against `VERSION`: valid gives `v0.1.0`, malformed or missing fails, an existing tag fails.
- The auto-merge classifier on sample tags, such as `2026.9` to `2026.9.1` (patch), `2026.9.1` to `2026.10` (not patch), and both modes of `BOT_LIVE`.
- The live-gate hook blocks an attempt to set the live value.
- CI is green on each PR.

### Run by me on my PC or VM
- `./setup.sh` and `./bot up` on a PC and on the Oracle VM (arm64), then `./bot status` and `./bot doctor`.
- Kill the container and confirm autoheal or the restart policy brings it back. Create the healthchecks.io check, set `HC_PING_URL`, stop the bot and confirm the failure email arrives.
- `./bot nightly` really runs for about 2 hours and the walk-forward result is sane. Interrupt it mid-run and confirm the next run resumes, and watch the first Kraken `--dl-trades` download span several nights without restarting.
- `tailscale up` and `tailscale serve --bg 8080`: the API opens from my phone on the tailnet and is unreachable from the public IP.
- A real push of the report to freqtrade-bot-data using the fine-grained token limited to that repo (check it cannot push anywhere else), and a Telegram test message at 2σ.
- The release workflow from the Actions tab with `VERSION` = 0.1.0 produces release `v0.1.0`, and a second run fails with "Tag already exists".
- A Dependabot Freqtrade PR auto-merges once CI is green with `BOT_LIVE` unset.

## On approval
Save this plan to `docs/changes/000-bootstrap/plan.md` (after Step 0 restores the docs folder) in the first PR, then start building in the order above.
