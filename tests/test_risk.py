from datetime import date

import pytest

from thaitrader.models import Order, Position, Side
from thaitrader.risk import RiskLimits, RiskManager, RiskViolation


@pytest.fixture
def rm(tmp_path):
    return RiskManager(
        RiskLimits(max_order_value=10_000, max_position_value=15_000, max_daily_loss=1_000,
                   max_orders_per_day=2, allowed_symbols=frozenset({"PTT"})),
        kill_switch_path=tmp_path / "KILL_SWITCH",
    )


def buy(qty=100, price=34.0, sym="PTT"):
    return Order(sym, Side.BUY, qty, price)


def test_accepts_valid_order(rm):
    rm.check(buy(), {}, cash=50_000)


@pytest.mark.parametrize("order,msg", [
    (buy(sym="AOT"), "allowed"),
    (buy(qty=150), "multiple"),
    (buy(price=34.1), "tick"),
    (buy(qty=300), "order value"),
])
def test_rejects(rm, order, msg):
    with pytest.raises(RiskViolation, match=msg):
        rm.check(order, {}, cash=50_000)


def test_rejects_insufficient_cash(rm):
    with pytest.raises(RiskViolation, match="cash"):
        rm.check(buy(), {}, cash=1_000)


def test_position_limit(rm):
    with pytest.raises(RiskViolation, match="position value"):
        rm.check(buy(qty=200), {"PTT": Position("PTT", 300)}, cash=50_000)


def test_no_short_selling(rm):
    with pytest.raises(RiskViolation, match="short"):
        rm.check(Order("PTT", Side.SELL, 200, 34.0), {"PTT": Position("PTT", 100)}, cash=0)


def test_order_count_limit(rm):
    rm.record_order(); rm.record_order()
    with pytest.raises(RiskViolation, match="orders per day"):
        rm.check(buy(), {}, cash=50_000)
    rm.start_day(date(2024, 1, 2), 100_000)  # new day resets the counter
    rm.check(buy(), {}, cash=50_000)


def test_daily_loss_trips_kill_switch(rm):
    rm.start_day(date(2024, 1, 2), 100_000)
    rm.update_equity(99_500)
    assert not rm.halted
    rm.update_equity(98_900)
    assert rm.halted
    with pytest.raises(RiskViolation, match="kill switch"):
        rm.check(buy(), {}, cash=50_000)
    rm.kill_switch_path.unlink()
    assert not rm.halted
