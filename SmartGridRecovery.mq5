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

double         gridSpacingPoints;    // Grid spacing in points (fixed at grid start)
double         pointValue;           // Point value
int            symDigits;               // Symbol symDigits
int            atrHandle;            // ATR indicator handle
int            emaHandle;            // EMA indicator handle
datetime       lastBarTime;          // Track new bar
double         lastGridPriceBuy;     // Price of last BUY grid order
double         lastGridPriceSell;    // Price of last SELL grid order

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

   // Auto-detect filling mode
   long fillType = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillType & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillType & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);

   // Symbol info
   symDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
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
   lastGridPriceBuy = 0;
   lastGridPriceSell = 0;
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
   // Only calculate once when grid starts (spacing = 0 means no grid active)
   // Recalculate only when no positions are open (new grid cycle)
   if(gridSpacingPoints > 0)
      return;

   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);

   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) <= 0)
      return;

   double dailyATR = atrBuffer[0];

   // Risk level divisor: 1=1x, 2=2x, 3=3x, 4=4x, 5=5x
   double divisor = (double)InpRiskLevel;
   gridSpacingPoints = dailyATR / divisor;

   // Minimum spacing: 10 pips for 5-digit brokers
   double pipMultiplier = (symDigits == 3 || symDigits == 5) ? 10.0 : 1.0;
   double minSpacing = 10.0 * pointValue * pipMultiplier;
   if(gridSpacingPoints < minSpacing)
      gridSpacingPoints = minSpacing;

   double spacingPips = gridSpacingPoints / (pointValue * pipMultiplier);
   Print("Grid spacing FIXED at: ", DoubleToString(spacingPips, 1),
         " pips (ATR=", DoubleToString(dailyATR / (pointValue * pipMultiplier), 1),
         " pips, Risk=", InpRiskLevel, ")");
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
      // Reset grid tracking for new cycle
      if(direction == ORDER_TYPE_BUY)
         lastGridPriceBuy = 0;
      else
         lastGridPriceSell = 0;
      gridSpacingPoints = 0; // Force recalculate ATR for new grid cycle
      UpdateGridSpacing();

      double lot = InpBaseLotSize;
      if(OpenPosition(direction, lot, "L1"))
      {
         if(direction == ORDER_TYPE_BUY)
            lastGridPriceBuy = ask;
         else
            lastGridPriceSell = bid;
      }
      return;
   }

   // Check if we've hit max grid levels
   if(currentCount >= InpMaxGridLevels)
      return;

   // Get price of the LAST opened position on this side
   double lastPrice = GetLastOpenedPrice(direction);
   if(lastPrice <= 0)
      return;

   // Calculate distance from LAST position to current price (must be against us)
   double distance = 0;
   if(direction == ORDER_TYPE_BUY)
      distance = lastPrice - currentPrice;   // BUY grid: price dropped from last entry
   else
      distance = currentPrice - lastPrice;   // SELL grid: price rose from last entry

   // Only open new level if price moved EXACTLY gridSpacing away from last position
   if(distance >= gridSpacingPoints)
   {
      // Calculate lot with multiplier
      double lot = InpBaseLotSize * MathPow(InpLotMultiplier, currentCount);
      lot = NormalizeLot(lot);

      string levelComment = "L" + IntegerToString(currentCount + 1);
      double pipMultiplier = (symDigits == 3 || symDigits == 5) ? 10.0 : 1.0;

      if(OpenPosition(direction, lot, levelComment))
      {
         // Update last grid price to THIS position
         if(direction == ORDER_TYPE_BUY)
            lastGridPriceBuy = ask;
         else
            lastGridPriceSell = bid;

         Print("Grid level ", currentCount + 1, " | ",
               (direction == ORDER_TYPE_BUY ? "BUY" : "SELL"),
               " | Lot: ", DoubleToString(lot, 2),
               " | Distance from prev: ", DoubleToString(distance / (pointValue * pipMultiplier), 1), " pips",
               " | Grid spacing: ", DoubleToString(gridSpacingPoints / (pointValue * pipMultiplier), 1), " pips");
      }
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

   if(count == 0)
      return;

   // === CASE 1: Single orphan position - give it a TP if it doesn't have one ===
   if(count == 1)
   {
      if(profits[0] > 0 && InpTakeProfitPips > 0)
      {
         // Check if it already has a TP
         if(PositionSelectByTicket(tickets[0]))
         {
            double currentTP = PositionGetDouble(POSITION_TP);
            if(currentTP == 0)
            {
               // Orphan with no TP - add TP so it can close itself
               double sl = PositionGetDouble(POSITION_SL);
               double tpDistance = InpTakeProfitPips * PointsToPips();
               double tp = 0;
               if(direction == ORDER_TYPE_BUY)
                  tp = NormalizeDouble(openPrices[0] + tpDistance, symDigits);
               else
                  tp = NormalizeDouble(openPrices[0] - tpDistance, symDigits);

               trade.PositionModify(tickets[0], sl, tp);
               Print("ORPHAN: Added TP ", DoubleToString(tp, symDigits),
                     " to position #", tickets[0]);
            }
         }
      }
      return;
   }

   // === CASE 2: Multiple positions - find ALL winners and ALL losers ===
   int winnerIndices[];
   double winnerProfits[];
   int winnerCount = 0;

   int loserIndices[];
   double loserProfits[];
   int loserCount = 0;

   for(int i = 0; i < count; i++)
   {
      if(profits[i] > 0)
      {
         ArrayResize(winnerIndices, winnerCount + 1);
         ArrayResize(winnerProfits, winnerCount + 1);
         winnerIndices[winnerCount] = i;
         winnerProfits[winnerCount] = profits[i];
         winnerCount++;
      }
      else if(profits[i] < 0)
      {
         ArrayResize(loserIndices, loserCount + 1);
         ArrayResize(loserProfits, loserCount + 1);
         loserIndices[loserCount] = i;
         loserProfits[loserCount] = profits[i];
         loserCount++;
      }
   }

   // No losers: check if total profit justifies closing all
   if(loserCount == 0)
   {
      double totalProfit = 0;
      for(int i = 0; i < count; i++)
         totalProfit += profits[i];

      // Close all if combined profit > surplus threshold
      double minClose = InpSurplusPercent * InpBaseLotSize *
                        SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(totalProfit > minClose)
      {
         CloseAllPositions(direction);
         Print("ALL IN PROFIT: Closed all ", count, " positions. Total: +",
               DoubleToString(totalProfit, 2));
      }
      return;
   }

   // No winners yet: nothing to recover with
   if(winnerCount == 0)
      return;

   // === RECOVERY: Pool ALL winning profit together ===
   double totalWinProfit = 0;
   for(int i = 0; i < winnerCount; i++)
      totalWinProfit += winnerProfits[i];

   // Sort losers by smallest loss first
   SortLosersByLoss(loserIndices, loserProfits, loserCount);

   double surplusMultiplier = 1.0 + (InpSurplusPercent / 100.0);

   if(InpPartialRecovery)
   {
      // Progressive: use combined winner profit to close losers one by one
      double availableProfit = totalWinProfit;
      int closedLosers = 0;
      double totalSurplusEarned = 0;

      for(int i = 0; i < loserCount; i++)
      {
         double absLoss = MathAbs(loserProfits[i]);
         double requiredProfit = absLoss * surplusMultiplier;

         if(availableProfit >= requiredProfit)
         {
            int idx = loserIndices[i];
            double surplus = requiredProfit - absLoss;

            trade.PositionClose(tickets[idx]);
            closedLosers++;
            totalSurplusEarned += surplus;
            availableProfit -= requiredProfit;

            Print("RECOVERY: Closed loser #", tickets[idx],
                  " | Loss: ", DoubleToString(loserProfits[i], 2),
                  " | Surplus: +", DoubleToString(surplus, 2),
                  " | Pool remaining: ", DoubleToString(availableProfit, 2));
         }
         else
         {
            break;
         }
      }

      // If ALL losers closed, close ALL winners too to lock profit
      if(closedLosers > 0 && closedLosers == loserCount)
      {
         for(int i = 0; i < winnerCount; i++)
            trade.PositionClose(tickets[winnerIndices[i]]);

         Print("RECOVERY COMPLETE: ", closedLosers, " losers + ", winnerCount, " winners closed.",
               " Surplus: +", DoubleToString(totalSurplusEarned, 2),
               " Locked: +", DoubleToString(availableProfit, 2));
      }
      // Closed some losers but not all: close winners to lock partial recovery
      else if(closedLosers > 0)
      {
         // Check if remaining profit is too small to cover next loser
         int nextLoserArrayIdx = closedLosers; // index in loserIndices
         double nextLossNeeded = MathAbs(loserProfits[nextLoserArrayIdx]) * surplusMultiplier;

         if(availableProfit < nextLossNeeded * 0.3)
         {
            // Not enough to cover next loser: close all winners, lock gains
            for(int i = 0; i < winnerCount; i++)
               trade.PositionClose(tickets[winnerIndices[i]]);

            Print("RECOVERY PARTIAL: ", closedLosers, "/", loserCount, " losers closed.",
                  " Surplus: +", DoubleToString(totalSurplusEarned, 2),
                  " Winners closed to lock profit.");
         }
         // Otherwise keep winners open to grow more profit
      }
   }
   else
   {
      // Batch: close ALL only when total winner profit covers ALL losses + surplus
      double totalRequired = 0;
      for(int i = 0; i < loserCount; i++)
         totalRequired += MathAbs(loserProfits[i]) * surplusMultiplier;

      if(totalWinProfit >= totalRequired)
      {
         CloseAllPositions(direction);
         Print("RECOVERY BATCH: All closed. Winners: +", DoubleToString(totalWinProfit, 2),
               " | Required: ", DoubleToString(totalRequired, 2),
               " | Net surplus: +", DoubleToString(totalWinProfit - totalRequired, 2));
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
//| Get price of the LAST (most recent) opened position               |
//+------------------------------------------------------------------+
double GetLastOpenedPrice(ENUM_ORDER_TYPE direction)
{
   double lastPrice = 0;
   datetime lastTime = 0;

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

      if(posInfo.Time() > lastTime)
      {
         lastTime = posInfo.Time();
         lastPrice = posInfo.PriceOpen();
      }
   }

   return lastPrice;
}

//+------------------------------------------------------------------+
//| Open a position                                                   |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE direction, double lot, string levelTag)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   string comment = InpComment + "_" + levelTag;

   // Calculate TP for initial position (L1)
   double tp = 0;
   if(levelTag == "L1" && InpTakeProfitPips > 0)
   {
      double tpDistance = InpTakeProfitPips * PointsToPips();
      if(direction == ORDER_TYPE_BUY)
         tp = NormalizeDouble(ask + tpDistance, symDigits);
      else
         tp = NormalizeDouble(bid - tpDistance, symDigits);

      Print("TP calculated: price=", (direction == ORDER_TYPE_BUY ? DoubleToString(ask, symDigits) : DoubleToString(bid, symDigits)),
            " + ", DoubleToString(tpDistance, symDigits), " = ", DoubleToString(tp, symDigits));
   }

   // Open position with TP
   bool result = false;
   if(direction == ORDER_TYPE_BUY)
      result = trade.Buy(lot, _Symbol, ask, 0, tp, comment);
   else
      result = trade.Sell(lot, _Symbol, bid, 0, tp, comment);

   if(result)
   {
      Print("Position opened: ", (direction == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " Lot: ", DoubleToString(lot, 2), " Level: ", levelTag,
            (tp > 0 ? " TP: " + DoubleToString(tp, symDigits) : " NO TP"));

      // If TP was requested but position opened without it, modify to add TP
      if(tp > 0)
      {
         ulong ticket = trade.ResultOrder();
         if(ticket > 0 && PositionSelectByTicket(ticket))
         {
            double currentTP = PositionGetDouble(POSITION_TP);
            if(currentTP == 0)
            {
               double sl = PositionGetDouble(POSITION_SL);
               if(trade.PositionModify(ticket, sl, tp))
                  Print("TP added via modify: ", DoubleToString(tp, symDigits));
               else
                  Print("WARNING: Failed to set TP. Error: ", GetLastError());
            }
         }
      }
   }
   else
   {
      Print("Failed to open position. Error: ", GetLastError(),
            " RetCode: ", trade.ResultRetcode());
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
   if(symDigits == 3 || symDigits == 5)
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
