#!/bin/sh
# Fixture backtest + comparison with evals/thresholds.json. Needs docker and python3.
# Offline data (tests/data); the fee is passed explicitly (Kraken taker rate) so the
# run does not need the exchange's fee lookup. Override with EVAL_FEE.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

STRATEGY=${EVAL_STRATEGY:-HopperBaseline}
FEE=${EVAL_FEE:-0.0026}
IMAGE=${FREQTRADE_IMAGE:-$(sed -n 's/^ *image: *\(freqtradeorg\/freqtrade:[^ ]*\).*/\1/p' docker-compose.yml | head -n 1)}
[ -n "$IMAGE" ] || { echo "evals: cannot read the pinned image from docker-compose.yml" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "evals: docker is required" >&2; exit 1; }

RESULTS=user_data/backtest_results
mkdir -p "$RESULTS"
# The image runs as its own user (ftuser), not as the caller, so it must be able to write here.
chmod a+rwx "$RESULTS"
rm -f "$RESULTS/.last_result.json"

echo "evals: backtesting $STRATEGY on tests/data with $IMAGE (fee $FEE)"
docker run --rm \
  -v "$ROOT:/work" -w /work "$IMAGE" backtesting \
  --userdir /work/user_data --config user_data/config.json --config tests/data/config.fixture.json \
  --datadir tests/data --strategy "$STRATEGY" --fee "$FEE" --export trades

python3 -I - "$RESULTS" "$STRATEGY" evals/thresholds.json <<'PY'
import json
import sys
import zipfile
from pathlib import Path

results, strategy, thresholds = Path(sys.argv[1]), sys.argv[2], json.loads(Path(sys.argv[3]).read_text())
latest = json.loads((results / ".last_result.json").read_text())["latest_backtest"]
path = results / latest
if path.suffix == ".zip":
    with zipfile.ZipFile(path) as z:
        name = next(n for n in z.namelist() if n.endswith(".json") and not n.endswith("_config.json"))
        data = json.loads(z.read(name))
else:
    data = json.loads(path.read_text())
r = data["strategy"][strategy]

trades = r["total_trades"]
dd = r.get("max_drawdown_account", 0.0)
market = r.get("market_change")
profit = r.get("profit_total")
print(f"evals: trades={trades} profit_total={profit} market_change={market} max_drawdown_account={dd}")

failures = []
if trades < thresholds["min_total_trades"]:
    failures.append(f"total_trades {trades} < {thresholds['min_total_trades']}")
if dd > thresholds["max_drawdown_account"]:
    failures.append(f"max_drawdown_account {dd} > {thresholds['max_drawdown_account']}")
if thresholds.get("require_market_change") and market is None:
    failures.append("market_change missing from the result")
if failures:
    print("evals: FAIL: " + "; ".join(failures))
    sys.exit(1)
print("evals: ok")
PY
