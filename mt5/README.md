# MT5 bot: SmaCrossEA

`SmaCrossEA.mq5` is a MetaTrader 5 Expert Advisor (EA), a bot that runs inside
**MT5 desktop**. The iPhone MT5 app can't run bots, but it shows the bot's
trades live and receives its push alerts.

> Use a **demo account**. The EA refuses to start on a real account unless you
> change `InpAllowRealAccount` to `true`. Leveraged CFDs can lose money fast.

## What it does

- **Signal:** buys when the fast moving average (SMA) crosses above the slow
  one and sells when it crosses below. It uses only closed bars and checks once
  per new bar.
- **Stops:** every trade gets a stop loss of ATR × 2 and a take profit of
  ATR × 3. ATR measures recent volatility, so stops widen in volatile markets.
- **Position size:** calculated so that hitting the stop loses about
  **1% of balance**. If even the minimum lot would risk more than that, the
  trade is **skipped**, never rounded up.
- **Daily loss limit:** if equity falls 3% below where it started the day
  (server time), the EA closes its positions and stops until the next day.
- **Also:** it skips entries when the spread is too wide, checks free margin
  before each order, sends push alerts to your phone, and shows its status in
  the chart's top-left corner.

## Install (once)

1. In MT5 desktop, go to **File → Open Data Folder**, then open `MQL5\Experts`.
2. Copy `SmaCrossEA.mq5` into that folder.
3. Open MetaEditor with **IDE** in the toolbar (or press F4), find
   `Experts\SmaCrossEA.mq5` in the Navigator, open it and press **F7 (Compile)**.
   It should report `0 errors`. Warnings are fine.
4. Back in MT5, right-click **Navigator → Expert Advisors → Refresh**.
   `SmaCrossEA` should now appear in the list.

## Test it first in the Strategy Tester

1. Go to **View → Strategy Tester** (Ctrl+R).
2. Set **Expert** to `SmaCrossEA`, **Symbol** to e.g. `EURUSDm` (Exness adds
   an `m` suffix on Standard accounts), **Timeframe** to H1, **Dates** to the
   last year, and **Modelling** to "Every tick based on real ticks" or
   "1 minute OHLC".
3. Click **Start**, then read the **Backtest** and **Graph** tabs.
4. Change the inputs (periods, risk, ATR multipliers) and compare. Watch out for
   overfitting: settings that look perfect on the past often fail in live trading.

## Run it on your demo account

1. Open a chart, e.g. `EURUSDm`, and set it to **H1** to match `InpTimeframe`.
2. Drag **SmaCrossEA** from the Navigator onto the chart.
3. On the **Common** tab, tick **Allow Algo Trading**. Check the **Inputs**
   tab, then click OK.
4. Turn on **Algo Trading** in the toolbar so it turns green. A small hat icon
   in the chart's top-right corner shows the EA is active.
5. Check the **Experts** tab at the bottom for the "started on DEMO account ..."
   message.

The bot runs only while MT5 desktop is open and the PC is awake. To keep it
running 24/5, use a Windows VPS or **MQL5 Virtual Hosting**: right-click your
account in Navigator and choose "Register a Virtual Server".

## Push alerts on your iPhone

1. In the iPhone MT5 app, open **Settings** (then **Messages** or **Chat and messages**, depending on the app version) and copy your
   **MetaQuotes ID**.
2. In MT5 desktop, go to **Tools → Options → Notifications**. Tick
   **Enable Push Notifications**, paste the ID, and click **Test**.
3. The EA now messages your phone when it starts, opens or closes a trade, a
   stop loss or take profit is hit, an order fails, or the daily loss limit
   is hit.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `InpTimeframe` | H1 | Bars used for signals |
| `InpFastPeriod` / `InpSlowPeriod` | 10 / 30 | SMA periods |
| `InpAllowShort` | true | Also open sell trades |
| `InpRiskPercent` | 1.0 | % of balance lost if the stop loss is hit (max 5) |
| `InpAtrPeriod` | 14 | ATR period |
| `InpStopAtrMult` | 2.0 | Stop loss distance = ATR × this |
| `InpTakeProfitAtrMult` | 3.0 | Take profit distance = ATR × this (0 = none) |
| `InpMaxDailyLossPct` | 3.0 | Daily equity drop that closes positions and stops trading (0 = off; takes effect immediately, even after a halt) |
| `InpMaxSpreadPoints` | 50 | Skip entries when the spread is wider (0 = no limit) |
| `InpAllowRealAccount` | false | Must be true to run on a real account |
| `InpPushAlerts` | true | Send push notifications |
| `InpMagic` | 20260927 | Tags this EA's positions. Use a different value per chart. |

## Notes

- **One chart = one symbol.** To trade several symbols, attach the EA to
  several charts, each with its own `InpMagic`.
- **Small accounts:** with 1,000 USD and 1% risk, instruments with large
  stops (e.g. gold) may always be skipped because 0.01 lot already risks more
  than 10 USD. That's the risk limit working as intended.
- **The daily limit is per chart.** Each chart tracks account equity
  separately.
- **Trading hours:** orders fail on weekends and when the market is closed,
  and the Experts log shows why.

## Variant without a daily loss limit

`SmaCrossEA_NoDailyLimit.mq5` is the same bot with the daily loss limit
removed completely. It keeps trading however much it loses in a day. Each
trade still has its stop loss and % risk sizing, and the real-account lock
stays. Its defaults match a BTCUSDm demo setup (M1, spread limit 2000 points,
magic 20260928), so attaching it fresh doesn't block BTC trades.
Install and compile it like the main EA.
