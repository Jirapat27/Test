from thaitrader.brokers.settrade import (
    parse_candles, parse_cash, parse_order_status, parse_positions,
)
from thaitrader.models import OrderStatus


def test_parse_columnar_candles():
    resp = {"time": [1704067200, 1704153600], "open": [1, 2], "high": [2, 3],
            "low": [0.5, 1.5], "close": [1.5, 2.5], "volume": [10, 20]}
    cs = parse_candles(resp)
    assert [c.close for c in cs] == [1.5, 2.5]
    assert cs[0].ts.year == 2024


def test_parse_positions_and_cash():
    resp = {"portfolioList": [
        {"symbol": "PTT", "actualVolume": 300, "averagePrice": 33.5},
        {"symbol": "AOT", "actualVolume": 0, "averagePrice": 0},
    ]}
    pos = parse_positions(resp)
    assert list(pos) == ["PTT"] and pos["PTT"].qty == 300
    assert parse_cash({"lineAvailable": 12345.5, "cashBalance": 1}) == 12345.5


def test_parse_order_status():
    assert parse_order_status({"showStatus": "Matched", "matchQty": 100}, 100)[0] is OrderStatus.FILLED
    assert parse_order_status({"showStatus": "Matched", "matchQty": 50}, 100)[0] is OrderStatus.PARTIAL
    assert parse_order_status({"showStatus": "Cancelled"}, 100)[0] is OrderStatus.CANCELLED
    assert parse_order_status({"showStatus": "Queuing", "matchQty": 0}, 100)[0] is OrderStatus.OPEN
