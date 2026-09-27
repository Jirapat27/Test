//+------------------------------------------------------------------+
//|                                                BtcAdaptiveEA.mq5 |
//|  BTC-only moving-average crossover bot that re-tunes itself.     |
//|                                                                  |
//|  Every few hours it backtests a grid of settings (timeframe,     |
//|  SMA periods, stop and target size) on recent BTC prices,        |
//|  including the current spread. It picks the best setting on the  |
//|  older part of the data, checks it on the most recent part it    |
//|  did not tune on, and only switches when the new setting is      |
//|  clearly better. When nothing is profitable after costs it stops |
//|  opening trades until the next re-tune.                          |
//|                                                                  |
//|  For learning on a DEMO account -- adaptation does not guarantee |
//|  profits. There is NO daily loss limit in this bot.              |
//+------------------------------------------------------------------+
#property copyright "thaitrader"
#property version   "1.00"
#property description "BTC-only SMA crossover that re-tunes itself on recent data (incl. spread),"
#property description "validates on unseen data, switches only when clearly better, pauses when nothing works."
#property description "Per-trade stop loss and % risk sizing. No daily loss limit. Demo-only unless allowed."

#include <Trade\Trade.mqh>

input group "Self-tuning"
input int    InpRetuneHours     = 6;     // Re-tune every N hours
input int    InpLookbackDays    = 7;     // Days of recent history used for tuning
input double InpValidationShare = 0.33;  // Most recent share of the lookback kept for validation (0.1-0.5)
input int    InpMinTrades       = 15;    // Minimum trades in the tuning part for a setting to count
input double InpSwitchMarginR   = 1.0;   // New setting must beat the current one by this many R (validation)
input bool   InpPauseIfNoEdge   = true;  // Stop opening trades when no setting is profitable after costs
input bool   InpUseM1           = true;  // Candidate timeframe: M1
input bool   InpUseM5           = true;  // Candidate timeframe: M5
input bool   InpUseM15          = true;  // Candidate timeframe: M15

input group "Risk"
input double InpRiskPercent     = 1.0;   // % of balance lost if the stop loss is hit
input int    InpAtrPeriod       = 14;    // ATR period for stop/target distance
input int    InpMaxSpreadPoints = 2000;  // Skip entries when spread is wider, in points (0 = no limit)
input bool   InpAllowShort      = true;  // Also trade short (sell) signals

input group "Safety and alerts"
input bool   InpAllowRealAccount = false;    // Allow trading on a REAL account
input bool   InpPushAlerts       = true;     // Send push notifications to the MT5 phone app
input ulong  InpMagic            = 20260929; // Magic number (identifies this EA's positions)

//--- Candidate grid
int    FastList[] = {5, 8, 10, 12, 20};
int    SlowList[] = {20, 21, 30, 48, 60};
double SlList[]   = {1.5, 2.0, 3.0};      // stop loss = ATR x this
double TpList[]   = {0.0, 2.0, 3.0};      // take profit = ATR x this (0 = exit on opposite cross only)

struct Config
{
   ENUM_TIMEFRAMES tf;
   int             fast;
   int             slow;
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

//--- Price series of one timeframe (closed bars, oldest first) + prefix sums
double g_open[], g_high[], g_low[], g_close[], g_cumClose[], g_cumTR[];
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
   return StringFormat("%s SMA %d/%d SL %.1fxATR TP %s", TfName(c.tf), c.fast, c.slow, c.slMult,
                       c.tpMult > 0 ? StringFormat("%.1fxATR", c.tpMult) : "on cross");
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

   g_n = got;
   ArrayResize(g_open, got);
   ArrayResize(g_high, got);
   ArrayResize(g_low, got);
   ArrayResize(g_close, got);
   ArrayResize(g_cumClose, got + 1);
   ArrayResize(g_cumTR, got + 1);
   g_cumClose[0] = 0;
   g_cumTR[0]    = 0;
   for(int i = 0; i < got; i++)
   {
      g_open[i]  = r[i].open;
      g_high[i]  = r[i].high;
      g_low[i]   = r[i].low;
      g_close[i] = r[i].close;
      double tr = r[i].high - r[i].low;
      if(i > 0)
         tr = MathMax(tr, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      g_cumClose[i + 1] = g_cumClose[i] + r[i].close;
      g_cumTR[i + 1]    = g_cumTR[i] + tr;
   }
   return true;
}

// Mean of close[i-p+1 .. i]
double SmaAt(const int i, const int p)
{
   return (g_cumClose[i + 1] - g_cumClose[i + 1 - p]) / p;
}

// Simple average true range over bars i-p+1 .. i
double AtrAt(const int i, const int p)
{
   return (g_cumTR[i + 1] - g_cumTR[i + 1 - p]) / p;
}

// +1 = fast crossed above slow at the close of bar i, -1 = crossed below, 0 = no cross. Needs i >= slow.
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

//+------------------------------------------------------------------+
//| Backtest one setting on bars [from, to) of the loaded series.    |
//| Same rules as live: decide on a bar's close, enter at the next   |
//| open, SL/TP from ATR, exit on opposite cross. Buys pay the       |
//| spread on entry, sells pay it on exit. If SL and TP are both     |
//| touched in one bar, the stop is assumed to hit first.            |
//+------------------------------------------------------------------+
void Simulate(const Config &c, const int iFrom, const int iTo, const double spread, SimResult &res)
{
   ResetResult(res);
   int    pos = 0;
   double entry = 0, sl = 0, tp = 0, risk = 0;
   int    start = MathMax(iFrom, MathMax(c.slow, InpAtrPeriod) + 1);

   for(int i = start; i < iTo; i++)
   {
      // 1) Manage the open position during bar i
      if(pos > 0)
      {
         if(g_low[i] <= sl)                     { Book(res, (sl - entry) / risk); pos = 0; }
         else if(tp > 0 && g_high[i] >= tp)     { Book(res, (tp - entry) / risk); pos = 0; }
      }
      else if(pos < 0)
      {
         if(g_high[i] + spread >= sl)           { Book(res, (entry - sl) / risk); pos = 0; }
         else if(tp > 0 && g_low[i] + spread <= tp) { Book(res, (entry - tp) / risk); pos = 0; }
      }

      // 2) Signal at the close of bar i -> act at the open of bar i+1
      if(i + 1 >= iTo)
         break;
      int x = CrossAt(i, c.fast, c.slow);
      if(x == 0)
         continue;
      double nextOpen = g_open[i + 1];

      if(pos != 0 && x != pos)
      {
         double exitPx = pos > 0 ? nextOpen : nextOpen + spread;
         Book(res, pos > 0 ? (exitPx - entry) / risk : (entry - exitPx) / risk);
         pos = 0;
      }
      if(pos == 0 && (x > 0 || InpAllowShort))
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
   return a.tf == b.tf && a.fast == b.fast && a.slow == b.slow &&
          MathAbs(a.slMult - b.slMult) < 1e-9 && MathAbs(a.tpMult - b.tpMult) < 1e-9;
}

//+------------------------------------------------------------------+
//| Re-tune: search the grid, validate, decide whether to switch.    |
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
   int    minOOS = MathMax(3, InpMinTrades / 3);

   bool      loadedAny = false, found = false, curEvaluated = false;
   Config    best;
   SimResult bestIS, bestOOS, curOOSNow, curISNow;
   ZeroMemory(best);
   ResetResult(bestIS);
   ResetResult(bestOOS);
   ResetResult(curOOSNow);
   ResetResult(curISNow);
   int tested = 0;

   for(int t = 0; t < ntf; t++)
   {
      int barsPerDay = 86400 / PeriodSeconds(tfs[t]);
      int want       = InpLookbackDays * barsPerDay + 100;
      if(!LoadSeries(tfs[t], want, 300))
      {
         PrintFormat("Re-tune: not enough %s history yet (%d error)", TfName(tfs[t]), GetLastError());
         continue;
      }
      loadedAny = true;
      int split = (int)(g_n * (1.0 - InpValidationShare));

      for(int a = 0; a < ArraySize(FastList); a++)
         for(int b = 0; b < ArraySize(SlowList); b++)
         {
            if(FastList[a] >= SlowList[b])
               continue;
            for(int s = 0; s < ArraySize(SlList); s++)
               for(int k = 0; k < ArraySize(TpList); k++)
               {
                  Config c;
                  c.tf = tfs[t];
                  c.fast = FastList[a];
                  c.slow = SlowList[b];
                  c.slMult = SlList[s];
                  c.tpMult = TpList[k];
                  tested++;

                  SimResult rIs, rOos;
                  ZeroMemory(rIs);
                  ZeroMemory(rOos);
                  Simulate(c, 0, split, spread, rIs);
                  bool isCurrent = haveConfig && SameConfig(c, cur);
                  if(isCurrent)
                  {
                     Simulate(c, split, g_n, spread, rOos);
                     curISNow = rIs;
                     curOOSNow = rOos;
                     curEvaluated = true;
                  }
                  // Must be profitable, with enough trades, on the tuning part...
                  if(rIs.trades < InpMinTrades || rIs.totalR <= 0 || ProfitFactor(rIs) <= 1.0)
                     continue;
                  if(!isCurrent)
                     Simulate(c, split, g_n, spread, rOos);
                  // ...and still profitable on the recent part it was not tuned on.
                  if(rOos.trades < minOOS || rOos.totalR <= 0 || ProfitFactor(rOos) <= 1.0)
                     continue;
                  if(!found || rIs.totalR > bestIS.totalR)
                  {
                     best = c;
                     bestIS = rIs;
                     bestOOS = rOos;
                     found = true;
                  }
               }
         }
   }

   if(!loadedAny)
      return false;

   lastRetune = TimeCurrent();
   if(curEvaluated)
   {
      curIS = curISNow;
      curOOS = curOOSNow;
   }

   if(!found)
   {
      lastRetuneNote = StringFormat("%d settings tested, none profitable after costs", tested);
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
   if(!switchIt && !SameConfig(best, cur))
   {
      // Switch if the current setting now loses on recent data, or the new one is clearly better.
      if(!curEvaluated || curOOS.totalR <= 0 || bestOOS.totalR >= curOOS.totalR + InpSwitchMarginR)
         switchIt = true;
   }

   if(switchIt && !SameConfig(best, cur))
   {
      string prevText = haveConfig ? ConfigText(cur) : "none";
      cur = best;
      haveConfig = true;
      curIS = bestIS;
      curOOS = bestOOS;
      lastBarTime = iTime(_Symbol, cur.tf, 0); // act only on crosses after the switch
      lastRetuneNote = StringFormat("switched to %s", ConfigText(cur));
      Notify(StringFormat("Re-tuned (%d settings): %s -> %s | tuning %+.1fR %d trades PF %.2f | validation %+.1fR %d trades PF %.2f",
                          tested, prevText, ConfigText(cur), curIS.totalR, curIS.trades, ProfitFactor(curIS),
                          curOOS.totalR, curOOS.trades, ProfitFactor(curOOS)));
   }
   else
   {
      if(switchIt) // was paused, best == current: resume
      {
         curIS = bestIS;
         curOOS = bestOOS;
      }
      lastRetuneNote = StringFormat("kept %s", ConfigText(cur));
      if(wasPaused)
         Notify("Re-tuned: edge found again, RESUMED with " + ConfigText(cur));
      else
         PrintFormat("Re-tuned (%d settings): keeping %s (validation %+.1fR, best alternative %+.1fR)",
                     tested, ConfigText(cur), curOOS.totalR, bestOOS.totalR);
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

void CloseAll(const ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurs(ticket) || (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(trade.PositionClose(ticket))
         Notify(StringFormat("closed %s #%I64u on opposite cross, P/L %.2f %s",
                             type == POSITION_TYPE_BUY ? "BUY" : "SELL", ticket, profit,
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
   string state   = !haveConfig ? "waiting for first tune" : (paused ? "PAUSED (no edge after costs)" : "running");
   Comment(StringFormat("BtcAdaptiveEA  %s  %s\nSetting: %s\nLast re-tune: %s (%s)\nTuning %+.1fR %d tr PF %.2f | Validation %+.1fR %d tr PF %.2f\nNext re-tune: %s\nBalance %.2f  Equity %.2f  Long %d  Short %d",
                        _Symbol, state, setting,
                        lastRetune > 0 ? TimeToString(lastRetune, TIME_DATE | TIME_MINUTES) : "-", lastRetuneNote,
                        curIS.totalR, curIS.trades, ProfitFactor(curIS),
                        curOOS.totalR, curOOS.trades, ProfitFactor(curOOS),
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

   ResetResult(curIS);
   ResetResult(curOOS);
   haveConfig = false;
   paused     = false;
   nextRetune = 0; // first tune on the first tick, once history is available

   Notify(StringFormat("started on %s account %I64d (%s), risk %.1f%%/trade, re-tune every %dh on %d days, NO daily loss limit",
                       AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "DEMO" : "REAL",
                       AccountInfoInteger(ACCOUNT_LOGIN), AccountInfoString(ACCOUNT_SERVER),
                       InpRiskPercent, InpRetuneHours, InpLookbackDays));
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
   int need = MathMax(cur.slow, InpAtrPeriod) + 5;
   if(!LoadSeries(cur.tf, need, cur.slow + 2))
      return; // data not ready yet; try again on the next tick
   lastBarTime = barTime;

   int i = g_n - 1; // last closed bar
   int x = CrossAt(i, cur.fast, cur.slow);
   if(x == 0)
      return;

   if(x > 0)
      CloseAll(POSITION_TYPE_SELL);
   else
      CloseAll(POSITION_TYPE_BUY);

   if(paused)
      return; // no edge right now: exits only, no new trades

   double atr = AtrAt(i, InpAtrPeriod);
   if(x > 0 && CountPositions(POSITION_TYPE_BUY) == 0)
      OpenPosition(ORDER_TYPE_BUY, atr);
   else if(x < 0 && InpAllowShort && CountPositions(POSITION_TYPE_SELL) == 0)
      OpenPosition(ORDER_TYPE_SELL, atr);
}
//+------------------------------------------------------------------+
