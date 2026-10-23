"""populate_* on the committed fixture candles. Needs freqtrade and talib (the Freqtrade image has both)."""

import json

import pytest

pd = pytest.importorskip("pandas")
pytest.importorskip("talib")
pytest.importorskip("freqtrade")

from HopperBaseline import HopperBaseline
from pandas.testing import assert_series_equal

PAIRS = ["BTC_USDT", "ETH_USDT", "SOL_USDT"]
INDICATORS = ["mama", "fama", "sar"]
SIGNALS = ["enter_long", "exit_long"]


def load(root, pair):
    rows = json.loads((root / "tests" / "data" / f"{pair}-30m.json").read_text())
    df = pd.DataFrame(rows, columns=["date", "open", "high", "low", "close", "volume"])
    df["date"] = pd.to_datetime(df["date"], unit="ms", utc=True)
    return df


@pytest.fixture(scope="module")
def strategy():
    return HopperBaseline({})


def populate(strategy, df):
    df = strategy.populate_indicators(df.copy(), {"pair": "X/USDT"})
    df = strategy.populate_entry_trend(df, {"pair": "X/USDT"})
    return strategy.populate_exit_trend(df, {"pair": "X/USDT"})


@pytest.mark.parametrize("pair", PAIRS)
def test_populate_adds_columns(strategy, root, pair):
    df = populate(strategy, load(root, pair))
    for col in INDICATORS:
        assert col in df.columns
        assert df[col].notna().sum() > len(df) // 2
    assert len(df) == len(load(root, pair))


def test_fixture_produces_signals(strategy, root):
    entries = sum(populate(strategy, load(root, p)).get("enter_long", pd.Series(dtype=float)).sum() for p in PAIRS)
    assert entries > 0


def test_only_known_columns_added(strategy, root):
    base = load(root, PAIRS[0])
    df = populate(strategy, base)
    assert set(df.columns) - set(base.columns) <= set(INDICATORS + SIGNALS)


@pytest.mark.parametrize("pair", PAIRS)
@pytest.mark.parametrize("cut", [400, 800, 1200])
def test_no_lookahead(strategy, root, pair, cut):
    """Rows computed on truncated data must equal the same rows computed on the full data."""
    full_in = load(root, pair)
    full = populate(strategy, full_in)
    part = populate(strategy, full_in.iloc[:cut])
    for col in INDICATORS + SIGNALS:
        if col not in full.columns:
            continue
        a = full[col].iloc[:cut].reset_index(drop=True).fillna(0)
        b = part[col].reset_index(drop=True).fillna(0) if col in part.columns else a * 0
        assert_series_equal(a, b, check_names=False)


def test_risk_settings(strategy):
    assert strategy.stoploss < 0
    assert strategy.timeframe == "30m"
    assert strategy.can_short is False
    assert strategy.startup_candle_count >= 30
    methods = {p["method"] for p in strategy.protections}
    assert {"MaxDrawdown", "StoplossGuard", "CooldownPeriod"} <= methods
