from __future__ import annotations

from abc import ABC, abstractmethod

from ..models import Candle, Order, Position


class BrokerError(Exception):
    pass


class Broker(ABC):
    """Everything the engine needs from a broker. Strategies never talk to a
    broker directly, so the same code runs in backtest, paper and live."""

    @abstractmethod
    def get_candles(self, symbol: str, interval: str = "1d", limit: int = 200) -> list[Candle]:
        """Oldest first."""

    @abstractmethod
    def get_last_price(self, symbol: str) -> float: ...

    @abstractmethod
    def get_positions(self) -> dict[str, Position]: ...

    @abstractmethod
    def get_cash(self) -> float:
        """Buying power available for new orders (THB)."""

    @abstractmethod
    def place_order(self, order: Order) -> Order:
        """Submit; returns the same order with broker_order_no/status set.
        Must not raise for business rejections -- set status=REJECTED."""

    @abstractmethod
    def cancel_order(self, order: Order) -> Order: ...

    @abstractmethod
    def refresh_order(self, order: Order) -> Order:
        """Update status / filled_qty from the broker."""
