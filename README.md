# thaitrader

A starter framework for automated trading of Thai stocks (SET/mai) through the
**Settrade Open API**, which many Thai brokers support (KGI, Yuanta, InnovestX,
Krungsri, KBank, Bualuang, Finansia, Phillip, Maybank, Asia Plus, ...).

> **Risk warning.** This is educational scaffolding, not a profitable strategy.
> Automated trading can lose money quickly. Run in the sandbox and paper modes
> for a long time first, start live with small size, and tell your broker you
> are using algorithmic trading.

## Architecture

```
 candles ──▶ Strategy ──▶ target position ──▶ Engine (target − actual = order)
                                                   │
                                        RiskManager.check()  ── kill switch
                                                   │
                                     Broker interface (brokers/base.py)
                        ┌──────────────────┼──────────────────┐
                  PaperBroker        SettradeBroker        (your broker)
               (simulated fills)  (sandbox or live API)
```

* **Strategies return a target position**, not buy/sell signals. After a
  restart or a missed fill, the engine trades only the difference.
* **One broker interface** means the same strategy runs in backtest, paper,
  sandbox and live.
* **Thai market rules** live in `market_rules.py`: tick-size table, board lots
  of 100 shares, ±30% daily limits and session times (Bangkok time).

| Module | Purpose |
|---|---|
| `market_rules.py` | Tick sizes, rounding, lots, price limits, trading sessions |
| `fees.py` | Commission and exchange fees plus VAT (set to your broker's rates) |
| `strategy/` | `Strategy` base class and an example `SmaCross` |
| `backtest.py` | Decides on each bar's close and fills at the next open, with slippage, fees, lot and cash limits |
| `risk.py` | Per-order, position, daily-loss and order-count limits, plus a kill switch |
| `engine.py` | Live polling loop: reconcile, decide, risk-check, place, manage stale orders |
| `brokers/settrade.py` | Settrade Open API adapter (`settrade-v2` SDK) |
| `brokers/paper.py` | In-memory broker for dry runs and tests |
| `notify.py` | Telegram and LINE Messaging API alerts (LINE Notify was shut down in 2025) |

## Quick start

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e ".[settrade,dev]"      # add ,yf for Yahoo data in backtests
pytest                                 # 44 tests, no network needed

# Backtest on the bundled synthetic sample (not real prices)
thaitrader backtest --csv data/sample_ptt_synthetic.csv --symbol PTT --lots 20

# Backtest on real history via Yahoo (unofficial; SET tickers end in .BK)
thaitrader backtest --yf PTT.BK --period 5y --fast 10 --slow 30
```

## Connecting to Settrade

1. Open an account with a broker that supports Settrade Open API and register
   for API access. You'll get an App ID, an App Secret, an App Code and your
   broker ID.
2. `cp .env.example .env` and fill it in. For the **sandbox**, use
   `SETTRADE_BROKER_ID=SANDBOX` and `SETTRADE_APP_CODE=SANDBOX`.
3. Check what the API actually returns. The response field names in
   `brokers/settrade.py` are parsed defensively, but confirm them once:
   ```bash
   thaitrader inspect --symbol PTT
   ```
4. Run it:
   ```bash
   thaitrader run --mode sandbox --symbols PTT,AOT --interval 1d --poll 60
   thaitrader run --mode paper   --symbols PTT     # real prices, simulated fills
   ```
5. **Live** requires `THAITRADER_MODE=live` (or `--mode live`), a real broker ID
   and `THAITRADER_CONFIRM_LIVE=yes`. The CLI refuses to start otherwise.

**Emergency stop:** `touch KILL_SWITCH` in the working directory. The engine
cancels working orders and stops placing new ones until you delete the file.
It also creates this file itself when the daily loss limit is hit.

## MetaTrader 5 (forex/CFD demo)

To run a bot on MetaTrader 5 instead (for example an Exness demo account), see
[`mt5/`](mt5/README.md). It contains a ready-to-compile MQL5 Expert Advisor
with the same risk ideas: position sizing by % risk, a daily loss limit, and a
refusal to trade on a real account unless you explicitly allow it.

## Writing your own strategy

```python
from thaitrader.strategy.base import Strategy

class MyStrategy(Strategy):
    warmup = 50  # candles needed before deciding

    def target_position(self, symbol, candles, current_qty):
        # return desired share count (multiple of 100), or None to do nothing
        ...
```

## Known limitations and next steps

- **Order handling is by polling.** Use `RealtimeDataConnection.subscribe_equity_order`
  from the SDK for push fill updates and `subscribe_bid_offer` for live quotes.
- **Daily-bar strategies see today's unfinished bar** during the session. Either
  decide on completed bars only, or run the loop once near the close (ATC).
- **No persistence yet.** Add a database (SQLite or Postgres) for orders, fills
  and daily P&L, plus daily reconciliation against the broker.
- **Holidays:** pass the SET holiday calendar to `TradingEngine(holidays=...)`.
- **Equities only.** TFEX futures and options need `investor.Derivatives(...)`
  and a separate adapter, with different tick sizes, margin and a night session.
- **Fees and tick sizes** match SET rules at the time of writing. Check them
  against your broker and the current SET rulebook.
