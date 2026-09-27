from __future__ import annotations

from ..market_rules import BOARD_LOT
from ..models import Candle
from .base import Strategy


def sma(values: list[float], n: int) -> float:
    return sum(values[-n:]) / n


class SmaCross(Strategy):
    """Long `lots` board lots while the fast SMA is above the slow SMA, flat otherwise.

    An example to show the plumbing, not a recommendation.
    """

    def __init__(self, fast: int = 10, slow: int = 30, lots: int = 1):
        if fast >= slow:
            raise ValueError("fast period must be shorter than slow period")
        self.fast, self.slow, self.lots = fast, slow, lots
        self.warmup = slow

    def target_position(self, symbol: str, candles: list[Candle], current_qty: int) -> int | None:
        if len(candles) < self.slow:
            return None
        closes = [c.close for c in candles]
        return self.lots * BOARD_LOT if sma(closes, self.fast) > sma(closes, self.slow) else 0
