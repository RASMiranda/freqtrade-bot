# Intent 000: bootstrap freqtrade-bot

## Problem
I want a free, always-on crypto trading bot I can watch from my phone and give
to friends, without writing a trading engine.

## Outcome
Freqtrade runs in dry-run 24/7 on Oracle Cloud Always Free or any PC after one
setup command, restarts itself, emails me when it is down, and writes a daily
report for a weekly review.

## Constraints
- EUR 0 running cost; Claude Pro only for development and one weekly review
- dry-run until a human edits .env on the VM; live settings never committed
- amd64 and arm64; Linux, macOS, Windows (WSL2)

## Deliverables
- docker-compose.yml: official base, image pinned to a release tag, 127.0.0.1:8080, healthcheck on /api/v1/ping, autoheal
- user_data/config.json, .env.example (non-secret FREQTRADE__* variables) and a SECRETS_BACKEND setting in ./bot (bws or env; with bws, docker compose runs through bws run)
- user_data/strategies/HopperBaseline.py: MAMA/FAMA cross + Parabolic SAR, 30m,
  stoploss, protections
- ./bot CLI, setup.sh, scripts/heartbeat.sh, scripts/export-report.sh, bands.yaml
- infra/oracle-cloud-init.sh
- .github/dependabot.yml and an auto-merge workflow for Freqtrade updates
- tests/ with fixture data, evals/thresholds.json, .github/workflows/ci.yml
  (ruff, pytest, fixture backtest, lookahead-analysis, dry_run check)
- .github/workflows/create-release.yml from RASMiranda/motion-blueprint-app (VERSION file)
- .claude/agents: product-owner, scrum-master, tech-lead, verifier,
  quant-reviewer, security-reviewer, support-l2, support-l3
- .claude/settings.json, REVIEW.md, RUNBOOK.md, PR template, Intent and Help issue forms
- ./bot doctor, ./bot rollback, .github/workflows/l1-triage.yml (no AI)
- README: local, Oracle and friend setup; "not financial advice"

## Open questions
- Default exchange for friends outside the EU?
