from thaitrader.backtest import run_backtest
from thaitrader.market_rules import is_valid_price
from thaitrader.models import Side
from thaitrader.strategy import SmaCross


def test_backtest_trades_and_accounts(wave_candles):
    res = run_backtest(wave_candles, SmaCross(5, 20, lots=10), initial_cash=100_000)
    assert len(res.trades) >= 4
    assert len(res.equity_curve) == len(wave_candles)
    for t in res.trades:
        assert t.qty % 100 == 0 and t.qty > 0
        assert is_valid_price(t.price)
    # buys and sells alternate for a long/flat strategy
    sides = [t.side for t in res.trades]
    assert all(a != b for a, b in zip(sides, sides[1:]))
    assert res.total_fees > 0
    assert 0 <= res.max_drawdown < 1


def test_no_lookahead(wave_candles):
    """A trade decided on bar i must execute at bar i+1's open."""
    res = run_backtest(wave_candles, SmaCross(5, 20), initial_cash=100_000, slippage_ticks=0)
    by_ts = {c.ts: c for c in wave_candles}
    first = res.trades[0]
    assert first.side is Side.BUY
    assert first.price >= by_ts[first.ts].open  # executed at that bar's open (rounded)
    assert first.ts > wave_candles[19].ts        # not before warmup completes


def test_cash_caps_position(wave_candles):
    res = run_backtest(wave_candles, SmaCross(5, 20, lots=1000), initial_cash=10_000)
    first_buy = res.trades[0]
    assert first_buy.side is Side.BUY
    assert 0 < first_buy.qty * first_buy.price + first_buy.fee <= 10_000
    assert first_buy.qty < 1000 * 100  # capped by cash, not by the strategy's target
