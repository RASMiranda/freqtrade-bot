"""HopperBaseline: MAMA/FAMA cross confirmed by Parabolic SAR, 30m, spot long only."""

import talib
from freqtrade.strategy import IStrategy
from pandas import DataFrame


class HopperBaseline(IStrategy):
    INTERFACE_VERSION = 3

    timeframe = "30m"
    can_short = False
    startup_candle_count = 100

    minimal_roi = {"0": 0.06, "360": 0.03, "1440": 0.01}  # noqa: RUF012
    stoploss = -0.08
    trailing_stop = False

    use_exit_signal = True
    exit_profit_only = False
    process_only_new_candles = True

    @property
    def protections(self):
        return [
            {"method": "CooldownPeriod", "stop_duration_candles": 4},
            {
                "method": "MaxDrawdown",
                "lookback_period_candles": 96,
                "trade_limit": 10,
                "stop_duration_candles": 24,
                "max_allowed_drawdown": 0.10,
            },
            {
                "method": "StoplossGuard",
                "lookback_period_candles": 48,
                "trade_limit": 3,
                "stop_duration_candles": 24,
                "only_per_pair": False,
            },
        ]

    def populate_indicators(self, dataframe: DataFrame, metadata: dict) -> DataFrame:
        mama, fama = talib.MAMA(dataframe["close"])
        dataframe["mama"] = mama
        dataframe["fama"] = fama
        dataframe["sar"] = talib.SAR(dataframe["high"], dataframe["low"])
        return dataframe

    def populate_entry_trend(self, dataframe: DataFrame, metadata: dict) -> DataFrame:
        crossed_up = (dataframe["mama"] > dataframe["fama"]) & (
            dataframe["mama"].shift(1) <= dataframe["fama"].shift(1)
        )
        dataframe.loc[
            crossed_up & (dataframe["sar"] < dataframe["close"]) & (dataframe["volume"] > 0),
            "enter_long",
        ] = 1
        return dataframe

    def populate_exit_trend(self, dataframe: DataFrame, metadata: dict) -> DataFrame:
        crossed_down = (dataframe["mama"] < dataframe["fama"]) & (
            dataframe["mama"].shift(1) >= dataframe["fama"].shift(1)
        )
        dataframe.loc[
            (crossed_down | (dataframe["sar"] > dataframe["close"])) & (dataframe["volume"] > 0),
            "exit_long",
        ] = 1
        return dataframe
