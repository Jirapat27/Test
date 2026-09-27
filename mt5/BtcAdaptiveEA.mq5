//+------------------------------------------------------------------+
//|                                                BtcAdaptiveEA.mq5 |
//|  BTC-only multi-strategy bot that re-tunes itself.               |
//|                                                                  |
//|  Every few hours it backtests three kinds of strategy on recent  |
//|  BTC prices, including the current spread:                       |
//|    TREND    moving-average crossover                             |
//|    MEANREV  Bollinger Band + RSI stretch, exit back at the mean  |
//|    BREAKOUT close beyond the recent high/low range (Donchian)    |
//|  across timeframes, periods, stop and target sizes. It picks the |
//|  best on the older part of the data, requires it to also be      |
//|  profitable on the most recent part it did not tune on, and      |
//|  switches only when clearly better. When nothing clears the bar  |
//|  it stops opening trades until the next re-tune.                 |
//|                                                                  |
//|  For learning on a DEMO account -- adaptation does not guarantee |
//|  profits. There is NO daily loss limit in this bot.              |
//+------------------------------------------------------------------+
#property copyright "thaitrader"
#property version   "2.01"
#property description "BTC-only bot that re-tunes itself across TREND, MEAN-REVERSION and BREAKOUT strategies"
#property description "on recent data (incl. spread), validates on unseen data, pauses when nothing works."
#property description "Per-trade stop loss and % risk sizing. No daily loss limit. Demo-only unless allowed."

#include <Trade\Trade.mqh>

input group "Self-tuning"
input int    InpRetuneHours     = 6;     // Re-tune every N hours
input int    InpLookbackDays    = 7;     // Days of recent history used for tuning
input double InpValidationShare = 0.33;  // Most recent share of the lookback kept for validation (0.1-0.5)
input int    InpMinTrades       = 15;    // Minimum trades in the tuning part for a setting to count
input double InpMinPF           = 1.2;   // Minimum profit factor in BOTH tuning and validation
input double InpSwitchMarginR   = 1.0;   // New setting must beat the current one by this many R (validation)
input bool   InpPauseIfNoEdge   = true;  // Stop opening trades when no setting clears the bar
input bool   InpUseTrend        = true;  // Strategy: TREND (moving-average crossover)
input bool   InpUseMeanRev      = true;  // Strategy: MEAN REVERSION (Bollinger Bands + RSI)
input bool   InpUseBreakout     = true;  // Strategy: BREAKOUT (recent high/low range)
input bool   InpUseM1           = true;  // Candidate timeframe: M1
input bool   InpUseM5           = true;  // Candidate timeframe: M5
input bool   InpUseM15          = true;  // Candidate timeframe: M15

input group "Risk"
input double InpRiskPercent     = 1.0;   // % of balance lost if the stop loss is hit
input int    InpAtrPeriod       = 14;    // ATR period for stop/target distance
input int    InpRsiPeriod       = 14;    // RSI period (mean reversion)
input int    InpMaxSpreadPoints = 2000;  // Skip entries when spread is wider, in points (0 = no limit)
input bool   InpAllowShort      = true;  // Also trade short (sell) signals

input group "Safety and alerts"
input bool   InpAllowRealAccount = false;    // Allow trading on a REAL account
input bool   InpPushAlerts       = true;     // Send push notifications to the MT5 phone app
input ulong  InpMagic            = 20260929; // Magic number (identifies this EA's positions)

#define STRAT_TREND    0
#define STRAT_MEANREV  1
#define STRAT_BREAKOUT 2

//--- Candidate grids
int    FastList[]   = {5, 8, 10, 12, 20};   // TREND fast SMA
int    SlowList[]   = {20, 21, 30, 48, 60}; // TREND slow SMA
int    BandList[]   = {20, 30};             // MEANREV Bollinger/SMA period
double BandKList[]  = {2.0, 2.5};           // MEANREV band width in standard deviations
int    RsiLowList[] = {30, 25};             // MEANREV RSI oversold level (overbought = 100 - this)
int    RangeList[]  = {20, 40, 60};         // BREAKOUT range length in bars
double SlList[]     = {1.5, 2.0, 3.0};      // stop loss = ATR x this
double TpList[]     = {0.0, 2.0, 3.0};      // take profit = ATR x this (0 = exit on the strategy's exit signal)

struct Config
{
   int             strat;
   ENUM_TIMEFRAMES tf;
   int             p1;      // TREND fast | MEANREV period | BREAKOUT range
   int             p2;      // TREND slow | MEANREV RSI low level
   double          p3;      // MEANREV band width
   double          slMult;
   double          tpMult;
};

struct SimResult
{
   int    trades;
   double totalR;      // sum of trade results in R (1R = the stop-loss distance)
   double winR;
   double lossR;
};

CTrade    trade;
Config    cur;
bool      haveConfig   = false;
bool      paused       = false;
datetime  lastBarTime  = 0;
datetime  nextRetune   = 0;
datetime  lastRetune   = 0;
SimResult curIS, curOOS;
string    lastRetuneNote = "not tuned yet";

//--- Search state used during Retune()
bool      s_found, s_curEvaluated;
Config    s_best;
SimResult s_bestIS, s_bestOOS, s_curIS, s_curOOS;
int       s_tested;

//--- Price series of one timeframe (closed bars, oldest first) + prefix sums
double g_open[], g_high[], g_low[], g_close[];
double g_cumClose[], g_cumTR[], g_cumDev[], g_cumDev2[], g_cumGain[], g_cumLoss[];
double g_base = 0;   // closes are shifted by this before squaring (keeps variance accurate)
int    g_n = 0;

//+------------------------------------------------------------------+
void Notify(const string text)
{
   string msg = "BtcAdaptive " + _Symbol + ": " + text;
   Print(msg);
   if(InpPushAlerts && !MQLInfoInteger(MQL_TESTER) && TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      SendNotification(msg);
}

string TfName(const ENUM_TIMEFRAMES tf)
{
   return StringSubstr(EnumToString(tf), 7); // "PERIOD_M5" -> "M5"
}

string ConfigText(const Config &c)
{
   string tp = c.tpMult > 0 ? StringFormat("%.1fxATR", c.tpMult) : "on exit signal";
   string core;
   if(c.strat == STRAT_TREND)
      core = StringFormat("TREND SMA %d/%d", c.p1, c.p2);
   else if(c.strat == STRAT_MEANREV)
      core = StringFormat("MEANREV BB %d x%.1f RSI %d/%d", c.p1, c.p3, c.p2, 100 - c.p2);
   else
      core = StringFormat("BREAKOUT %d bars", c.p1);
   return StringFormat("%s %s SL %.1fxATR TP %s", TfName(c.tf), core, c.slMult, tp);
}

double ProfitFactor(const SimResult &r)
{
   if(r.lossR > 0)
      return r.winR / r.lossR;
   return r.winR > 0 ? 99.0 : 0.0;
}

void ResetResult(SimResult &r)
{
   r.trades = 0;
   r.totalR = 0;
   r.winR   = 0;
   r.lossR  = 0;
}

void Book(SimResult &r, const double resultR)
{
   r.trades++;
   r.totalR += resultR;
   if(resultR > 0)
      r.winR += resultR;
   else
      r.lossR -= resultR;
}

//+------------------------------------------------------------------+
//| Load closed bars of a timeframe into the g_ arrays               |
//+------------------------------------------------------------------+
bool LoadSeries(const ENUM_TIMEFRAMES tf, const int bars, const int minBars)
{
   MqlRates r[];
   int got = CopyRates(_Symbol, tf, 1, bars, r); // start at 1 = skip the bar still forming
   if(got < minBars)
      return false;

   g_n    = got;
   g_base = r[0].close;
   ArrayResize(g_open, got);
   ArrayResize(g_high, got);
   ArrayResize(g_low, got);
   ArrayResize(g_close, got);
   ArrayResize(g_cumClose, got + 1);
   ArrayResize(g_cumTR, got + 1);
   ArrayResize(g_cumDev, got + 1);
   ArrayResize(g_cumDev2, got + 1);
   ArrayResize(g_cumGain, got + 1);
   ArrayResize(g_cumLoss, got + 1);
   g_cumClose[0] = 0;
   g_cumTR[0]    = 0;
   g_cumDev[0]   = 0;
   g_cumDev2[0]  = 0;
   g_cumGain[0]  = 0;
   g_cumLoss[0]  = 0;
   for(int i = 0; i < got; i++)
   {
      g_open[i]  = r[i].open;
      g_high[i]  = r[i].high;
      g_low[i]   = r[i].low;
      g_close[i] = r[i].close;
      double tr = r[i].high - r[i].low;
      double change = 0;
      if(i > 0)
      {
         tr = MathMax(tr, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
         change = r[i].close - r[i - 1].close;
      }
      double dev = r[i].close - g_base;
      g_cumClose[i + 1] = g_cumClose[i] + r[i].close;
      g_cumTR[i + 1]    = g_cumTR[i] + tr;
      g_cumDev[i + 1]   = g_cumDev[i] + dev;
      g_cumDev2[i + 1]  = g_cumDev2[i] + dev * dev;
      g_cumGain[i + 1]  = g_cumGain[i] + (change > 0 ? change : 0);
      g_cumLoss[i + 1]  = g_cumLoss[i] + (change < 0 ? -change : 0);
   }
   return true;
}

// Mean of close[i-p+1 .. i]
double SmaAt(const int i, const int p)
{
   return (g_cumClose[i + 1] - g_cumClose[i + 1 - p]) / p;
}

// Population standard deviation of close[i-p+1 .. i]
double StdAt(const int i, const int p)
{
   double m  = (g_cumDev[i + 1] - g_cumDev[i + 1 - p]) / p;
   double m2 = (g_cumDev2[i + 1] - g_cumDev2[i + 1 - p]) / p;
   double v  = m2 - m * m;
   return v > 0 ? MathSqrt(v) : 0;
}

// Simple average true range over bars i-p+1 .. i
double AtrAt(const int i, const int p)
{
   return (g_cumTR[i + 1] - g_cumTR[i + 1 - p]) / p;
}

// RSI (simple-average form) over the last p price changes ending at bar i
double RsiAt(const int i, const int p)
{
   double gain = g_cumGain[i + 1] - g_cumGain[i + 1 - p];
   double loss = g_cumLoss[i + 1] - g_cumLoss[i + 1 - p];
   if(gain + loss <= 0)
      return 50.0;
   return 100.0 * gain / (gain + loss);
}

// +1 = fast crossed above slow at the close of bar i, -1 = crossed below, 0 = no cross
int CrossAt(const int i, const int fast, const int slow)
{
   double d0 = SmaAt(i - 1, fast) - SmaAt(i - 1, slow);
   double d1 = SmaAt(i, fast) - SmaAt(i, slow);
   if(d0 <= 0 && d1 > 0)
      return 1;
   if(d0 >= 0 && d1 < 0)
      return -1;
   return 0;
}

// Bars needed before a setting can produce signals
int Warmup(const Config &c)
{
   int w = InpAtrPeriod;
   if(c.strat == STRAT_TREND)
      w = MathMax(w, c.p2);
   else if(c.strat == STRAT_MEANREV)
      w = MathMax(w, MathMax(c.p1, InpRsiPeriod));
   else
      w = MathMax(w, c.p1);
   return w + 1;
}

// Entry signal at the close of bar i: +1 buy, -1 sell, 0 nothing. Needs i >= Warmup(c).
int EntrySignal(const int i, const Config &c)
{
   if(c.strat == STRAT_TREND)
      return CrossAt(i, c.p1, c.p2);

   if(c.strat == STRAT_MEANREV)
   {
      double mid  = SmaAt(i, c.p1);
      double band = c.p3 * StdAt(i, c.p1);
      double rsi  = RsiAt(i, InpRsiPeriod);
      if(g_close[i] < mid - band && rsi < c.p2)
         return 1;
      if(g_close[i] > mid + band && rsi > 100 - c.p2)
         return -1;
      return 0;
   }

   // BREAKOUT: close beyond the highest high / lowest low of the previous p1 bars
   double hi = g_high[i - 1], lo = g_low[i - 1];
   for(int k = i - c.p1; k < i - 1; k++)
   {
      if(g_high[k] > hi)
         hi = g_high[k];
      if(g_low[k] < lo)
         lo = g_low[k];
   }
   if(g_close[i] > hi)
      return 1;
   if(g_close[i] < lo)
      return -1;
   return 0;
}

// Strategy-specific exit at the close of bar i for a position in direction pos (+1/-1).
// TREND and BREAKOUT exit on the opposite entry signal (handled by the caller);
// MEANREV also exits once the price is back at its average.
bool ExitSignal(const int i, const Config &c, const int pos)
{
   if(c.strat != STRAT_MEANREV)
      return false;
   double mid = SmaAt(i, c.p1);
   return pos > 0 ? g_close[i] >= mid : g_close[i] <= mid;
}

//+------------------------------------------------------------------+
//| Backtest one setting on bars [iFrom, iTo) of the loaded series.  |
//| Same rules as live: decide on a bar's close, act at the next     |
//| open, SL/TP from ATR. Buys pay the spread on entry, sells on     |
//| exit. If SL and TP are both touched in one bar, the stop is      |
//| assumed to hit first.                                            |
//+------------------------------------------------------------------+
void Simulate(const Config &c, const int iFrom, const int iTo, const double spread, SimResult &res)
{
   ResetResult(res);
   int    pos = 0;
   double entry = 0, sl = 0, tp = 0, risk = 0;
   int    start = MathMax(iFrom, Warmup(c));

   for(int i = start; i < iTo; i++)
   {
      // 1) Manage the open position during bar i
      if(pos > 0)
      {
         if(g_low[i] <= sl)                          { Book(res, (sl - entry) / risk); pos = 0; }
         else if(tp > 0 && g_high[i] >= tp)          { Book(res, (tp - entry) / risk); pos = 0; }
      }
      else if(pos < 0)
      {
         if(g_high[i] + spread >= sl)                { Book(res, (entry - sl) / risk); pos = 0; }
         else if(tp > 0 && g_low[i] + spread <= tp)  { Book(res, (entry - tp) / risk); pos = 0; }
      }

      // 2) Signals at the close of bar i -> act at the open of bar i+1
      if(i + 1 >= iTo)
         break;
      double nextOpen = g_open[i + 1];
      int    x = EntrySignal(i, c);

      if(pos != 0 && (ExitSignal(i, c, pos) || (x != 0 && x != pos)))
      {
         double exitPx = pos > 0 ? nextOpen : nextOpen + spread;
         Book(res, pos > 0 ? (exitPx - entry) / risk : (entry - exitPx) / risk);
         pos = 0;
      }
      if(pos == 0 && x != 0 && (x > 0 || InpAllowShort))
      {
         double atr = AtrAt(i, InpAtrPeriod);
         if(atr <= 0)
            continue;
         risk = atr * c.slMult;
         if(x > 0)
         {
            entry = nextOpen + spread;
            sl    = entry - risk;
            tp    = c.tpMult > 0 ? entry + atr * c.tpMult : 0;
         }
         else
         {
            entry = nextOpen;
            sl    = entry + risk;
            tp    = c.tpMult > 0 ? entry - atr * c.tpMult : 0;
         }
         pos = x;
      }
   }

   if(pos != 0) // mark a still-open trade at the last close
   {
      double last = g_close[iTo - 1];
      Book(res, pos > 0 ? (last - entry) / risk : (entry - (last + spread)) / risk);
   }
}

bool SameConfig(const Config &a, const Config &b)
{
   return a.strat == b.strat && a.tf == b.tf && a.p1 == b.p1 && a.p2 == b.p2 &&
          MathAbs(a.p3 - b.p3) < 1e-9 && MathAbs(a.slMult - b.slMult) < 1e-9 &&
          MathAbs(a.tpMult - b.tpMult) < 1e-9;
}

bool Passes(const SimResult &r, const int minTrades)
{
   return r.trades >= minTrades && r.totalR > 0 && ProfitFactor(r) >= InpMinPF;
}

// Evaluate one candidate on the loaded series and update the search state.
void Consider(const Config &c, const int split, const double spread)
{
   s_tested++;
   SimResult rIs, rOos;
   ZeroMemory(rIs);
   ZeroMemory(rOos);
   Simulate(c, 0, split, spread, rIs);

   bool isCurrent = haveConfig && SameConfig(c, cur);
   if(isCurrent)
   {
      Simulate(c, split, g_n, spread, rOos);
      s_curIS = rIs;
      s_curOOS = rOos;
      s_curEvaluated = true;
   }
   // Must clear the bar on the tuning part...
   if(!Passes(rIs, InpMinTrades))
      return;
   if(!isCurrent)
      Simulate(c, split, g_n, spread, rOos);
   // ...and on the recent part it was not tuned on.
   if(!Passes(rOos, MathMax(3, InpMinTrades / 3)))
      return;
   if(!s_found || rIs.totalR > s_bestIS.totalR)
   {
      s_best = c;
      s_bestIS = rIs;
      s_bestOOS = rOos;
      s_found = true;
   }
}

//+------------------------------------------------------------------+
//| Re-tune: search all strategies, validate, decide.                |
//| Returns false when no price history could be loaded.             |
//+------------------------------------------------------------------+
bool Retune()
{
   ENUM_TIMEFRAMES tfs[];
   int ntf = 0;
   if(InpUseM1)  { ArrayResize(tfs, ntf + 1); tfs[ntf++] = PERIOD_M1; }
   if(InpUseM5)  { ArrayResize(tfs, ntf + 1); tfs[ntf++] = PERIOD_M5; }
   if(InpUseM15) { ArrayResize(tfs, ntf + 1); tfs[ntf++] = PERIOD_M15; }

   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;

   s_found = false;
   s_curEvaluated = false;
   s_tested = 0;
   ZeroMemory(s_best);
   ResetResult(s_bestIS);
   ResetResult(s_bestOOS);
   ResetResult(s_curIS);
   ResetResult(s_curOOS);
   bool loadedAny = false;

   for(int t = 0; t < ntf; t++)
   {
      int barsPerDay = 86400 / PeriodSeconds(tfs[t]);
      int want       = InpLookbackDays * barsPerDay + 100;
      if(!LoadSeries(tfs[t], want, 300))
      {
         PrintFormat("Re-tune: not enough %s history yet (error %d)", TfName(tfs[t]), GetLastError());
         continue;
      }
      loadedAny = true;
      int split = (int)(g_n * (1.0 - InpValidationShare));

      Config c;
      ZeroMemory(c);
      c.tf = tfs[t];
      for(int s = 0; s < ArraySize(SlList); s++)
         for(int k = 0; k < ArraySize(TpList); k++)
         {
            c.slMult = SlList[s];
            c.tpMult = TpList[k];

            if(InpUseTrend)
            {
               c.strat = STRAT_TREND;
               c.p3 = 0;
               for(int a = 0; a < ArraySize(FastList); a++)
                  for(int b = 0; b < ArraySize(SlowList); b++)
                  {
                     if(FastList[a] >= SlowList[b])
                        continue;
                     c.p1 = FastList[a];
                     c.p2 = SlowList[b];
                     Consider(c, split, spread);
                  }
            }
            if(InpUseMeanRev)
            {
               c.strat = STRAT_MEANREV;
               for(int a = 0; a < ArraySize(BandList); a++)
                  for(int b = 0; b < ArraySize(BandKList); b++)
                     for(int d = 0; d < ArraySize(RsiLowList); d++)
                     {
                        c.p1 = BandList[a];
                        c.p3 = BandKList[b];
                        c.p2 = RsiLowList[d];
                        Consider(c, split, spread);
                     }
            }
            if(InpUseBreakout)
            {
               c.strat = STRAT_BREAKOUT;
               c.p2 = 0;
               c.p3 = 0;
               for(int a = 0; a < ArraySize(RangeList); a++)
               {
                  c.p1 = RangeList[a];
                  Consider(c, split, spread);
               }
            }
         }
   }

   if(!loadedAny)
      return false;

   lastRetune = TimeCurrent();
   if(s_curEvaluated)
   {
      curIS = s_curIS;
      curOOS = s_curOOS;
   }

   if(!s_found)
   {
      lastRetuneNote = StringFormat("%d settings tested, none with PF >= %.2f after costs", s_tested, InpMinPF);
      if(InpPauseIfNoEdge && !paused)
         Notify(lastRetuneNote + " -> PAUSED new trades until the next re-tune");
      else
         Print(lastRetuneNote);
      paused = InpPauseIfNoEdge;
      return true;
   }

   bool wasPaused = paused;
   paused = false;

   bool switchIt = !haveConfig || wasPaused;
   if(!switchIt && !SameConfig(s_best, cur))
   {
      // Switch if the current setting no longer clears the bar, or the new one is clearly better.
      if(!s_curEvaluated || !Passes(curOOS, MathMax(3, InpMinTrades / 3)) ||
         s_bestOOS.totalR >= curOOS.totalR + InpSwitchMarginR)
         switchIt = true;
   }

   // !haveConfig: always adopt -- MT5 keeps globals (incl. cur) across re-inits,
   // so the best setting can equal a stale cur while nothing is active yet.
   if(switchIt && (!haveConfig || !SameConfig(s_best, cur)))
   {
      string prevText = haveConfig ? ConfigText(cur) : "none";
      cur = s_best;
      haveConfig = true;
      curIS = s_bestIS;
      curOOS = s_bestOOS;
      lastBarTime = iTime(_Symbol, cur.tf, 0); // act only on signals after the switch
      lastRetuneNote = "switched to " + ConfigText(cur);
      Notify(StringFormat("Re-tuned (%d settings): %s -> %s | tuning %+.1fR %d trades PF %.2f | validation %+.1fR %d trades PF %.2f",
                          s_tested, prevText, ConfigText(cur), curIS.totalR, curIS.trades, ProfitFactor(curIS),
                          curOOS.totalR, curOOS.trades, ProfitFactor(curOOS)));
   }
   else
   {
      if(switchIt) // was paused and the best is the current setting: resume
      {
         curIS = s_bestIS;
         curOOS = s_bestOOS;
      }
      lastRetuneNote = "kept " + ConfigText(cur);
      if(wasPaused)
         Notify("Re-tuned: edge found again, RESUMED with " + ConfigText(cur));
      else
         PrintFormat("Re-tuned (%d settings): keeping %s (validation %+.1fR, best alternative %+.1fR)",
                     s_tested, ConfigText(cur), curOOS.totalR, s_bestOOS.totalR);
   }
   return true;
}

//+------------------------------------------------------------------+
//| Trading helpers                                                  |
//+------------------------------------------------------------------+
bool IsOurs(const ulong ticket)
{
   return ticket != 0 &&
          PositionGetString(POSITION_SYMBOL) == _Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic;
}

int CountPositions(const ENUM_POSITION_TYPE type)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i); // also selects the position
      if(IsOurs(ticket) && (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         n++;
   }
   return n;
}

void CloseAll(const ENUM_POSITION_TYPE type, const string why)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurs(ticket) || (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(trade.PositionClose(ticket))
         Notify(StringFormat("closed %s #%I64u (%s), P/L %.2f %s",
                             type == POSITION_TYPE_BUY ? "BUY" : "SELL", ticket, why, profit,
                             AccountInfoString(ACCOUNT_CURRENCY)));
      else
         PrintFormat("Close #%I64u failed: %u %s", ticket, trade.ResultRetcode(),
                     trade.ResultRetcodeDescription());
   }
}

int VolumeDigits(double step)
{
   int d = 0;
   while(step < 0.999999 && d < 8)
   {
      step *= 10.0;
      d++;
   }
   return d;
}

//--- Lot size so that hitting the stop loses InpRiskPercent of balance. 0 = can't trade.
double CalcLots(const double stopDistance)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0 || stopDistance <= 0)
      return 0;

   double lossPerLot = stopDistance / tickSize * tickValue;
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double lots = MathFloor(riskMoney / lossPerLot / step + 1e-9) * step;
   if(lots < minLot)
   {
      // Never round UP to the minimum lot: that would risk more than asked.
      PrintFormat("Skip: risking %.2f allows %.4f lots, below the minimum %.2f (min lot would risk %.2f)",
                  riskMoney, riskMoney / lossPerLot, minLot, minLot * lossPerLot);
      return 0;
   }
   return NormalizeDouble(MathMin(lots, maxLot), VolumeDigits(step));
}

double NormPrice(const double price)
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick > 0)
      return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
   return NormalizeDouble(price, _Digits);
}

void OpenPosition(const ENUM_ORDER_TYPE type, const double atr)
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(InpMaxSpreadPoints > 0 && spread > InpMaxSpreadPoints)
   {
      PrintFormat("Skip entry: spread %I64d points > limit %d", spread, InpMaxSpreadPoints);
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   bool   isBuy = (type == ORDER_TYPE_BUY);
   double price = isBuy ? tick.ask : tick.bid;

   double minStop = (double)(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 1) * _Point;
   double slDist  = MathMax(atr * cur.slMult, minStop);
   double tpDist  = cur.tpMult > 0 ? MathMax(atr * cur.tpMult, minStop) : 0;
   double sl      = NormPrice(isBuy ? price - slDist : price + slDist);
   double tp      = tpDist > 0 ? NormPrice(isBuy ? price + tpDist : price - tpDist) : 0;

   double lots = CalcLots(slDist);
   if(lots <= 0)
      return;

   double margin = 0;
   if(!OrderCalcMargin(type, _Symbol, lots, price, margin) ||
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      PrintFormat("Skip entry: margin %.2f needed, free margin %.2f", margin,
                  AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      return;
   }

   bool sent = isBuy ? trade.Buy(lots, _Symbol, price, sl, tp, "BtcAdaptive")
                     : trade.Sell(lots, _Symbol, price, sl, tp, "BtcAdaptive");
   uint rc = trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
      Notify(StringFormat("%s %.2f lots @ %s, SL %s, TP %s [%s]", isBuy ? "BUY" : "SELL", lots,
                          DoubleToString(trade.ResultPrice(), _Digits), DoubleToString(sl, _Digits),
                          tp > 0 ? DoubleToString(tp, _Digits) : "none", ConfigText(cur)));
   else
      Notify(StringFormat("%s order FAILED: %u %s", isBuy ? "BUY" : "SELL", rc,
                          trade.ResultRetcodeDescription()));
}

void ShowStatus()
{
   string setting = haveConfig ? ConfigText(cur) : "none yet";
   string state   = !haveConfig ? (paused ? "PAUSED (no edge after costs)" : "waiting for first tune")
                                : (paused ? "PAUSED (no edge after costs)" : "running");
   Comment(StringFormat("BtcAdaptiveEA 2.01  %s  %s\nSetting: %s\nLast re-tune: %s (%s)\nTuning %+.1fR %d tr PF %.2f | Validation %+.1fR %d tr PF %.2f | min PF %.2f\nNext re-tune: %s\nBalance %.2f  Equity %.2f  Long %d  Short %d",
                        _Symbol, state, setting,
                        lastRetune > 0 ? TimeToString(lastRetune, TIME_DATE | TIME_MINUTES) : "-", lastRetuneNote,
                        curIS.totalR, curIS.trades, ProfitFactor(curIS),
                        curOOS.totalR, curOOS.trades, ProfitFactor(curOOS), InpMinPF,
                        nextRetune > 0 ? TimeToString(nextRetune, TIME_DATE | TIME_MINUTES) : "-",
                        AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY),
                        CountPositions(POSITION_TYPE_BUY), CountPositions(POSITION_TYPE_SELL)));
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringFind(_Symbol, "BTC") < 0)
   {
      Alert("BtcAdaptiveEA is built for Bitcoin only. Attach it to a BTC chart such as BTCUSDm.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!InpUseM1 && !InpUseM5 && !InpUseM15)
   {
      Print("Enable at least one candidate timeframe");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!InpUseTrend && !InpUseMeanRev && !InpUseBreakout)
   {
      Print("Enable at least one strategy");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpValidationShare < 0.1 || InpValidationShare > 0.5 || InpLookbackDays < 1 || InpRetuneHours < 1)
   {
      Print("Check InpValidationShare (0.1-0.5), InpLookbackDays (>=1) and InpRetuneHours (>=1)");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpRiskPercent <= 0 || InpRiskPercent > 5)
   {
      Print("InpRiskPercent must be between 0 and 5");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!MQLInfoInteger(MQL_TESTER) && !InpAllowRealAccount &&
      AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
   {
      Alert("BtcAdaptiveEA: this is NOT a demo account. Set InpAllowRealAccount = true only when you accept real losses.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Globals survive re-inits (timeframe or input changes), so reset all state explicitly.
   ZeroMemory(cur);
   ResetResult(curIS);
   ResetResult(curOOS);
   lastBarTime    = 0;
   lastRetune     = 0;
   lastRetuneNote = "not tuned yet";
   haveConfig = false;
   paused     = false;
   nextRetune = 0; // first tune on the first tick, once history is available

   Notify(StringFormat("v2.0 started on %s account %I64d (%s), risk %.1f%%/trade, re-tune every %dh on %d days, min PF %.2f, NO daily loss limit",
                       AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "DEMO" : "REAL",
                       AccountInfoInteger(ACCOUNT_LOGIN), AccountInfoString(ACCOUNT_SERVER),
                       InpRiskPercent, InpRetuneHours, InpLookbackDays, InpMinPF));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
}

//--- True if the position was opened by this EA on this symbol (checks its opening deal).
bool PositionWasOurs(const long positionId)
{
   if(!HistorySelectByPosition(positionId))
      return false;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         return HistoryDealGetString(deal, DEAL_SYMBOL) == _Symbol &&
                (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) == InpMagic;
   }
   return false;
}

//--- Report closes done by the broker (stop loss, take profit, stop out).
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal))
      return;

   ENUM_DEAL_ENTRY  entry  = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;
   if(reason != DEAL_REASON_SL && reason != DEAL_REASON_TP && reason != DEAL_REASON_SO)
      return;

   double price  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                   HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                   HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   long   posId  = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(!PositionWasOurs(posId))
      return;

   string what = reason == DEAL_REASON_SL ? "STOP LOSS" : reason == DEAL_REASON_TP ? "TAKE PROFIT" : "STOP OUT";
   Notify(StringFormat("%s hit, closed @ %s, P/L %.2f %s", what, DoubleToString(price, _Digits), profit,
                       AccountInfoString(ACCOUNT_CURRENCY)));
}

void OnTick()
{
   if(TimeCurrent() >= nextRetune)
   {
      if(Retune())
         nextRetune = TimeCurrent() + InpRetuneHours * 3600;
      else
         nextRetune = TimeCurrent() + 300; // history still loading: try again in 5 minutes
   }
   ShowStatus();
   if(!haveConfig)
      return;

   // Decide once per new bar of the chosen timeframe, on closed bars only.
   datetime barTime = iTime(_Symbol, cur.tf, 0);
   if(barTime == 0 || barTime == lastBarTime)
      return;
   int warm = Warmup(cur);
   if(!LoadSeries(cur.tf, warm + 10, warm + 2))
      return; // data not ready yet; try again on the next tick
   lastBarTime = barTime;

   int i = g_n - 1; // last closed bar
   int x = EntrySignal(i, cur);

   // Exits: strategy exit signal, or an entry signal in the opposite direction
   if(CountPositions(POSITION_TYPE_BUY) > 0 && (ExitSignal(i, cur, 1) || x < 0))
      CloseAll(POSITION_TYPE_BUY, x < 0 ? "opposite signal" : "back at the mean");
   if(CountPositions(POSITION_TYPE_SELL) > 0 && (ExitSignal(i, cur, -1) || x > 0))
      CloseAll(POSITION_TYPE_SELL, x > 0 ? "opposite signal" : "back at the mean");

   if(paused || x == 0)
      return; // no edge right now, or no entry signal

   double atr = AtrAt(i, InpAtrPeriod);
   if(x > 0 && CountPositions(POSITION_TYPE_BUY) == 0)
      OpenPosition(ORDER_TYPE_BUY, atr);
   else if(x < 0 && InpAllowShort && CountPositions(POSITION_TYPE_SELL) == 0)
      OpenPosition(ORDER_TYPE_SELL, atr);
}
//+------------------------------------------------------------------+
