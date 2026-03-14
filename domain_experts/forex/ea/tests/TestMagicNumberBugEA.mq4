//+------------------------------------------------------------------+
//| TestMagicNumberBugEA.mq4                                         |
//| Automated EA test harness for magic-number fix validation        |
//+------------------------------------------------------------------+
#property strict
#define UNIT_TEST

// TimeUtils.mqh 依赖的全局配置（测试桩）
bool AutoDetectUTCOffset = true;
int  ServerUTCOffset = 2;

// ===== Mock A: OrderSend / GetLastError wrapper =====
int g_LastOrderSendMagic = -1;
int g_OrderSendCallCount = 0;
int g_OrderSendReturnSequence[10];
int g_OrderSendSeqIndex = 0;
int g_LastErrorSequence[10];
int g_LastErrorSeqIndex = 0;

int MockOrderSend(string symbol, int cmd, double volume, double price,
                  int slippage, double stoploss, double takeprofit,
                  string comment, int magic, datetime expiration, color arrow_color)
{
   g_LastOrderSendMagic = magic;
   g_OrderSendCallCount++;
   if(g_OrderSendSeqIndex < ArraySize(g_OrderSendReturnSequence))
      return g_OrderSendReturnSequence[g_OrderSendSeqIndex++];
   return 10001;
}

int MockGetLastError()
{
   if(g_LastErrorSeqIndex < ArraySize(g_LastErrorSequence))
      return g_LastErrorSequence[g_LastErrorSeqIndex++];
   return 0;
}

// ===== Mock B: 订单查询 wrapper =====
struct MockOrder { int type; string symbol; int magic; };
MockOrder g_MockOrders[10];
int g_MockOrderCount = 0;
int g_MockCurrentIndex = -1;

int MockOrdersTotal() { return g_MockOrderCount; }

bool MockOrderSelect(int i, int mode, int pool)
{
   if(i < 0 || i >= g_MockOrderCount) return false;
   g_MockCurrentIndex = i;
   return true;
}

int MockOrderType() { return g_MockOrders[g_MockCurrentIndex].type; }
string MockOrderSymbol() { return g_MockOrders[g_MockCurrentIndex].symbol; }
int MockOrderMagicNumber() { return g_MockOrders[g_MockCurrentIndex].magic; }

// ===== Include SUT =====
#include "include/OrderExecutor.mqh"
#include "include/PositionManager.mqh"

// ===== Counters =====
int g_ExplorePass = 0;
int g_ExploreFail = 0;
int g_PreservePass = 0;
int g_PreserveFail = 0;

void ResetMocks()
{
   g_LastOrderSendMagic = -1;
   g_OrderSendCallCount = 0;
   g_OrderSendSeqIndex = 0;
   g_LastErrorSeqIndex = 0;
   g_MockOrderCount = 0;
   g_MockCurrentIndex = -1;
   ArrayInitialize(g_OrderSendReturnSequence, 10001);
   ArrayInitialize(g_LastErrorSequence, 0);
}

void AssertExplore(bool condition, string test_name, string detail)
{
   if(condition) {
      Print("[PASS] ", test_name);
      g_ExplorePass++;
   } else {
      Print("[FAIL] ", test_name, " | ", detail);
      g_ExploreFail++;
   }
}

void AssertPreserve(bool condition, string test_name, string detail)
{
   if(condition) {
      Print("[PASS] ", test_name);
      g_PreservePass++;
   } else {
      Print("[FAIL] ", test_name, " | ", detail);
      g_PreserveFail++;
   }
}

void RunExploratoryTests()
{
   Print("========== Magic Number Bug 探索性测试 ==========");

   // 探索 1: OpenPosition 透传 magic
   ResetMocks();
   g_OrderSendReturnSequence[0] = 10001;
   int ticket = OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3, 12345);
   AssertExplore(g_LastOrderSendMagic == 12345,
                 "探索1: OpenPosition 应将 magic=12345 传入 OrderSend",
                 StringFormat("ticket=%d, actual magic=%d", ticket, g_LastOrderSendMagic));

   // 探索 2: OpenMultiplePositions 透传 magic
   ResetMocks();
   g_OrderSendReturnSequence[0] = 10001;
   g_OrderSendReturnSequence[1] = 10002;
   LotSplit splits[2];
   splits[0].lots = 0.05; splits[0].tp_price = 1.0900;
   splits[1].lots = 0.05; splits[1].tp_price = 1.0850;
   int tickets[2];
   OpenMultiplePositions(splits, 2, 1.1000, 1.0950, 3, tickets, 12345);
   AssertExplore(g_LastOrderSendMagic == 12345,
                 "探索2: OpenMultiplePositions 应将 magic=12345 传入每笔 OrderSend",
                 StringFormat("actual magic=%d", g_LastOrderSendMagic));

   // 探索 3: GetOpenPositions 按 magic 过滤
   ResetMocks();
   g_MockOrders[0].type = OP_SELL; g_MockOrders[0].symbol = Symbol(); g_MockOrders[0].magic = 12345;
   g_MockOrders[1].type = OP_SELL; g_MockOrders[1].symbol = Symbol(); g_MockOrders[1].magic = 99999;
   g_MockOrderCount = 2;
   int positions[10];
   int count = GetOpenPositions(positions, 12345);
   AssertExplore(count == 1,
                 "探索3: GetOpenPositions 应只返回 magic=12345 的订单",
                 StringFormat("actual count=%d", count));

   Print("探索性测试 - 通过: ", g_ExplorePass, " / 失败: ", g_ExploreFail, "（修复后应全部 PASS）");
}

void RunPreservationTests()
{
   Print("========== Preservation 属性测试 ==========");

   // Preservation 0: magic<=0 直接拒绝
   ResetMocks();
   int rej_ticket = OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3, 0);
   AssertPreserve((rej_ticket == -1 && g_OrderSendCallCount == 0),
                  "Preservation0: magic<=0 直接拒绝，不调用 OrderSend",
                  StringFormat("ticket=%d callCount=%d", rej_ticket, g_OrderSendCallCount));

   // Preservation 1: 可重试错误触发 3 次后成功
   ResetMocks();
   g_OrderSendReturnSequence[0] = -1;
   g_OrderSendReturnSequence[1] = -1;
   g_OrderSendReturnSequence[2] = 10001;
   g_LastErrorSequence[0] = 4;
   g_LastErrorSequence[1] = 4;
   int ticket1 = OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3, 12345);
   AssertPreserve((ticket1 == 10001 && g_OrderSendCallCount == 3),
                  "Preservation1: 可重试错误触发 3 次重试后成功",
                  StringFormat("ticket=%d callCount=%d", ticket1, g_OrderSendCallCount));

   // Preservation 2: 不可重试错误立即放弃
   ResetMocks();
   g_OrderSendReturnSequence[0] = -1;
   g_LastErrorSequence[0] = 130;
   int ticket2 = OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3, 12345);
   AssertPreserve((ticket2 == -1 && g_OrderSendCallCount == 1),
                  "Preservation2: 不可重试错误立即放弃",
                  StringFormat("ticket=%d callCount=%d", ticket2, g_OrderSendCallCount));

   // Preservation 3: 拆单遍历不中止
   ResetMocks();
   g_OrderSendReturnSequence[0] = 10001;
   g_OrderSendReturnSequence[1] = -1;
   g_OrderSendReturnSequence[2] = 10003;
   g_LastErrorSequence[0] = 130;
   LotSplit splits3[3];
   splits3[0].lots = 0.03; splits3[0].tp_price = 1.0900;
   splits3[1].lots = 0.03; splits3[1].tp_price = 1.0870;
   splits3[2].lots = 0.04; splits3[2].tp_price = 1.0840;
   int tickets3[3];
   OpenMultiplePositions(splits3, 3, 1.1000, 1.0950, 3, tickets3, 12345);
   AssertPreserve((g_OrderSendCallCount == 3 && tickets3[0] == 10001 && tickets3[2] == 10003),
                  "Preservation3: 拆单遍历——第 2 笔失败不中止其余订单",
                  StringFormat("callCount=%d t1=%d t3=%d", g_OrderSendCallCount, tickets3[0], tickets3[2]));

   // Preservation 4: 品种过滤保留
   ResetMocks();
   g_MockOrders[0].type = OP_SELL; g_MockOrders[0].symbol = Symbol(); g_MockOrders[0].magic = 12345;
   g_MockOrders[1].type = OP_SELL; g_MockOrders[1].symbol = "EURUSD_OTHER"; g_MockOrders[1].magic = 12345;
   g_MockOrderCount = 2;
   int pos4[10];
   int cnt4 = GetOpenPositions(pos4, 12345);
   AssertPreserve(cnt4 == 1,
                  "Preservation4: 非当前品种订单被过滤",
                  StringFormat("count=%d", cnt4));

   Print("Preservation 测试 - 通过: ", g_PreservePass, " / 失败: ", g_PreserveFail, "（应全部 PASS）");
}

int OnInit()
{
   RunExploratoryTests();
   RunPreservationTests();

   int totalFail = g_ExploreFail + g_PreserveFail;
   Print("AUTO_TEST_SUMMARY: explore_pass=", g_ExplorePass,
         " explore_fail=", g_ExploreFail,
         " preserve_pass=", g_PreservePass,
         " preserve_fail=", g_PreserveFail,
         " total_fail=", totalFail);
   Print("AUTO_TEST_RESULT: ", (totalFail == 0 ? "PASS" : "FAIL"));

   ExpertRemove();
   return(INIT_SUCCEEDED);
}

void OnTick()
{
}

