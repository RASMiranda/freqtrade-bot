"""Write the SYNTHETIC fixture candles: 3 pairs, 30 days of 30m, seeded and deterministic.

Run from the repo root:  python3 tests/data/generate_fixture.py
Standard library only. Output is byte-identical on every run.
"""

import json
import math
import random
from pathlib import Path

OUT = Path(__file__).resolve().parent
START_MS = 1767225600000  # 2026-01-01T00:00:00Z
STEP_MS = 30 * 60 * 1000
CANDLES = 30 * 48
PAIRS = {  # pair file stem: (seed, start price, cycle length in candles, cycle amplitude)
    "BTC_USDT": (11, 40000.0, 150, 0.05),
    "ETH_USDT": (23, 2500.0, 110, 0.06),
    "SOL_USDT": (37, 100.0, 90, 0.08),
}


def series(seed, price, period, amp):
    rng = random.Random(seed)
    rows = []
    drift = 0.0
    for i in range(CANDLES):
        if i % 240 == 0:
            drift = rng.uniform(-0.0004, 0.0004)
        target = price * math.exp(amp * math.sin(2 * math.pi * i / period))
        close = target * math.exp(rng.gauss(0, 0.004)) * math.exp(drift * i)
        rows.append(close)
    out = []
    prev = rows[0]
    for i, close in enumerate(rows):
        open_ = prev
        wick = abs(rng.gauss(0, 0.003))
        high = max(open_, close) * (1 + wick)
        low = min(open_, close) * (1 - wick)
        volume = rng.uniform(50, 500)
        out.append([START_MS + i * STEP_MS, round(open_, 4), round(high, 4), round(low, 4), round(close, 4), round(volume, 4)])
        prev = close
    return out


def main():
    for stem, params in PAIRS.items():
        (OUT / f"{stem}-30m.json").write_text(json.dumps(series(*params), separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
