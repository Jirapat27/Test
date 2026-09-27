from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime

from .fees import FeeSchedule
from .market_rules import BOARD_LOT, add_ticks, round_to_lot
from .models import Candle, Side
from .strategy.base import Strategy


@dataclass
class Trade:
    ts: datetime
    side: Side
    qty: int
    price: float
    fee: float
    pnl: float = 0.0  # realised P&L net of both legs' fees (sells only)


@dataclass
class BacktestResult:
    initial_cash: float
    equity_curve: list[tuple[datetime, float]] = field(default_factory=list)
    trades: list[Trade] = field(default_factory=list)

    @property
    def final_equity(self) -> float:
        return self.equity_curve[-1][1] if self.equity_curve else self.initial_cash

    @property
    def total_return(self) -> float:
        return self.final_equity / self.initial_cash - 1

    @property
    def max_drawdown(self) -> float:
        peak, mdd = float("-inf"), 0.0
        for _, eq in self.equity_curve:
            peak = max(peak, eq)
            mdd = max(mdd, (peak - eq) / peak)
        return mdd

    @property
    def total_fees(self) -> float:
        return sum(t.fee for t in self.trades)

    @property
    def win_rate(self) -> float:
        closes = [t for t in self.trades if t.side is Side.SELL]
        return sum(t.pnl > 0 for t in closes) / len(closes) if closes else 0.0

    def summary(self) -> str:
        sells = sum(t.side is Side.SELL for t in self.trades)
        return (
            f"Final equity : {self.final_equity:,.2f} THB\n"
            f"Total return : {self.total_return:+.2%}\n"
            f"Max drawdown : {self.max_drawdown:.2%}\n"
            f"Trades       : {len(self.trades)} ({sells} exits)\n"
            f"Win rate     : {self.win_rate:.1%}\n"
            f"Fees paid    : {self.total_fees:,.2f} THB"
        )


def run_backtest(
    candles: list[Candle],
    strategy: Strategy,
    symbol: str = "SYMBOL",
    initial_cash: float = 100_000.0,
    fees: FeeSchedule | None = None,
    slippage_ticks: int = 1,
) -> BacktestResult:
    """Decide on each bar's close, execute at the next bar's open.

    Buys pay `slippage_ticks` above the open and sells receive that many
    ticks below it. Quantities are floored to board lots and capped by cash.
    """
    fees = fees or FeeSchedule()
    res = BacktestResult(initial_cash)
    cash, qty, avg_cost = initial_cash, 0, 0.0
    pending_target: int | None = None

    for i, bar in enumerate(candles):
        # 1) execute yesterday's decision at today's open
        if pending_target is not None and pending_target != qty:
            diff = pending_target - qty
            if diff > 0:
                px = add_ticks(bar.open, slippage_ticks)
                lot_cost = px * BOARD_LOT
                affordable = int(cash // (lot_cost + fees.cost(lot_cost))) * BOARD_LOT
                buy = min(round_to_lot(diff), affordable)
                if buy > 0:
                    fee = fees.cost(buy * px)
                    cash -= buy * px + fee
                    avg_cost = (avg_cost * qty + buy * px + fee) / (qty + buy)
                    qty += buy
                    res.trades.append(Trade(bar.ts, Side.BUY, buy, px, fee))
            else:
                px = add_ticks(bar.open, -slippage_ticks)
                sell = min(round_to_lot(-diff), qty)
                if sell > 0:
                    fee = fees.cost(sell * px)
                    cash += sell * px - fee
                    pnl = (px - avg_cost) * sell - fee
                    qty -= sell
                    if qty == 0:
                        avg_cost = 0.0
                    res.trades.append(Trade(bar.ts, Side.SELL, sell, px, fee, pnl))
        pending_target = None

        # 2) mark to market at the close and decide for tomorrow
        res.equity_curve.append((bar.ts, cash + qty * bar.close))
        if i + 1 >= strategy.warmup:
            pending_target = strategy.target_position(symbol, candles[: i + 1], qty)

    return res
