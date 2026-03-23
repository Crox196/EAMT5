//+------------------------------------------------------------------+
//|                                          SmartGridRecovery.mq5   |
//|                              Smart Grid EA with Recovery System   |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "SmartGrid EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Grid Settings ==="
input int      InpRiskLevel        = 3;       // Risk Level (1=Conservative, 5=Aggressive)
input int      InpATRPeriod        = 14;      // ATR Period for grid calculation
input int      InpMaxGridLevels    = 8;       // Max grid levels (anti-infinite grid)
input double   InpBaseLotSize      = 0.01;    // Base lot size
input double   InpLotMultiplier    = 1.3;     // Lot multiplier per grid level

input group "=== Recovery Settings ==="
input double   InpSurplusPercent   = 10.0;    // Surplus % on each recovery closure (e.g. 10 = 10% extra)
input bool     InpPartialRecovery  = true;    // Close losers one-by-one (true) or all at once (false)

input group "=== Direction & Filter ==="
input ENUM_ORDER_TYPE InpInitialDirection = ORDER_TYPE_BUY; // Initial direction
input bool     InpUseTrendFilter   = true;    // Use EMA trend filter
input int      InpEMAPeriod        = 200;     // EMA period for trend filter
input bool     InpBothDirections   = false;   // Trade both directions (hedge)

input group "=== Risk Management ==="
input double   InpMaxDrawdownPct   = 15.0;    // Max drawdown % to stop trading
input double   InpTakeProfitPips   = 50.0;    // TP pips for initial position (0=disabled)
input int      InpMagicNumber      = 777777;  // Magic number
input string   InpComment          = "SGR";   // Order comment

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;

double         gridSpacingPoints;    // Grid spacing in points
double         pointValue;           // Point value
int            digits;               // Symbol digits
int            atrHandle;            // ATR indicator handle
int            emaHandle;            // EMA indicator handle
datetime       lastBarTime;          // Track new bar
double         lastGridPrice;        // Price of last grid order

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate inputs
   if(InpRiskLevel < 1 || InpRiskLevel > 5)
   {
      Print("Error: Risk Level must be between 1 and 5");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpMaxGridLevels < 2 || InpMaxGridLevels > 20)
   {
      Print("Error: Max grid levels must be between 2 and 20");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Setup trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   // Symbol info
   digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Create ATR handle (Daily timeframe for average daily range)
   atrHandle = iATR(_Symbol, PERIOD_D1, InpATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("Error creating ATR indicator");
      return INIT_FAILED;
   }

   // Create EMA handle
   if(InpUseTrendFilter)
   {
      emaHandle = iMA(_Symbol, PERIOD_H1, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(emaHandle == INVALID_HANDLE)
      {
         Print("Error creating EMA indicator");
         return INIT_FAILED;
      }
   }

   lastBarTime = 0;
   lastGridPrice = 0;
   gridSpacingPoints = 0;

   Print("SmartGrid Recovery EA initialized. Risk Level: ", InpRiskLevel);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   if(InpUseTrendFilter && emaHandle != INVALID_HANDLE)
      IndicatorRelease(emaHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check max drawdown
   if(CheckMaxDrawdown())
      return;

   // Update grid spacing on each new daily bar
   UpdateGridSpacing();

   // Get our positions
   int totalBuy = 0, totalSell = 0;
   double totalBuyProfit = 0, totalSellProfit = 0;
   CountPositions(totalBuy, totalSell, totalBuyProfit, totalSellProfit);

   // === RECOVERY LOGIC (runs every tick for responsiveness) ===
   if(InpBothDirections || InpInitialDirection == ORDER_TYPE_BUY)
      RecoveryCheck(ORDER_TYPE_BUY);
   if(InpBothDirections || InpInitialDirection == ORDER_TYPE_SELL)
      RecoveryCheck(ORDER_TYPE_SELL);

   // === GRID LOGIC (new bar check for grid entries) ===
   if(!IsNewBar(PERIOD_M15))
      return;

   if(gridSpacingPoints <= 0)
      return;

   // Open initial position or add grid levels
   if(InpBothDirections || InpInitialDirection == ORDER_TYPE_BUY)
      ManageGridSide(ORDER_TYPE_BUY, totalBuy);
   if(InpBothDirections || InpInitialDirection == ORDER_TYPE_SELL)
      ManageGridSide(ORDER_TYPE_SELL, totalSell);
}

//+------------------------------------------------------------------+
//| Update grid spacing based on ATR and risk level                   |
//+------------------------------------------------------------------+
void UpdateGridSpacing()
{
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);

   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) <= 0)
      return;

   double dailyATR = atrBuffer[0];

   // Risk level divisor: 1=1x, 2=2x, 3=3x, 4=4x, 5=5x
   // Level 1 (conservative): grid = full daily ATR (~95 pips EURUSD)
   // Level 5 (aggressive): grid = ATR/5 (~19 pips EURUSD)
   double divisor = (double)InpRiskLevel;
   gridSpacingPoints = dailyATR / divisor;

   // Minimum spacing safety: at least 10 pips for major pairs
   double minSpacing = 10.0 * pointValue * (digits == 3 || digits == 5 ? 10 : 1);
   if(gridSpacingPoints < minSpacing)
      gridSpacingPoints = minSpacing;
}

//+------------------------------------------------------------------+
//| Manage grid for one side (BUY or SELL)                            |
//+------------------------------------------------------------------+
void ManageGridSide(ENUM_ORDER_TYPE direction, int currentCount)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (direction == ORDER_TYPE_BUY) ? ask : bid;

   // Trend filter
   if(InpUseTrendFilter && !CheckTrendFilter(direction))
      return;

   // No positions yet: open first
   if(currentCount == 0)
   {
      double lot = InpBaseLotSize;
      OpenPosition(direction, lot, "L1");
      return;
   }

   // Check if we've hit max grid levels
   if(currentCount >= InpMaxGridLevels)
      return;

   // Find the worst (furthest in loss) position on this side
   double worstPrice = 0;
   GetWorstPositionPrice(direction, worstPrice);

   if(worstPrice <= 0)
      return;

   // Calculate distance from worst position to current price
   double distance = 0;
   if(direction == ORDER_TYPE_BUY)
      distance = worstPrice - currentPrice;  // BUY: loss when price drops
   else
      distance = currentPrice - worstPrice;  // SELL: loss when price rises

   // If price moved against us by gridSpacing, open new level
   if(distance >= gridSpacingPoints)
   {
      // Calculate lot with multiplier
      double lot = InpBaseLotSize * MathPow(InpLotMultiplier, currentCount);
      lot = NormalizeLot(lot);

      string levelComment = "L" + IntegerToString(currentCount + 1);
      OpenPosition(direction, lot, levelComment);

      Print("Grid level ", currentCount + 1, " opened. Direction: ",
            (direction == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " Lot: ", DoubleToString(lot, 2),
            " Spacing: ", DoubleToString(gridSpacingPoints / pointValue, 1), " points");
   }
}

//+------------------------------------------------------------------+
//| Recovery: use last profitable trade to close losers               |
//+------------------------------------------------------------------+
void RecoveryCheck(ENUM_ORDER_TYPE direction)
{
   // Collect all positions for this direction
   int count = 0;
   ulong tickets[];
   double profits[];
   double openPrices[];
   double lots[];
   datetime openTimes[];

   ArrayResize(tickets, 0);
   ArrayResize(profits, 0);
   ArrayResize(openPrices, 0);
   ArrayResize(lots, 0);
   ArrayResize(openTimes, 0);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Symbol() != _Symbol)
         continue;
      if(posInfo.Magic() != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE posType = posInfo.PositionType();
      if((direction == ORDER_TYPE_BUY && posType != POSITION_TYPE_BUY) ||
         (direction == ORDER_TYPE_SELL && posType != POSITION_TYPE_SELL))
         continue;

      int idx = count;
      count++;
      ArrayResize(tickets, count);
      ArrayResize(profits, count);
      ArrayResize(openPrices, count);
      ArrayResize(lots, count);
      ArrayResize(openTimes, count);

      tickets[idx]    = posInfo.Ticket();
      profits[idx]    = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
      openPrices[idx] = posInfo.PriceOpen();
      lots[idx]       = posInfo.Volume();
      openTimes[idx]  = posInfo.Time();
   }

   if(count < 2)
      return;

   // Find the newest position (last grid level = recovery trade)
   int newestIdx = 0;
   datetime newestTime = 0;
   for(int i = 0; i < count; i++)
   {
      if(openTimes[i] > newestTime)
      {
         newestTime = openTimes[i];
         newestIdx = i;
      }
   }

   double recoveryProfit = profits[newestIdx];

   // Recovery trade must be in profit
   if(recoveryProfit <= 0)
      return;

   // Find losing positions sorted by smallest loss first (easiest to recover)
   int loserIndices[];
   double loserProfits[];
   int loserCount = 0;

   for(int i = 0; i < count; i++)
   {
      if(i == newestIdx)
         continue;
      if(profits[i] < 0)
      {
         ArrayResize(loserIndices, loserCount + 1);
         ArrayResize(loserProfits, loserCount + 1);
         loserIndices[loserCount] = i;
         loserProfits[loserCount] = profits[i];
         loserCount++;
      }
   }

   if(loserCount == 0)
   {
      // All positions are in profit - check if we should close all with TP
      if(InpTakeProfitPips > 0)
      {
         double totalProfit = 0;
         for(int i = 0; i < count; i++)
            totalProfit += profits[i];

         double tpValue = InpTakeProfitPips * PointsToPips() * lots[0] *
                          SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         if(totalProfit >= tpValue)
            CloseAllPositions(direction);
      }
      return;
   }

   // Sort losers by loss (smallest absolute loss first = easiest to cover)
   SortLosersByLoss(loserIndices, loserProfits, loserCount);

   // Surplus multiplier: e.g. 10% means we need loss * 1.10 of profit to close
   double surplusMultiplier = 1.0 + (InpSurplusPercent / 100.0);

   if(InpPartialRecovery)
   {
      // Progressive recovery: close losers one by one, each with guaranteed surplus
      double availableProfit = recoveryProfit;
      int closedCount = 0;
      double totalSurplusEarned = 0;

      for(int i = 0; i < loserCount; i++)
      {
         double absLoss = MathAbs(loserProfits[i]);
         // Required profit = loss + surplus%. E.g. loss=100$, surplus=10% => need 110$
         double requiredProfit = absLoss * surplusMultiplier;

         if(availableProfit >= requiredProfit)
         {
            // Close the losing position - surplus guaranteed
            int idx = loserIndices[i];
            double surplus = requiredProfit - absLoss;  // Our net gain on this closure

            trade.PositionClose(tickets[idx]);
            closedCount++;
            totalSurplusEarned += surplus;
            availableProfit -= requiredProfit;

            Print("RECOVERY: Closed #", tickets[idx],
                  " | Loss: ", DoubleToString(loserProfits[i], 2),
                  " | Required: ", DoubleToString(requiredProfit, 2),
                  " | Surplus earned: +", DoubleToString(surplus, 2),
                  " | Remaining profit: ", DoubleToString(availableProfit, 2));
         }
         else
         {
            // Not enough profit yet for this loser - stop, wait for more profit
            break;
         }
      }

      // If we closed all losers, close recovery trade too to lock remaining profit
      if(closedCount > 0 && closedCount == loserCount)
      {
         trade.PositionClose(tickets[newestIdx]);
         Print("RECOVERY COMPLETE: All ", closedCount, " losers closed.",
               " Total surplus: +", DoubleToString(totalSurplusEarned, 2),
               " Remaining locked: +", DoubleToString(availableProfit, 2));
      }
      // If we closed some but not all, close recovery trade to lock partial gains
      else if(closedCount > 0 && availableProfit < (MathAbs(loserProfits[loserIndices[closedCount]]) * surplusMultiplier * 0.5))
      {
         // Not enough left to cover next loser even at 50% - lock what we have
         trade.PositionClose(tickets[newestIdx]);
         Print("RECOVERY PARTIAL: Closed ", closedCount, "/", loserCount, " losers.",
               " Surplus earned: +", DoubleToString(totalSurplusEarned, 2),
               " Profit locked: +", DoubleToString(availableProfit, 2));
      }
      // Otherwise keep recovery trade open - it's still growing
   }
   else
   {
      // Batch recovery: close ALL only when profit covers ALL losses + surplus on each
      double totalRequired = 0;
      for(int i = 0; i < loserCount; i++)
         totalRequired += MathAbs(loserProfits[i]) * surplusMultiplier;

      if(recoveryProfit >= totalRequired)
      {
         double totalSurplus = recoveryProfit - totalRequired + (totalRequired - totalRequired / surplusMultiplier);
         CloseAllPositions(direction);
         Print("RECOVERY BATCH: All positions closed.",
               " Recovery profit: ", DoubleToString(recoveryProfit, 2),
               " Required (with surplus): ", DoubleToString(totalRequired, 2),
               " Net surplus: +", DoubleToString(recoveryProfit - totalRequired / surplusMultiplier * (surplusMultiplier - 1.0), 2));
      }
   }
}

//+------------------------------------------------------------------+
//| Sort losers by smallest loss first                                |
//+------------------------------------------------------------------+
void SortLosersByLoss(int &indices[], double &profitsArr[], int size)
{
   // Simple bubble sort (small arrays)
   for(int i = 0; i < size - 1; i++)
   {
      for(int j = 0; j < size - i - 1; j++)
      {
         // Sort by absolute loss ascending (smallest loss first)
         if(MathAbs(profitsArr[j]) > MathAbs(profitsArr[j + 1]))
         {
            // Swap
            double tmpProfit = profitsArr[j];
            profitsArr[j] = profitsArr[j + 1];
            profitsArr[j + 1] = tmpProfit;

            int tmpIdx = indices[j];
            indices[j] = indices[j + 1];
            indices[j + 1] = tmpIdx;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Count positions and profit by direction                           |
//+------------------------------------------------------------------+
void CountPositions(int &buyCount, int &sellCount, double &buyProfit, double &sellProfit)
{
   buyCount = 0;
   sellCount = 0;
   buyProfit = 0;
   sellProfit = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Symbol() != _Symbol)
         continue;
      if(posInfo.Magic() != InpMagicNumber)
         continue;

      double profit = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         buyCount++;
         buyProfit += profit;
      }
      else
      {
         sellCount++;
         sellProfit += profit;
      }
   }
}

//+------------------------------------------------------------------+
//| Get worst position price (furthest in loss)                       |
//+------------------------------------------------------------------+
void GetWorstPositionPrice(ENUM_ORDER_TYPE direction, double &worstPrice)
{
   worstPrice = 0;
   double worstProfit = DBL_MAX;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Symbol() != _Symbol)
         continue;
      if(posInfo.Magic() != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE posType = posInfo.PositionType();
      if((direction == ORDER_TYPE_BUY && posType != POSITION_TYPE_BUY) ||
         (direction == ORDER_TYPE_SELL && posType != POSITION_TYPE_SELL))
         continue;

      double profit = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
      if(profit < worstProfit)
      {
         worstProfit = profit;
         worstPrice = posInfo.PriceOpen();
      }
   }
}

//+------------------------------------------------------------------+
//| Open a position                                                   |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE direction, double lot, string levelTag)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   string comment = InpComment + "_" + levelTag;

   // TP only on the initial position (L1) - grid levels use recovery system
   double tp = 0;
   if(levelTag == "L1" && InpTakeProfitPips > 0)
   {
      double tpDistance = InpTakeProfitPips * PointsToPips();
      if(direction == ORDER_TYPE_BUY)
         tp = NormalizeDouble(ask + tpDistance, digits);
      else
         tp = NormalizeDouble(bid - tpDistance, digits);
   }

   bool result = false;
   if(direction == ORDER_TYPE_BUY)
      result = trade.Buy(lot, _Symbol, ask, 0, tp, comment);
   else
      result = trade.Sell(lot, _Symbol, bid, 0, tp, comment);

   if(result)
   {
      lastGridPrice = (direction == ORDER_TYPE_BUY) ? ask : bid;
      Print("Position opened: ", (direction == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " Lot: ", DoubleToString(lot, 2), " Level: ", levelTag,
            (tp > 0 ? " TP: " + DoubleToString(tp, digits) : ""));
   }
   else
   {
      Print("Failed to open position. Error: ", GetLastError());
   }

   return result;
}

//+------------------------------------------------------------------+
//| Close all positions for a direction                               |
//+------------------------------------------------------------------+
void CloseAllPositions(ENUM_ORDER_TYPE direction)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Symbol() != _Symbol)
         continue;
      if(posInfo.Magic() != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE posType = posInfo.PositionType();
      if((direction == ORDER_TYPE_BUY && posType != POSITION_TYPE_BUY) ||
         (direction == ORDER_TYPE_SELL && posType != POSITION_TYPE_SELL))
         continue;

      trade.PositionClose(posInfo.Ticket());
   }
}

//+------------------------------------------------------------------+
//| Check trend filter (EMA)                                          |
//+------------------------------------------------------------------+
bool CheckTrendFilter(ENUM_ORDER_TYPE direction)
{
   if(!InpUseTrendFilter)
      return true;

   double emaBuffer[];
   ArraySetAsSeries(emaBuffer, true);

   if(CopyBuffer(emaHandle, 0, 0, 1, emaBuffer) <= 0)
      return true; // Allow if indicator fails

   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(direction == ORDER_TYPE_BUY)
      return (currentPrice > emaBuffer[0]); // Buy only above EMA
   else
      return (currentPrice < emaBuffer[0]); // Sell only below EMA
}

//+------------------------------------------------------------------+
//| Check max drawdown                                                |
//+------------------------------------------------------------------+
bool CheckMaxDrawdown()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(balance <= 0)
      return false;

   double ddPercent = ((balance - equity) / balance) * 100.0;

   if(ddPercent >= InpMaxDrawdownPct)
   {
      // Close all positions
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!posInfo.SelectByIndex(i))
            continue;
         if(posInfo.Symbol() != _Symbol)
            continue;
         if(posInfo.Magic() != InpMagicNumber)
            continue;

         trade.PositionClose(posInfo.Ticket());
      }

      Print("MAX DRAWDOWN REACHED (", DoubleToString(ddPercent, 1),
            "%). All positions closed!");
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Check for new bar                                                  |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES tf)
{
   datetime currentBarTime = iTime(_Symbol, tf, 0);
   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Normalize lot size                                                 |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, lot);
   lot = MathMin(maxLot, lot);
   lot = MathRound(lot / lotStep) * lotStep;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Helper: points to pips conversion factor                          |
//+------------------------------------------------------------------+
double PointsToPips()
{
   if(digits == 3 || digits == 5)
      return pointValue * 10;
   return pointValue;
}

//+------------------------------------------------------------------+
//| OnTrade - log trade events                                        |
//+------------------------------------------------------------------+
void OnTrade()
{
   static int lastTotal = 0;
   int currentTotal = PositionsTotal();

   if(currentTotal != lastTotal)
   {
      int buyCount = 0, sellCount = 0;
      double buyProfit = 0, sellProfit = 0;
      CountPositions(buyCount, sellCount, buyProfit, sellProfit);

      Print("=== Position Update === Buy: ", buyCount, " (", DoubleToString(buyProfit, 2),
            ") | Sell: ", sellCount, " (", DoubleToString(sellProfit, 2), ")",
            " | Grid spacing: ", DoubleToString(gridSpacingPoints / pointValue, 1), " pts");

      lastTotal = currentTotal;
   }
}

//+------------------------------------------------------------------+
//| Display panel on chart                                             |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Future: panel interaction
}
//+------------------------------------------------------------------+
