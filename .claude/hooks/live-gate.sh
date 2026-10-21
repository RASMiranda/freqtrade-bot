#!/bin/sh
# Blocks any Claude action that would switch the bot to live trading.
if grep -Eiq 'dry_run[^a-z0-9]{0,6}false'; then
  echo "Live trading is a human-only gate (see CLAUDE.md). Stop and ask the user." >&2
  exit 2
fi
exit 0
