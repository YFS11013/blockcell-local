//+------------------------------------------------------------------+
//| TestMagicNumberBug.mq4                                           |
//| Bug Condition 探索性测试 + Preservation 属性测试                  |
//|                                                                  |
//| 探索性测试：验证修复后 magic 正确透传（修复前这些测试会 FAIL）      |
//| Preservation 测试：验证重试/拆单/DryRun 等行为不变（应始终 PASS）  |
//+------------------------------------------------------------------+
#property strict
#define UNIT_TEST

// ===== Mock 桩定义（必须在 #include 之前）=====

// TimeUtils.mqh 依赖的全局配置（脚本上下文无 EA input，需提供测试桩）
bool AutoDetectUTCOffset = true;
int  ServerUTCOffset = 2;

// Mock A: OrderSend / GetLastError wrapper
int g_LastOrderSendMagic = -1;
int g_OrderSendCallCount = 0;
int g_OrderSendReturnSequence[10];
int g_OrderSendSeqIndex = 0;
int g_LastErrorSequence[10];
int g_LastErrorSeqIndex = 0;

int MockOrderSend(string symbol, int cmd, double volume, double price,
                  int slippage, double stoploss, double takeprofit,
                  string comment, int magic, datetime expiration, color arrow_color) {
   g_LastOrderSendMagic = magic;
   g_OrderSendCallCount++;
   if(g_OrderSendSeqIndex < ArraySize(g_OrderSendReturnSequence))
      return g_OrderSendReturnSequence[g_OrderSendSeqIndex++];
   return 10001;
}

int MockGetLastError() {
   if(g_LastErrorSeqIndex < ArraySize(g_LastErrorSequence))
      return g_LastErrorSequence[g_LastErrorSeqIndex++];
   return 0;
}

// Mock B: 订单查询 wrapper
struct MockOrder { int type; string symbol; int magic; };
MockOrder g_MockOrders[10];
int g_MockOrderCount  = 0;
int g_MockCurrentIndex = -1;

int    MockOrdersTotal()                              { return g_MockOrderCount; }
bool   MockOrderSelect(int i, int mode, int pool)     {
   if(i < 0 || i >= g_MockOrderCount) return false;
   g_MockCurrentIndex = i;
   return true;
}
int    MockOrderType()        { return g_MockOrders[g_MockCurrentIndex].type; }
string MockOrderSymbol()      { return g_MockOrders[g_MockCurrentIndex].symbol; }
int    MockOrderMagicNumber() { return g_MockOrders[g_MockCurrentIndex].magic; }

// ===== 包含被测模块 =====
#include "../include/OrderExecutor.mqh"
#include "../include/PositionManager.mqh"

// ===== 测试辅助函数 =====
void ResetMocks() {
   g_LastOrderSendMagic = -1;
   g_OrderSendCallCount = 0;
   g_OrderSendSeqIndex  = 0;
   g_LastErrorSeqIndex  = 0;
   g_MockOrderCount     = 0;
   g_MockCurrentIndex   = -1;
   ArrayInitialize(g_OrderSendReturnSequence, 10001);
   ArrayInitialize(g_LastErrorSequence, 0);
}

int g_PassCount = 0;
int g_FailCount = 0;

void Assert(bool condition, string test_name, string detail = "") {
   if(condition) {
      Print("[PASS] ", test_name);
      g_PassCount++;
   } else {
      Print("[FAIL] ", test_name, detail != "" ? " | " + detail : "");
      g_FailCount++;
   }
}

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart() {
   Print("========== Magic Number Bug 探索性测试 ==========");
   Print("注意：探索性测试验证修复后 magic 正确透传（修复前这些测试会 FAIL）");

   // ---------------------------------------------------------------
   // 探索性测试 1：OpenPosition 正确透传 magic=12345
   // 修复前：内部硬编码 magic=0，g_LastOrderSendMagic 会是 0 → FAIL
   // 修复后：magic 由调用方传入，g_LastOrderSendMagic 应为 12345 → PASS
   // ---------------------------------------------------------------
   ResetMocks();
   g_OrderSendReturnSequence[0] = 10001;

   int ticket = OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3, 12345);

   Assert(g_LastOrderSendMagic == 12345,
          "探索1: OpenPosition 应将 magic=12345 传入 OrderSend",
          StringFormat("实际 g_LastOrderSendMagic=%d（期望 12345）", g_LastOrderSendMagic));

   // ---------------------------------------------------------------
   // 探索性测试 2：OpenMultiplePositions 正确透传 magic=12345
   // 修复前：内部硬编码 magic=0 → FAIL
   // 修复后：magic 透传到每笔 OpenPosition → PASS
   // ---------------------------------------------------------------
   ResetMocks();
   g_OrderSendReturnSequence[0] = 10001;
   g_OrderSendReturnSequence[1] = 10002;

   LotSplit splits[2];
   splits[0].lots = 0.05; splits[0].tp_price = 1.0900;
   splits[1].lots = 0.05; splits[1].tp_price = 1.0850;
   int tickets[2];

   OpenMultiplePositions(splits, 2, 1.1000, 1.0950, 3, tickets, 12345);

   Assert(g_LastOrderSendMagic == 12345,
          "探索2: OpenMultiplePositions 应将 magic=12345 传入每笔 OrderSend",
          StringFormat("实际 g_LastOrderSendMagic=%d（期望 12345）", g_LastOrderSendMagic));

   // ---------------------------------------------------------------
   // 探索性测试 3：GetOpenPositions 按 magic_number 过滤
   // 注入两笔订单：magic=12345 和 magic=99999
   // 修复前：无 magic 过滤，返回 2 笔 → FAIL
   // 修复后：只返回 magic=12345 的 1 笔 → PASS
   // ---------------------------------------------------------------
   ResetMocks();
   g_MockOrders[0].type = OP_SELL; g_MockOrders[0].symbol = Symbol(); g_MockOrders[0].magic = 12345;
   g_MockOrders[1].type = OP_SELL; g_MockOrders[1].symbol = Symbol(); g_MockOrders[1].magic = 99999;
   g_MockOrderCount = 2;

   int positions[10];
   int count = GetOpenPositions(positions, 12345);

   Assert(count == 1,
          "探索3: GetOpenPositions 应只返回 magic=12345 的订单（共 1 笔）",
          StringFormat("实际返回 %d 笔（期望 1）", count));

   Print("========== 探索性测试结果 ==========");
   Print("通过: ", g_PassCount, " / 失败: ", g_FailCount);
   Print("（修复后探索性测试应全部 PASS）");

   // ===============================================================
   // Preservation 测试（应始终 PASS，验证行为无回归）
   // ===============================================================
   Print("");
   Print("========== Preservation 属性测试 ==========");
   int pres_pass = 0;
   int pres_fail = 0;

   // ---------------------------------------------------------------
   // Preservation 1：magic <= 0 时直接拒绝，不进重试（新增校验）
   // ---------------------------------------------------------------
   ResetMocks();
   int rej_ticket = OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3, 0);

   bool pres0_rejected = (rej_ticket == -1);
   bool pres0_no_call  = (g_OrderSendCallCount == 0);
   if(pres0_rejected && pres0_no_call) {
      Print("[PASS] Preservation0: magic<=0 直接拒绝，不调用 OrderSend");
      pres_pass++;
   } else {
      Print("[FAIL] Preservation0: magic<=0 校验",
            StringFormat(" | ticket=%d(期望-1), callCount=%d(期望0)", rej_ticket, g_OrderSendCallCount));
      pres_fail++;
   }

   // ---------------------------------------------------------------
   // Preservation 1：可重试错误触发重试（最多 3 次）
   // ORDER_SEND 前两次返回 -1，GET_LAST_ERROR 返回 4（IsRetryableError(4)==true）
   // 第三次 ORDER_SEND 返回有效 ticket 10001
   // ---------------------------------------------------------------
   ResetMocks();
   g_OrderSendReturnSequence[0] = -1;
   g_OrderSendReturnSequence[1] = -1;
   g_OrderSendReturnSequence[2] = 10001;
   g_LastErrorSequence[0] = 4;  // ERR_SERVER_BUSY（内部码 4）
   g_LastErrorSequence[1] = 4;

   int pres_ticket = OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3, 12345);

   bool pres1_ticket_ok = (pres_ticket == 10001);
   bool pres1_retry_ok  = (g_OrderSendCallCount == 3);
   if(pres1_ticket_ok && pres1_retry_ok) {
      Print("[PASS] Preservation1: 可重试错误触发 3 次重试后成功");
      pres_pass++;
   } else {
      Print("[FAIL] Preservation1: 可重试错误重试行为",
            StringFormat(" | ticket=%d(期望10001), callCount=%d(期望3)", pres_ticket, g_OrderSendCallCount));
      pres_fail++;
   }

   // ---------------------------------------------------------------
   // Preservation 2：不可重试错误立即放弃（不重试）
   // ORDER_SEND 返回 -1，GET_LAST_ERROR 返回 130（ERR_INVALID_STOPS，不可重试）
   // ---------------------------------------------------------------
   ResetMocks();
   g_OrderSendReturnSequence[0] = -1;
   g_LastErrorSequence[0] = 130;  // ERR_INVALID_STOPS

   int pres_ticket2 = OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3, 12345);

   bool pres2_fail_ok  = (pres_ticket2 == -1);
   bool pres2_no_retry = (g_OrderSendCallCount == 1);
   if(pres2_fail_ok && pres2_no_retry) {
      Print("[PASS] Preservation2: 不可重试错误立即放弃");
      pres_pass++;
   } else {
      Print("[FAIL] Preservation2: 不可重试错误处理",
            StringFormat(" | ticket=%d(期望-1), callCount=%d(期望1)", pres_ticket2, g_OrderSendCallCount));
      pres_fail++;
   }

   // ---------------------------------------------------------------
   // Preservation 3：拆单遍历——第 2 笔失败不中止第 3 笔
   // split_count=3，第 2 笔 ORDER_SEND 返回 -1（不可重试错误 130），第 1、3 笔成功
   // ---------------------------------------------------------------
   ResetMocks();
   g_OrderSendReturnSequence[0] = 10001;  // 第 1 笔成功
   g_OrderSendReturnSequence[1] = -1;     // 第 2 笔失败
   g_OrderSendReturnSequence[2] = 10003;  // 第 3 笔成功
   g_LastErrorSequence[0] = 130;          // 第 2 笔失败时的错误码（不可重试）

   LotSplit splits3[3];
   splits3[0].lots = 0.03; splits3[0].tp_price = 1.0900;
   splits3[1].lots = 0.03; splits3[1].tp_price = 1.0870;
   splits3[2].lots = 0.04; splits3[2].tp_price = 1.0840;
   int tickets3[3];

   OpenMultiplePositions(splits3, 3, 1.1000, 1.0950, 3, tickets3, 12345);

   bool pres3_all_tried = (g_OrderSendCallCount == 3);
   bool pres3_t1_ok     = (tickets3[0] == 10001);
   bool pres3_t3_ok     = (tickets3[2] == 10003);
   if(pres3_all_tried && pres3_t1_ok && pres3_t3_ok) {
      Print("[PASS] Preservation3: 拆单遍历——第 2 笔失败不中止其余订单");
      pres_pass++;
   } else {
      Print("[FAIL] Preservation3: 拆单遍历行为",
            StringFormat(" | callCount=%d(期望3), t1=%d(期望10001), t3=%d(期望10003)",
                         g_OrderSendCallCount, tickets3[0], tickets3[2]));
      pres_fail++;
   }

   // ---------------------------------------------------------------
   // Preservation 4：品种过滤——非当前品种订单被过滤
   // 注入两笔订单：一笔当前品种，一笔其他品种（magic 相同）
   // ---------------------------------------------------------------
   ResetMocks();
   g_MockOrders[0].type = OP_SELL; g_MockOrders[0].symbol = Symbol();       g_MockOrders[0].magic = 12345;
   g_MockOrders[1].type = OP_SELL; g_MockOrders[1].symbol = "EURUSD_OTHER"; g_MockOrders[1].magic = 12345;
   g_MockOrderCount = 2;

   int pos4[10];
   int cnt4 = GetOpenPositions(pos4, 12345);

   bool pres4_ok = (cnt4 == 1);
   if(pres4_ok) {
      Print("[PASS] Preservation4: 非当前品种订单被过滤");
      pres_pass++;
   } else {
      Print("[FAIL] Preservation4: 品种过滤行为",
            StringFormat(" | 返回 %d 笔（期望 1）", cnt4));
      pres_fail++;
   }

   Print("========== Preservation 测试结果 ==========");
   Print("通过: ", pres_pass, " / 失败: ", pres_fail);
   Print("（Preservation 测试应全部 PASS）");
   Print("");
   Print("========== 全部测试汇总 ==========");
   Print("探索性测试 - 通过: ", g_PassCount, " / 失败: ", g_FailCount, "（修复后应全部 PASS）");
   Print("Preservation 测试 - 通过: ", pres_pass, " / 失败: ", pres_fail, "（应全部 PASS）");
}
