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

## BtcAdaptiveEA (v2.0): self-tuning multi-strategy bot for Bitcoin

`BtcAdaptiveEA.mq5` re-tunes itself and chooses between three **kinds** of
strategy. It only runs on BTC symbols such as `BTCUSDm`.

| Strategy | Entry | Exit (besides stop loss / take profit) |
|---|---|---|
| **TREND** | Fast SMA crosses slow SMA (5–20 / 20–60) | Opposite cross |
| **MEANREV** | Close outside the Bollinger Band (20 or 30 bars, 2 or 2.5 standard deviations) **and** RSI below 30/25 (buy) or above 70/75 (sell) | Price back at its average, or opposite signal |
| **BREAKOUT** | Close above the highest high / below the lowest low of the last 20, 40 or 60 bars | Opposite breakout |

**How it adapts (every `InpRetuneHours`, default 6 hours):**
1. It loads the last `InpLookbackDays` (default 7) of BTC prices on M1, M5 and
   M15.
2. It backtests **945 settings**: 3 timeframes × every strategy variant ×
   stop (1.5/2/3 × ATR) × target (none/2/3 × ATR). Every simulated trade pays
   the **current spread**. Results are in R, where 1R is the stop-loss distance
   (the risk of one trade).
3. A setting counts only if it has a profit factor of at least **`InpMinPF`
   (default 1.2)** on both the older ~2/3 of the data (tuning) **and** the most
   recent ~1/3, which it wasn't tuned on (validation). Among those, the one
   with the best tuning result wins.
4. It switches only if the winner beats the current setting by
   `InpSwitchMarginR` on validation, or if the current setting no longer
   clears the bar.
5. If nothing clears the bar, it **pauses new trades** (`InpPauseIfNoEdge`)
   and checks again at the next re-tune. Open positions keep their stops and
   exit rules.

You can switch each strategy on or off (`InpUseTrend`, `InpUseMeanRev`,
`InpUseBreakout`) and each timeframe (`InpUseM1/M5/M15`). Every switch, pause
and resume is sent to the Experts tab and your iPhone. The chart shows the
active strategy and its tuning and validation scores.

**Unchanged:** stop loss on every trade, sizing for about 1% risk, the spread
filter (default 2000 points), margin check, SL/TP alerts, and the real-account
lock. There is **no daily loss limit**. The default magic number is 20260929.

**Backtest the adaptation itself** in the Strategy Tester (BTCUSDm,
1-minute OHLC, 1–3 months). Each re-tune runs 945 mini backtests, so long
tests are slow.

## BtcAdaptiveTrendEA: trend-only self-tuning bot (M15)

`BtcAdaptiveTrendEA.mq5` is the first BtcAdaptiveEA (moving-average crossover
only, 648 settings) with the re-init fix. By default it considers **M15
only** and uses magic **20260930**, so it can run next to BtcAdaptiveEA 2.x,
for example:

| Chart | Bot | Timeframe inputs | Magic |
|---|---|---|---|
| BTCUSDm (any) | BtcAdaptiveEA 2.x (multi-strategy) | M1 and/or M5 on, **M15 off** | 20260929 |
| BTCUSDm (any) | BtcAdaptiveTrendEA | **M15 only** | 20260930 |

The bot chooses its timeframe from its inputs; the chart's timeframe doesn't
matter. Always give bots on the same symbol **different magic numbers**.
Both bots trade the same account, so their risk adds up.
