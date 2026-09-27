//+------------------------------------------------------------------+
//|                                                   SmaCrossEA.mq5 |
//|  Moving-average crossover with ATR stops, %-risk position sizing,|
//|  a daily loss limit and iPhone push alerts.                      |
//|                                                                  |
//|  An example for learning on a DEMO account -- not a profitable   |
//|  strategy. Leveraged CFDs can lose money very quickly.           |
//+------------------------------------------------------------------+
#property copyright "thaitrader"
#property version   "1.01"
#property description "SMA crossover with ATR stop-loss/take-profit, % risk sizing and a daily loss limit."
#property description "Refuses to run on a real account unless InpAllowRealAccount = true."

#include <Trade\Trade.mqh>

input group "Strategy"
input ENUM_TIMEFRAMES InpTimeframe  = PERIOD_H1; // Timeframe for signals
input int             InpFastPeriod = 10;        // Fast SMA period
input int             InpSlowPeriod = 30;        // Slow SMA period
input bool            InpAllowShort = true;      // Also trade short (sell) signals

input group "Risk"
input double InpRiskPercent       = 1.0;  // % of balance lost if the stop loss is hit
input int    InpAtrPeriod         = 14;   // ATR period for stop distance
input double InpStopAtrMult       = 2.0;  // Stop loss = ATR x this
input double InpTakeProfitAtrMult = 3.0;  // Take profit = ATR x this (0 = none)
input double InpMaxDailyLossPct   = 3.0;  // Close all and stop for the day after this % equity drop (0 = off)
input int    InpMaxSpreadPoints   = 50;   // Skip entries when spread is wider, in points (0 = no limit)

input group "Safety and alerts"
input bool   InpAllowRealAccount = false;    // Allow trading on a REAL account
input bool   InpPushAlerts       = true;     // Send push notifications to the MT5 phone app
input ulong  InpMagic            = 20260927; // Magic number (identifies this EA's positions)

CTrade   trade;
int      hFast = INVALID_HANDLE;
int      hSlow = INVALID_HANDLE;
int      hAtr  = INVALID_HANDLE;
datetime lastBarTime = 0;

//--- Daily-loss state lives in terminal global variables so it survives restarts.
string GvName(const string what)
{
   return "SCE_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + _Symbol + "_" +
          IntegerToString((long)InpMagic) + "_" + what;
}

datetime DayStart(const datetime t)
{
   return (datetime)((long)t - (long)t % 86400);
}

void Notify(const string text)
{
   string msg = "SmaCrossEA " + _Symbol + ": " + text;
   Print(msg);
   if(InpPushAlerts && !MQLInfoInteger(MQL_TESTER) && TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      SendNotification(msg);
}

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
         Notify(StringFormat("closed %s #%I64u, P/L %.2f %s",
                             type == POSITION_TYPE_BUY ? "BUY" : "SELL", ticket, profit,
                             AccountInfoString(ACCOUNT_CURRENCY)));
      else
         PrintFormat("Close #%I64u failed: %u %s", ticket, trade.ResultRetcode(),
                     trade.ResultRetcodeDescription());
   }
}

//--- Returns true when trading is halted for the rest of the (server) day.
bool UpdateDailyState()
{
   datetime today  = DayStart(TimeCurrent());
   double   equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(!GlobalVariableCheck(GvName("day")) || (datetime)(long)GlobalVariableGet(GvName("day")) != today)
   {
      GlobalVariableSet(GvName("day"), (double)today);
      GlobalVariableSet(GvName("equity"), equity);
      GlobalVariableSet(GvName("halted"), 0);
      PrintFormat("New trading day %s, start equity %.2f", TimeToString(today, TIME_DATE), equity);
   }

   if(GlobalVariableGet(GvName("halted")) > 0)
      return true;

   double start = GlobalVariableGet(GvName("equity"));
   if(InpMaxDailyLossPct > 0 && equity <= start * (1.0 - InpMaxDailyLossPct / 100.0))
   {
      GlobalVariableSet(GvName("halted"), 1);
      CloseAll(POSITION_TYPE_BUY);
      CloseAll(POSITION_TYPE_SELL);
      Notify(StringFormat("DAILY LOSS LIMIT hit (equity %.2f, day start %.2f). Trading stopped until tomorrow.",
                          equity, start));
      return true;
   }
   return false;
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

   // Broker's minimum stop distance, plus one point of headroom.
   double minStop = (double)(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 1) * _Point;
   double slDist  = MathMax(atr * InpStopAtrMult, minStop);
   double tpDist  = InpTakeProfitAtrMult > 0 ? MathMax(atr * InpTakeProfitAtrMult, minStop) : 0;
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

   bool sent = isBuy ? trade.Buy(lots, _Symbol, price, sl, tp, "SmaCrossEA")
                     : trade.Sell(lots, _Symbol, price, sl, tp, "SmaCrossEA");
   uint rc = trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
      Notify(StringFormat("%s %.2f lots @ %s, SL %s, TP %s", isBuy ? "BUY" : "SELL", lots,
                          DoubleToString(trade.ResultPrice(), _Digits), DoubleToString(sl, _Digits),
                          tp > 0 ? DoubleToString(tp, _Digits) : "none"));
   else
      Notify(StringFormat("%s order FAILED: %u %s", isBuy ? "BUY" : "SELL", rc,
                          trade.ResultRetcodeDescription()));
}

void ShowStatus(const bool halted)
{
   Comment(StringFormat("SmaCrossEA  %s %s  SMA %d/%d\nDay start equity: %.2f   Equity: %.2f\nLong: %d  Short: %d  %s",
                        _Symbol, EnumToString(InpTimeframe), InpFastPeriod, InpSlowPeriod,
                        GlobalVariableGet(GvName("equity")), AccountInfoDouble(ACCOUNT_EQUITY),
                        CountPositions(POSITION_TYPE_BUY), CountPositions(POSITION_TYPE_SELL),
                        halted ? "HALTED (daily loss limit)" : "running"));
}

int OnInit()
{
   if(InpFastPeriod <= 0 || InpFastPeriod >= InpSlowPeriod)
   {
      Print("Fast period must be > 0 and smaller than the slow period");
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
      Alert("SmaCrossEA: this is NOT a demo account. Set InpAllowRealAccount = true only when you accept real losses.");
      return INIT_FAILED;
   }

   hFast = iMA(_Symbol, InpTimeframe, InpFastPeriod, 0, MODE_SMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, InpTimeframe, InpSlowPeriod, 0, MODE_SMA, PRICE_CLOSE);
   hAtr  = iATR(_Symbol, InpTimeframe, InpAtrPeriod);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hAtr == INVALID_HANDLE)
   {
      Print("Failed to create indicators: ", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Act only on crossovers that happen after the EA starts, not on an old one.
   lastBarTime = iTime(_Symbol, InpTimeframe, 0);

   Notify(StringFormat("started on %s account %I64d (%s), risk %.1f%%/trade, daily loss limit %.1f%%",
                       AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "DEMO" : "REAL",
                       AccountInfoInteger(ACCOUNT_LOGIN), AccountInfoString(ACCOUNT_SERVER),
                       InpRiskPercent, InpMaxDailyLossPct));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hFast);
   IndicatorRelease(hSlow);
   IndicatorRelease(hAtr);
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
//--- Closes done by the EA itself are already reported in CloseAll().
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
   bool halted = UpdateDailyState();
   ShowStatus(halted);
   if(halted)
      return;

   // Decide once per new bar, using the last two CLOSED bars (no repainting).
   datetime barTime = iTime(_Symbol, InpTimeframe, 0);
   if(barTime == 0 || barTime == lastBarTime)
      return;

   // Static arrays: element 0 = older bar (shift 2), element 1 = last closed bar (shift 1).
   double fast[2], slow[2], atr[1];
   if(CopyBuffer(hFast, 0, 1, 2, fast) != 2 ||
      CopyBuffer(hSlow, 0, 1, 2, slow) != 2 ||
      CopyBuffer(hAtr,  0, 1, 1, atr)  != 1)
      return; // data not ready yet; try again on the next tick
   lastBarTime = barTime;

   bool crossUp   = fast[0] <= slow[0] && fast[1] > slow[1];
   bool crossDown = fast[0] >= slow[0] && fast[1] < slow[1];

   if(crossUp)
   {
      CloseAll(POSITION_TYPE_SELL);
      if(CountPositions(POSITION_TYPE_BUY) == 0)
         OpenPosition(ORDER_TYPE_BUY, atr[0]);
   }
   else if(crossDown)
   {
      CloseAll(POSITION_TYPE_BUY);
      if(InpAllowShort && CountPositions(POSITION_TYPE_SELL) == 0)
         OpenPosition(ORDER_TYPE_SELL, atr[0]);
   }
}
//+------------------------------------------------------------------+
