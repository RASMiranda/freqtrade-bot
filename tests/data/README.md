# Test fixture candles (SYNTHETIC)

These candles are **synthetic, not real market data**. They come from a seeded random
walk with sine cycles, written by `generate_fixture.py` (standard library only, byte-identical
on every run). They exist so CI and `./bot test` run without network access.

- Pairs: BTC/USDT, ETH/USDT, SOL/USDT (`<PAIR>-30m.json`, Freqtrade `json` data format)
- Span: 30 days of 30m candles from 2026-01-01T00:00:00Z (1440 per pair)
- `config.fixture.json`: layered over `user_data/config.json` for fixture runs

Results on this data say nothing about strategy quality. `evals/thresholds.json` only checks
that the backtest plumbing works. Real downloaded data replaces this fixture later.

Regenerate: `python3 tests/data/generate_fixture.py`
