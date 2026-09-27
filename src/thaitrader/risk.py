from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from datetime import date
from pathlib import Path

from .market_rules import BOARD_LOT, is_valid_price
from .models import Order, Position, PriceType, Side

log = logging.getLogger(__name__)


class RiskViolation(Exception):
    pass


@dataclass(frozen=True)
class RiskLimits:
    max_order_value: float = 50_000.0
    max_position_value: float = 100_000.0
    max_daily_loss: float = 5_000.0
    max_orders_per_day: int = 20
    allowed_symbols: frozenset[str] | None = None  # None = any

    @classmethod
    def from_env(cls, allowed_symbols: frozenset[str] | None = None) -> "RiskLimits":
        def f(key: str, default: float) -> float:
            return float(os.environ.get(key) or default)

        return cls(
            max_order_value=f("RISK_MAX_ORDER_VALUE", cls.max_order_value),
            max_position_value=f("RISK_MAX_POSITION_VALUE", cls.max_position_value),
            max_daily_loss=f("RISK_MAX_DAILY_LOSS", cls.max_daily_loss),
            max_orders_per_day=int(f("RISK_MAX_ORDERS_PER_DAY", cls.max_orders_per_day)),
            allowed_symbols=allowed_symbols,
        )


class RiskManager:
    """Pre-trade checks plus a kill switch.

    The kill switch trips automatically when the daily loss limit is hit, and
    can be tripped manually by creating the KILL_SWITCH file (``touch KILL_SWITCH``).
    Once tripped, no new orders are allowed until the file is removed.
    """

    def __init__(self, limits: RiskLimits, kill_switch_path: str | Path = "KILL_SWITCH"):
        self.limits = limits
        self.kill_switch_path = Path(kill_switch_path)
        self._day: date | None = None
        self._start_equity: float | None = None
        self._orders_today = 0

    # --- daily state -------------------------------------------------------
    def start_day(self, today: date, equity: float) -> None:
        if self._day != today:
            self._day = today
            self._start_equity = equity
            self._orders_today = 0
            log.info("risk: new trading day %s, start equity %.2f", today, equity)

    def update_equity(self, equity: float) -> None:
        if self._start_equity is None:
            return
        loss = self._start_equity - equity
        if loss >= self.limits.max_daily_loss and not self.halted:
            self.trip(f"daily loss {loss:.2f} >= limit {self.limits.max_daily_loss:.2f}")

    # --- kill switch -------------------------------------------------------
    @property
    def halted(self) -> bool:
        return self.kill_switch_path.exists()

    def trip(self, reason: str) -> None:
        log.error("KILL SWITCH TRIPPED: %s", reason)
        self.kill_switch_path.write_text(reason + "\n")

    # --- pre-trade ---------------------------------------------------------
    def check(self, order: Order, positions: dict[str, Position], cash: float) -> None:
        lim = self.limits
        if self.halted:
            raise RiskViolation("kill switch is active")
        if lim.allowed_symbols is not None and order.symbol not in lim.allowed_symbols:
            raise RiskViolation(f"{order.symbol} not in allowed symbols")
        if order.qty <= 0 or order.qty % BOARD_LOT:
            raise RiskViolation(f"qty {order.qty} is not a positive multiple of {BOARD_LOT}")
        if order.price_type is PriceType.LIMIT and not is_valid_price(order.price):
            raise RiskViolation(f"price {order.price} is not on the tick grid")
        if self._orders_today >= lim.max_orders_per_day:
            raise RiskViolation(f"max orders per day ({lim.max_orders_per_day}) reached")
        if order.notional > lim.max_order_value:
            raise RiskViolation(f"order value {order.notional:.2f} > {lim.max_order_value:.2f}")

        held = positions.get(order.symbol, Position(order.symbol, 0)).qty
        if order.side is Side.BUY:
            if order.notional > cash:
                raise RiskViolation(f"order value {order.notional:.2f} > cash {cash:.2f}")
            if (held + order.qty) * order.price > lim.max_position_value:
                raise RiskViolation(
                    f"position value would exceed {lim.max_position_value:.2f}"
                )
        elif order.qty > held:
            raise RiskViolation(f"sell {order.qty} > held {held} (short selling not supported)")

    def record_order(self) -> None:
        self._orders_today += 1
