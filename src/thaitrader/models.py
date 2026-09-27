from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class Side(str, Enum):
    # Values match the strings Settrade Open API expects.
    BUY = "Buy"
    SELL = "Sell"


class PriceType(str, Enum):
    LIMIT = "Limit"
    ATO = "ATO"
    ATC = "ATC"
    MP_MKT = "MP-MKT"
    MP_MTL = "MP-MTL"


class OrderStatus(str, Enum):
    NEW = "new"            # created locally, not yet sent
    OPEN = "open"          # accepted by broker, working
    PARTIAL = "partial"
    FILLED = "filled"
    CANCELLED = "cancelled"
    REJECTED = "rejected"

    @property
    def is_terminal(self) -> bool:
        return self in (OrderStatus.FILLED, OrderStatus.CANCELLED, OrderStatus.REJECTED)


@dataclass
class Candle:
    ts: datetime
    open: float
    high: float
    low: float
    close: float
    volume: float = 0.0


@dataclass
class Position:
    symbol: str
    qty: int
    avg_price: float = 0.0


@dataclass
class Order:
    symbol: str
    side: Side
    qty: int
    price: float
    price_type: PriceType = PriceType.LIMIT
    client_id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    broker_order_no: str | None = None
    status: OrderStatus = OrderStatus.NEW
    filled_qty: int = 0
    avg_fill_price: float = 0.0
    reject_reason: str | None = None
    created_at: datetime = field(default_factory=datetime.now)

    @property
    def notional(self) -> float:
        return self.qty * self.price

    @property
    def signed_qty(self) -> int:
        return self.qty if self.side is Side.BUY else -self.qty
