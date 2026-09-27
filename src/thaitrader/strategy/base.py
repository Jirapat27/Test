from __future__ import annotations

from abc import ABC, abstractmethod

from ..models import Candle


class Strategy(ABC):
    """A strategy maps recent candles to a *target* position in shares.

    Returning a target (rather than buy/sell signals) makes the engine
    idempotent: after a restart or a missed fill it simply trades the
    difference between target and actual position.
    """

    #: minimum number of candles needed before the strategy can decide
    warmup: int = 1

    @abstractmethod
    def target_position(self, symbol: str, candles: list[Candle], current_qty: int) -> int | None:
        """Desired share count (>= 0 for a cash account), or None for 'no opinion'."""
