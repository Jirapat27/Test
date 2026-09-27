"""SET/mai market microstructure: tick sizes, board lots, price limits, sessions.

Rules change occasionally -- verify against the current SET rulebook before
trading live. Everything here is plain data so it is easy to update.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, time
from decimal import ROUND_CEILING, ROUND_FLOOR, Decimal
from zoneinfo import ZoneInfo

BANGKOK = ZoneInfo("Asia/Bangkok")

BOARD_LOT = 100
DAILY_PRICE_LIMIT = Decimal("0.30")  # +/-30% from previous close (stocks)

# (upper bound exclusive, tick size) -- SET equity tick size table.
_TICK_TABLE: list[tuple[Decimal, Decimal]] = [
    (Decimal("2"), Decimal("0.01")),
    (Decimal("5"), Decimal("0.02")),
    (Decimal("10"), Decimal("0.05")),
    (Decimal("25"), Decimal("0.10")),
    (Decimal("100"), Decimal("0.25")),
    (Decimal("200"), Decimal("0.50")),
    (Decimal("400"), Decimal("1.00")),
]
_TOP_TICK = Decimal("2.00")


def _d(x: float | str | Decimal) -> Decimal:
    return x if isinstance(x, Decimal) else Decimal(str(x))


def tick_size(price: float | Decimal) -> Decimal:
    p = _d(price)
    for upper, tick in _TICK_TABLE:
        if p < upper:
            return tick
    return _TOP_TICK


def round_to_tick(price: float | Decimal, direction: str = "down") -> float:
    """Round a price onto the tick grid.

    Use direction="down" for buy limits (never pay more than intended) and
    "up" for sell limits (never sell for less). Tick boundaries in the SET
    table are multiples of the next band's tick, so a single pass is enough.
    """
    p = _d(price)
    if p <= 0:
        raise ValueError(f"price must be positive, got {price}")
    tick = tick_size(p)
    mode = ROUND_FLOOR if direction == "down" else ROUND_CEILING
    steps = (p / tick).to_integral_value(rounding=mode)
    return float(steps * tick)


def is_valid_price(price: float | Decimal) -> bool:
    p = _d(price)
    return p > 0 and p % tick_size(p) == 0


def add_ticks(price: float, n: int) -> float:
    """Move a valid price by n ticks (n may be negative)."""
    p = _d(round_to_tick(price, "down" if n < 0 else "up"))
    for _ in range(abs(n)):
        if n > 0:
            p += tick_size(p)
        else:
            # step down using the tick of the band just below p
            p -= tick_size(p - Decimal("0.000001"))
    return float(p)


def round_to_lot(qty: int, lot: int = BOARD_LOT) -> int:
    """Floor a share quantity to whole board lots."""
    if qty < 0:
        return -round_to_lot(-qty, lot)
    return (qty // lot) * lot


def price_limits(prev_close: float) -> tuple[float, float]:
    """(floor, ceiling) for the day, rounded inward onto the tick grid."""
    pc = _d(prev_close)
    floor = round_to_tick(pc * (1 - DAILY_PRICE_LIMIT), "up")
    ceiling = round_to_tick(pc * (1 + DAILY_PRICE_LIMIT), "down")
    return floor, ceiling


@dataclass(frozen=True)
class Session:
    name: str
    start: time
    end: time
    continuous: bool  # False = call auction (ATO/ATC only matching at the end)


# Approximate SET equity schedule (Bangkok time). Pre-open end times are
# randomised by the exchange; treat these as conservative windows.
SET_SESSIONS: tuple[Session, ...] = (
    Session("pre_open_1", time(9, 30), time(10, 0), continuous=False),
    Session("morning", time(10, 0), time(12, 30), continuous=True),
    Session("pre_open_2", time(14, 0), time(14, 30), continuous=False),
    Session("afternoon", time(14, 30), time(16, 30), continuous=True),
    Session("pre_close", time(16, 30), time(16, 40), continuous=False),
)


def current_session(
    now: datetime | None = None,
    holidays: set[date] | frozenset[date] = frozenset(),
) -> Session | None:
    now = (now or datetime.now(BANGKOK)).astimezone(BANGKOK)
    if now.weekday() >= 5 or now.date() in holidays:
        return None
    t = now.time()
    for s in SET_SESSIONS:
        if s.start <= t < s.end:
            return s
    return None


def is_continuous_trading(
    now: datetime | None = None,
    holidays: set[date] | frozenset[date] = frozenset(),
) -> bool:
    s = current_session(now, holidays)
    return s is not None and s.continuous
