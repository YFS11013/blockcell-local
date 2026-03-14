//+------------------------------------------------------------------+
//| EaTestBase.mqh                                                   |
//| P4 通用 EA 测试基础库                                              |
//|                                                                  |
//| 用法：                                                            |
//|   1. 在测试 EA 中 #include "EaTestBase.mqh"                      |
//|   2. 实现 void RunTests() 函数，在其中调用 AssertExplore /        |
//|      AssertPreserve                                              |
//|   3. OnInit 调用 RunAllTests()，OnTick 留空                       |
//|                                                                  |
//| 输出格式（run_ea_test.ps1 解析）：                                 |
//|   AUTO_TEST_SUMMARY: explore_pass=N explore_fail=N              |
//|                      preserve_pass=N preserve_fail=N total_fail=N|
//|   AUTO_TEST_RESULT: PASS|FAIL                                    |
//+------------------------------------------------------------------+
#property strict

// ── 全局计数器 ────────────────────────────────────────────────────────────────
int g_ExplorePass  = 0;
int g_ExploreFail  = 0;
int g_PreservePass = 0;
int g_PreserveFail = 0;

// ── 断言函数 ──────────────────────────────────────────────────────────────────

// 探索性断言：验证 bug 存在 / 修复效果
void AssertExplore(bool condition, string testName, string detail = "")
{
    if (condition) {
        Print("[PASS][explore] ", testName);
        g_ExplorePass++;
    } else {
        Print("[FAIL][explore] ", testName,
              (StringLen(detail) > 0 ? (" | " + detail) : ""));
        g_ExploreFail++;
    }
}

// Preservation 断言：验证不变量 / 回归保护
void AssertPreserve(bool condition, string testName, string detail = "")
{
    if (condition) {
        Print("[PASS][preserve] ", testName);
        g_PreservePass++;
    } else {
        Print("[FAIL][preserve] ", testName,
              (StringLen(detail) > 0 ? (" | " + detail) : ""));
        g_PreserveFail++;
    }
}

// 通用断言（不区分类型，计入 preserve）
void Assert(bool condition, string testName, string detail = "")
{
    AssertPreserve(condition, testName, detail);
}

// ── 主入口（在 OnInit 调用）──────────────────────────────────────────────────

// 测试 EA 必须实现此函数
void RunTests();

void RunAllTests()
{
    g_ExplorePass = g_ExploreFail = g_PreservePass = g_PreserveFail = 0;

    Print("========== EA Test Start ==========");
    RunTests();
    Print("========== EA Test End ==========");

    int totalFail = g_ExploreFail + g_PreserveFail;
    Print("AUTO_TEST_SUMMARY: explore_pass=", g_ExplorePass,
          " explore_fail=", g_ExploreFail,
          " preserve_pass=", g_PreservePass,
          " preserve_fail=", g_PreserveFail,
          " total_fail=", totalFail);
    Print("AUTO_TEST_RESULT: ", (totalFail == 0 ? "PASS" : "FAIL"));
}
