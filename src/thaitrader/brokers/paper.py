from __future__ import annotations

import itertools

from ..fees import FeeSchedule
from ..models import Candle, Order, OrderStatus, Position, PriceType, Side
from .base import Broker


class PaperBroker(Broker):
    """In-memory broker with simulated fills.

    Market data comes from `data_source` (e.g. a SettradeBroker, for dry runs
    on real prices) or from prices you push with `set_price` (tests).
    A limit order fills in full at its limit price as soon as the last price
    crosses it. No partial fills, queue position or slippage -- optimistic.
    """

    def __init__(
        self,
        cash: float = 1_000_000.0,
        fees: FeeSchedule | None = None,
        data_source: Broker | None = None,
    ):
        self.cash = cash
        self.fees = fees or FeeSchedule()
        self.data_source = data_source
        self.positions: dict[str, Position] = {}
        self.orders: dict[str, Order] = {}
        self._prices: dict[str, float] = {}
        self._candles: dict[str, list[Candle]] = {}
        self._seq = itertools.count(1)

    # --- market data -------------------------------------------------------
    def set_price(self, symbol: str, price: float) -> None:
        self._prices[symbol] = price
        self._match(symbol)

    def set_candles(self, symbol: str, candles: list[Candle]) -> None:
        self._candles[symbol] = candles
        if candles:
            self.set_price(symbol, candles[-1].close)

    def get_candles(self, symbol: str, interval: str = "1d", limit: int = 200) -> list[Candle]:
        if self.data_source is not None:
            candles = self.data_source.get_candles(symbol, interval, limit)
            if candles:
                self.set_price(symbol, candles[-1].close)
            return candles
        return self._candles.get(symbol, [])[-limit:]

    def get_last_price(self, symbol: str) -> float:
        if self.data_source is not None:
            self.set_price(symbol, self.data_source.get_last_price(symbol))
        return self._prices[symbol]

    # --- account -----------------------------------------------------------
    def get_positions(self) -> dict[str, Position]:
        return {s: Position(p.symbol, p.qty, p.avg_price) for s, p in self.positions.items() if p.qty}

    def get_cash(self) -> float:
        return self.cash

    # --- orders ------------------------------------------------------------
    def place_order(self, order: Order) -> Order:
        if order.side is Side.BUY and order.notional + self.fees.cost(order.notional) > self.cash:
            order.status = OrderStatus.REJECTED
            order.reject_reason = "insufficient cash"
            return order
        held = self.positions.get(order.symbol, Position(order.symbol, 0)).qty
        if order.side is Side.SELL and order.qty > held:
            order.status = OrderStatus.REJECTED
            order.reject_reason = "insufficient shares (no short selling in cash account)"
            return order
        order.broker_order_no = f"P{next(self._seq):06d}"
        order.status = OrderStatus.OPEN
        self.orders[order.broker_order_no] = order
        self._match(order.symbol)
        return order

    def cancel_order(self, order: Order) -> Order:
        if not order.status.is_terminal:
            order.status = OrderStatus.CANCELLED
        return order

    def refresh_order(self, order: Order) -> Order:
        return order

    def _match(self, symbol: str) -> None:
        px = self._prices.get(symbol)
        if px is None:
            return
        for o in self.orders.values():
            if o.symbol != symbol or o.status.is_terminal:
                continue
            if o.price_type is PriceType.LIMIT:
                crosses = px <= o.price if o.side is Side.BUY else px >= o.price
                fill_px = o.price
            else:
                crosses, fill_px = True, px
            if crosses:
                self._fill(o, fill_px)

    def _fill(self, o: Order, px: float) -> None:
        notional = o.qty * px
        fee = self.fees.cost(notional)
        pos = self.positions.setdefault(o.symbol, Position(o.symbol, 0))
        if o.side is Side.BUY:
            self.cash -= notional + fee
            total = pos.qty + o.qty
            pos.avg_price = (pos.avg_price * pos.qty + notional) / total
            pos.qty = total
        else:
            self.cash += notional - fee
            pos.qty -= o.qty
            if pos.qty == 0:
                pos.avg_price = 0.0
        o.filled_qty = o.qty
        o.avg_fill_price = px
        o.status = OrderStatus.FILLED
