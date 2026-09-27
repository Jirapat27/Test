"""Settrade Open API adapter (SET/mai equities).

Install with: pip install "thaitrader[settrade]"

The SDK method signatures below were checked against settrade-v2 2.2.1.
The *response* field names are not formally documented in the SDK, so the
`_parse_*` helpers try several known spellings. Before going live, run
`thaitrader inspect` against the sandbox and confirm the fields match.
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any, Iterable

from ..config import SettradeCredentials
from ..market_rules import BANGKOK
from ..models import Candle, Order, OrderStatus, Position
from .base import Broker, BrokerError

log = logging.getLogger(__name__)


def _first(d: dict[str, Any], keys: Iterable[str], default: Any = None) -> Any:
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return default


def _to_dt(t: Any) -> datetime:
    if isinstance(t, (int, float)):
        # epoch seconds (or ms)
        return datetime.fromtimestamp(t / 1000 if t > 1e11 else t, BANGKOK)
    return datetime.fromisoformat(str(t))


def parse_candles(resp: Any) -> list[Candle]:
    """Accepts columnar {'time': [...], 'open': [...], ...} or a list of dicts."""
    if isinstance(resp, dict) and isinstance(resp.get("close"), list):
        cols = resp
        times = _first(cols, ("time", "timestamp", "date"), [])
        vols = cols.get("volume") or [0] * len(times)
        return [
            Candle(_to_dt(t), float(o), float(h), float(lo), float(c), float(v))
            for t, o, h, lo, c, v in zip(
                times, cols["open"], cols["high"], cols["low"], cols["close"], vols
            )
        ]
    rows = resp if isinstance(resp, list) else (resp or {}).get("data", [])
    return [
        Candle(
            _to_dt(_first(r, ("time", "timestamp", "date"))),
            float(r["open"]), float(r["high"]), float(r["low"]), float(r["close"]),
            float(r.get("volume", 0)),
        )
        for r in rows
    ]


def parse_positions(resp: Any) -> dict[str, Position]:
    rows = resp.get("portfolioList", []) if isinstance(resp, dict) else (resp or [])
    out: dict[str, Position] = {}
    for r in rows:
        qty = int(_first(r, ("actualVolume", "currentVolume", "availableVolume", "volume"), 0))
        if qty:
            sym = r["symbol"]
            out[sym] = Position(sym, qty, float(_first(r, ("averagePrice", "avgPrice"), 0.0)))
    return out


def parse_cash(resp: dict[str, Any]) -> float:
    val = _first(resp, ("lineAvailable", "buyingPower", "cashBalance", "excessEquity"))
    if val is None:
        raise BrokerError(f"cannot find buying power in account info keys: {sorted(resp)}")
    return float(val)


_STATUS_WORDS = {
    OrderStatus.FILLED: ("matched", "filled"),
    OrderStatus.CANCELLED: ("cancel", "expired"),
    OrderStatus.REJECTED: ("reject",),
}


def parse_order_status(resp: dict[str, Any], qty: int) -> tuple[OrderStatus, int, float]:
    filled = int(_first(resp, ("matchQty", "matchedVolume", "matchVolume"), 0))
    avg = float(_first(resp, ("matchPrice", "avgPrice", "price"), 0.0))
    text = str(_first(resp, ("showStatus", "status", "statusMeaning"), "")).lower()
    for status, words in _STATUS_WORDS.items():
        if any(w in text for w in words):
            if status is OrderStatus.FILLED and filled < qty:
                return OrderStatus.PARTIAL, filled, avg
            return status, filled, avg
    if qty and filled >= qty:
        return OrderStatus.FILLED, filled, avg
    return (OrderStatus.PARTIAL if filled else OrderStatus.OPEN), filled, avg


class SettradeBroker(Broker):
    def __init__(self, creds: SettradeCredentials):
        try:
            from settrade_v2 import Investor
        except ImportError as e:  # pragma: no cover
            raise BrokerError('settrade-v2 not installed: pip install "thaitrader[settrade]"') from e

        self._pin = creds.pin
        self.investor = Investor(
            app_id=creds.app_id,
            app_secret=creds.app_secret,
            app_code=creds.app_code,
            broker_id=creds.broker_id,
            is_auto_queue=False,
        )
        self.equity = self.investor.Equity(account_no=creds.account_no)
        self.market = self.investor.MarketData()

    def get_candles(self, symbol: str, interval: str = "1d", limit: int = 200) -> list[Candle]:
        return parse_candles(self.market.get_candlestick(symbol=symbol, interval=interval, limit=limit))

    def get_last_price(self, symbol: str) -> float:
        q = self.market.get_quote_symbol(symbol)
        px = _first(q, ("last", "lastPrice", "close", "prior"))
        if px is None:
            raise BrokerError(f"no price in quote for {symbol}: keys {sorted(q)}")
        return float(px)

    def get_positions(self) -> dict[str, Position]:
        return parse_positions(self.equity.get_portfolios())

    def get_cash(self) -> float:
        return parse_cash(self.equity.get_account_info())

    def place_order(self, order: Order) -> Order:
        from settrade_v2.errors import SettradeError

        try:
            resp = self.equity.place_order(
                pin=self._pin,
                side=order.side.value,
                symbol=order.symbol,
                volume=order.qty,
                price=order.price,
                price_type=order.price_type.value,
                validity_type="Day",
            )
        except SettradeError as e:
            order.status = OrderStatus.REJECTED
            order.reject_reason = str(e)
            log.warning("order %s rejected: %s", order.client_id, e)
            return order
        order.broker_order_no = str(_first(resp, ("orderNo", "orderId", "id"), ""))
        order.status = OrderStatus.OPEN
        return order

    def cancel_order(self, order: Order) -> Order:
        if order.broker_order_no and not order.status.is_terminal:
            self.equity.cancel_order(order_no=order.broker_order_no, pin=self._pin)
            return self.refresh_order(order)
        return order

    def refresh_order(self, order: Order) -> Order:
        if not order.broker_order_no:
            return order
        resp = self.equity.get_order(order.broker_order_no)
        order.status, order.filled_qty, order.avg_fill_price = parse_order_status(resp, order.qty)
        return order

    def raw_snapshot(self, symbol: str) -> dict[str, Any]:
        """Raw API responses, for checking field names (`thaitrader inspect`)."""
        return {
            "account_info": self.equity.get_account_info(),
            "portfolios": self.equity.get_portfolios(),
            "orders": self.equity.get_orders(),
            "quote": self.market.get_quote_symbol(symbol),
            "candlestick": self.market.get_candlestick(symbol=symbol, interval="1d", limit=3),
        }
