from datetime import datetime

import pytest

from thaitrader.market_rules import (
    BANGKOK, add_ticks, current_session, is_continuous_trading, is_valid_price,
    price_limits, round_to_lot, round_to_tick, tick_size,
)


@pytest.mark.parametrize("price,tick", [
    (1.99, 0.01), (2.00, 0.02), (4.98, 0.02), (5, 0.05), (9.95, 0.05), (10, 0.10),
    (24.9, 0.10), (25, 0.25), (99.75, 0.25), (100, 0.50), (199.5, 0.50),
    (200, 1.00), (399, 1.00), (400, 2.00), (1000, 2.00),
])
def test_tick_size(price, tick):
    assert float(tick_size(price)) == tick


def test_round_to_tick_directions():
    assert round_to_tick(33.13, "down") == 33.00
    assert round_to_tick(33.13, "up") == 33.25
    assert round_to_tick(4.999, "down") == 4.98
    assert round_to_tick(1.995, "up") == 2.00
    assert round_to_tick(34.25, "down") == 34.25  # already valid


def test_is_valid_price():
    assert is_valid_price(34.25)
    assert not is_valid_price(34.30)
    assert is_valid_price(1.23)
    assert not is_valid_price(0)


def test_add_ticks_crosses_bands():
    assert add_ticks(24.9, 1) == 25.0
    assert add_ticks(25.0, 1) == 25.25
    assert add_ticks(25.0, -1) == 24.9
    assert add_ticks(2.00, -1) == 1.99
    assert add_ticks(34.25, 0) == 34.25


def test_round_to_lot():
    assert round_to_lot(250) == 200
    assert round_to_lot(99) == 0
    assert round_to_lot(-250) == -200


def test_price_limits():
    floor, ceiling = price_limits(100.0)
    assert (floor, ceiling) == (70.0, 130.0)
    floor, ceiling = price_limits(33.0)  # 23.1 / 42.9
    assert floor == 23.1 and ceiling == 42.75
    assert is_valid_price(floor) and is_valid_price(ceiling)


def test_sessions():
    mon = lambda h, m: datetime(2024, 6, 3, h, m, tzinfo=BANGKOK)
    assert current_session(mon(9, 45)).name == "pre_open_1"
    assert is_continuous_trading(mon(10, 30))
    assert not is_continuous_trading(mon(13, 0))  # lunch break
    assert is_continuous_trading(mon(15, 0))
    assert not is_continuous_trading(mon(17, 0))
    sat = datetime(2024, 6, 1, 11, 0, tzinfo=BANGKOK)
    assert current_session(sat) is None
    assert not is_continuous_trading(mon(10, 30), holidays={mon(10, 30).date()})
