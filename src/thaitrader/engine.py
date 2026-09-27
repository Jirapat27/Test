from __future__ import annotations

import logging
import time as _time
from datetime import date, datetime, timedelta
from typing import Callable

from .brokers.base import Broker
from .market_rules import BANGKOK, add_ticks, is_continuous_trading, round_to_lot, round_to_tick
from .models import Order, OrderStatus, Side
from .notify import Notifier
from .risk import RiskManager, RiskViolation
from .strategy.base import Strategy

log = logging.getLogger(__name__)


class TradingEngine:
    """Polling loop: reconcile -> decide -> risk-check -> place orders.

    Each cycle compares the strategy's target position with the broker's
    actual position and trades the difference, so restarts and missed
    fills self-correct. At most one working order per symbol is allowed;
    orders older than `order_timeout` are cancelled and re-decided.
    """

    def __init__(
        self,
        broker: Broker,
        strategy: Strategy,
        risk: RiskManager,
        symbols: list[str],
        interval: str = "1d",
        notifier: Notifier | None = None,
        clock: Callable[[], datetime] = lambda: datetime.now(BANGKOK),
        holidays: frozenset[date] = frozenset(),
        order_timeout: timedelta = timedelta(minutes=5),
        aggressiveness_ticks: int = 0,
    ):
        self.broker = broker
        self.strategy = strategy
        self.risk = risk
        self.symbols = symbols
        self.interval = interval
        self.notifier = notifier or Notifier()
        self.clock = clock
        self.holidays = holidays
        self.order_timeout = order_timeout
        self.aggressiveness_ticks = aggressiveness_ticks
        self.working: dict[str, Order] = {}

    # ----------------------------------------------------------------------
    def run_once(self) -> list[Order]:
        now = self.clock()
        if not is_continuous_trading(now, self.holidays):
            log.debug("market not in continuous trading at %s", now)
            return []
        if self.risk.halted:
            self._cancel_all("kill switch active")
            return []

        positions = self.broker.get_positions()
        cash = self.broker.get_cash()
        equity = cash + sum(p.qty * self.broker.get_last_price(s) for s, p in positions.items())
        self.risk.start_day(now.date(), equity)
        self.risk.update_equity(equity)
        if self.risk.halted:
            self.notifier.send(f"Trading halted: daily loss limit hit (equity {equity:,.2f})")
            self._cancel_all("daily loss limit")
            return []

        self._refresh_working(now)
        placed: list[Order] = []
        for symbol in self.symbols:
            if symbol in self.working:
                continue
            order = self._decide(symbol, positions, now)
            if order is None:
                continue
            try:
                self.risk.check(order, positions, cash)
            except RiskViolation as e:
                log.warning("risk blocked %s %s %s: %s", order.side.value, order.qty, symbol, e)
                continue
            self.broker.place_order(order)
            self.risk.record_order()
            if order.status is OrderStatus.REJECTED:
                self.notifier.send(f"REJECTED {order.side.value} {order.qty} {symbol} @ {order.price}: {order.reject_reason}")
            else:
                if not order.status.is_terminal:
                    self.working[symbol] = order
                if order.side is Side.BUY:
                    cash -= order.notional
                self.notifier.send(f"{order.side.value} {order.qty} {symbol} @ {order.price} ({order.status.value})")
            placed.append(order)
        return placed

    def run_forever(self, poll_seconds: float = 60.0) -> None:
        log.info("engine started: symbols=%s interval=%s poll=%ss", self.symbols, self.interval, poll_seconds)
        while True:
            try:
                self.run_once()
            except KeyboardInterrupt:
                raise
            except Exception:
                # Network blips etc. must not kill the loop; alert and retry next cycle.
                log.exception("cycle failed")
                self.notifier.send("Engine cycle failed -- check logs")
            _time.sleep(poll_seconds)

    # ----------------------------------------------------------------------
    def _decide(self, symbol: str, positions: dict, now: datetime) -> Order | None:
        held = positions[symbol].qty if symbol in positions else 0
        candles = self.broker.get_candles(symbol, self.interval, limit=max(self.strategy.warmup + 10, 50))
        target = self.strategy.target_position(symbol, candles, held)
        if target is None:
            return None
        diff = round_to_lot(max(target, 0) - held)
        if diff == 0:
            return None

        last = self.broker.get_last_price(symbol)
        side = Side.BUY if diff > 0 else Side.SELL
        n = self.aggressiveness_ticks
        # Buy at/above last, sell at/below last, so the limit is likely to fill.
        base = round_to_tick(last, "up" if side is Side.BUY else "down")
        price = add_ticks(base, n if side is Side.BUY else -n)
        return Order(symbol=symbol, side=side, qty=abs(diff), price=price, created_at=now)

    def _refresh_working(self, now: datetime) -> None:
        for symbol, order in list(self.working.items()):
            self.broker.refresh_order(order)
            if not order.status.is_terminal and now - order.created_at > self.order_timeout:
                log.info("cancelling stale order %s %s", order.broker_order_no, symbol)
                self.broker.cancel_order(order)
            if order.status.is_terminal:
                del self.working[symbol]

    def _cancel_all(self, reason: str) -> None:
        for symbol, order in list(self.working.items()):
            log.warning("cancelling %s (%s)", order.broker_order_no, reason)
            self.broker.cancel_order(order)
            del self.working[symbol]
