from datetime import datetime, timedelta

import pytest

from thaitrader.brokers import PaperBroker
from thaitrader.engine import TradingEngine
from thaitrader.market_rules import BANGKOK
from thaitrader.models import Order, OrderStatus, Side
from thaitrader.risk import RiskLimits, RiskManager
from thaitrader.strategy.base import Strategy


def test_paper_limit_fill_and_cash():
    b = PaperBroker(cash=10_000)
    b.set_price("PTT", 34.25)
    o = b.place_order(Order("PTT", Side.BUY, 100, 34.0))
    assert o.status is OrderStatus.OPEN
    b.set_price("PTT", 34.0)
    assert o.status is OrderStatus.FILLED
    assert b.get_positions()["PTT"].qty == 100
    assert b.get_cash() < 10_000 - 3_400
    s = b.place_order(Order("PTT", Side.SELL, 200, 34.0))
    assert s.status is OrderStatus.REJECTED


class FixedTarget(Strategy):
    def __init__(self, target):
        self.target = target

    def target_position(self, symbol, candles, current_qty):
        return self.target


@pytest.fixture
def setup(tmp_path, wave_candles):
    broker = PaperBroker(cash=100_000)
    broker.set_candles("PTT", wave_candles)
    risk = RiskManager(RiskLimits(max_order_value=50_000, max_position_value=50_000),
                       kill_switch_path=tmp_path / "KILL_SWITCH")
    now = [datetime(2024, 6, 3, 10, 30, tzinfo=BANGKOK)]
    return broker, risk, now


def make_engine(broker, risk, now, target):
    return TradingEngine(broker, FixedTarget(target), risk, ["PTT"], clock=lambda: now[0])


def test_engine_reaches_target_and_is_idempotent(setup):
    broker, risk, now = setup
    eng = make_engine(broker, risk, now, 300)
    placed = eng.run_once()
    assert len(placed) == 1 and placed[0].qty == 300 and placed[0].status is OrderStatus.FILLED
    assert broker.get_positions()["PTT"].qty == 300
    assert eng.run_once() == []  # already at target -> nothing to do

    eng.strategy.target = 0
    placed = eng.run_once()
    assert placed[0].side is Side.SELL and placed[0].qty == 300
    assert "PTT" not in broker.get_positions()


def test_engine_idle_outside_hours(setup):
    broker, risk, now = setup
    now[0] = datetime(2024, 6, 3, 13, 0, tzinfo=BANGKOK)
    assert make_engine(broker, risk, now, 300).run_once() == []


def test_engine_respects_kill_switch(setup):
    broker, risk, now = setup
    risk.trip("manual")
    assert make_engine(broker, risk, now, 300).run_once() == []


def test_engine_one_working_order_and_timeout(setup):
    broker, risk, now = setup
    eng = make_engine(broker, risk, now, 100)
    eng.aggressiveness_ticks = -5  # bid below market so it rests
    first = eng.run_once()[0]
    assert first.status is OrderStatus.OPEN
    assert eng.run_once() == []  # still working, no duplicate
    now[0] += timedelta(minutes=10)
    eng.run_once()  # stale order cancelled, a fresh one placed
    assert first.status is OrderStatus.CANCELLED
    assert eng.working["PTT"] is not first
