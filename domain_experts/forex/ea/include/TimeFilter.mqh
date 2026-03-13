//+------------------------------------------------------------------+
//|                                                   TimeFilter.mqh |
//|                        MT4 Forex Strategy Executor - Time Filter |
//|                                                                  |
//| 描述：时间过滤器模块                                              |
//| 功能：                                                            |
//|   - 新闻窗口过滤（禁开仓时间窗口）                                |
//|   - 交易时段过滤（允许交易的时段）                                |
//|   - UTC 时间判断                                                 |
//+------------------------------------------------------------------+
#property copyright "MT4 Forex Strategy Executor"
#property strict

#ifndef TIME_FILTER_MQH
#define TIME_FILTER_MQH

// 引入依赖
#include "TimeUtils.mqh"
#include "ParameterLoader.mqh"

//+------------------------------------------------------------------+
//| 检查当前时间是否在新闻禁开仓窗口内                                 |
//| 参数：                                                            |
//|   blackouts - 新闻禁开仓窗口数组                                  |
//|   blackout_count - 窗口数量                                      |
//| 返回：                                                            |
//|   true - 在禁开仓窗口内，false - 不在窗口内                       |
//| 说明：                                                            |
//|   - 使用 UTC 时间判断                                            |
//|   - 支持多个时间窗口                                             |
//|   - 正确处理窗口重叠情况                                         |
//|   - 只要在任一窗口内，就返回 true                                |
//+------------------------------------------------------------------+
bool IsInNewsBlackout(NewsBlackout &blackouts[], int blackout_count)
{
    // 如果没有配置新闻窗口，直接返回 false
    if(blackout_count <= 0) {
        return false;
    }
    
    // 获取当前 UTC 时间
    datetime current_utc = GetCurrentUTC();
    
    // 遍历所有新闻窗口
    for(int i = 0; i < blackout_count; i++) {
        // 检查当前时间是否在窗口内
        if(current_utc >= blackouts[i].start && current_utc <= blackouts[i].end) {
            // 在窗口内，记录日志
            Print("INFO: [TimeFilter] 当前时间在新闻禁开仓窗口内");
            Print("  当前 UTC 时间: ", TimeToString(current_utc, TIME_DATE|TIME_SECONDS));
            Print("  窗口开始: ", TimeToString(blackouts[i].start, TIME_DATE|TIME_SECONDS));
            Print("  窗口结束: ", TimeToString(blackouts[i].end, TIME_DATE|TIME_SECONDS));
            Print("  原因: ", blackouts[i].reason);
            
            return true;
        }
    }
    
    // 不在任何窗口内
    return false;
}

//+------------------------------------------------------------------+
//| 检查当前时间是否在允许的交易时段内                                 |
//| 参数：                                                            |
//|   filter - 交易时段过滤配置                                       |
//| 返回：                                                            |
//|   true - 在允许的交易时段内，false - 不在允许的时段内             |
//| 说明：                                                            |
//|   - 使用 UTC 时间判断                                            |
//|   - 如果 filter.enabled = false，直接返回 true                   |
//|   - 检查当前小时是否在 allowed_hours_utc 数组中                  |
//+------------------------------------------------------------------+
bool IsInTradingSession(SessionFilter &filter)
{
    // 如果未启用时段过滤，直接返回 true
    if(!filter.enabled) {
        return true;
    }
    
    // 如果没有配置允许的小时，返回 false（保守策略）
    if(filter.allowed_count <= 0) {
        Print("WARN: [TimeFilter] 时段过滤已启用但未配置允许的小时");
        return false;
    }
    
    // 获取当前 UTC 时间
    datetime current_utc = GetCurrentUTC();
    int current_hour = TimeHour(current_utc);
    
    // 检查当前小时是否在允许的小时数组中
    for(int i = 0; i < filter.allowed_count; i++) {
        if(current_hour == filter.allowed_hours_utc[i]) {
            // 在允许的时段内
            return true;
        }
    }
    
    // 不在允许的时段内，记录日志
    Print("INFO: [TimeFilter] 当前时间不在允许的交易时段内");
    Print("  当前 UTC 时间: ", TimeToString(current_utc, TIME_DATE|TIME_SECONDS));
    Print("  当前 UTC 小时: ", current_hour);
    
    return false;
}

//+------------------------------------------------------------------+
//| 检查是否允许开仓（综合时间过滤）                                   |
//| 参数：                                                            |
//|   params - 参数包                                                |
//| 返回：                                                            |
//|   true - 允许开仓，false - 禁止开仓                              |
//| 说明：                                                            |
//|   - 综合检查新闻窗口和交易时段                                    |
//|   - 任一条件不满足，都禁止开仓                                    |
//+------------------------------------------------------------------+
bool CanOpenByTimeFilter(ParameterPack &params)
{
    // 检查新闻窗口
    if(IsInNewsBlackout(params.news_blackouts, params.blackout_count)) {
        Print("WARN: [TimeFilter] 拒绝开仓 - 在新闻禁开仓窗口内");
        return false;
    }
    
    // 检查交易时段
    if(!IsInTradingSession(params.session_filter)) {
        Print("WARN: [TimeFilter] 拒绝开仓 - 不在允许的交易时段内");
        return false;
    }
    
    // 所有时间过滤条件都满足
    return true;
}

//+------------------------------------------------------------------+
//| 测试时间过滤器函数                                                 |
//+------------------------------------------------------------------+
void TestTimeFilter()
{
    Print("========== TimeFilter 测试 ==========");
    
    // 测试 1：新闻窗口过滤
    Print("--- 测试 1：新闻窗口过滤 ---");
    
    NewsBlackout blackouts[3];
    
    // 创建测试窗口（当前时间前后各 1 小时）
    datetime current_utc = GetCurrentUTC();
    
    blackouts[0].start = current_utc - 3600;  // 1 小时前
    blackouts[0].end = current_utc + 3600;    // 1 小时后
    blackouts[0].reason = "测试窗口 1";
    
    blackouts[1].start = current_utc + 7200;  // 2 小时后
    blackouts[1].end = current_utc + 10800;   // 3 小时后
    blackouts[1].reason = "测试窗口 2";
    
    blackouts[2].start = current_utc - 7200;  // 2 小时前
    blackouts[2].end = current_utc - 3600;    // 1 小时前
    blackouts[2].reason = "测试窗口 3（已过期）";
    
    // 测试当前时间（应该在窗口 1 内）
    bool in_blackout = IsInNewsBlackout(blackouts, 3);
    Print("当前时间在新闻窗口内: ", in_blackout ? "是" : "否");
    Print("预期结果: 是（在窗口 1 内）");
    
    // 测试空数组
    NewsBlackout empty_blackouts[1];
    bool in_empty = IsInNewsBlackout(empty_blackouts, 0);
    Print("空数组测试: ", in_empty ? "在窗口内" : "不在窗口内");
    Print("预期结果: 不在窗口内");
    
    // 测试 2：交易时段过滤
    Print("--- 测试 2：交易时段过滤 ---");
    
    SessionFilter filter;
    filter.enabled = true;
    filter.allowed_count = 9;
    
    // 配置允许的小时（8-16 UTC）
    for(int i = 0; i < 9; i++) {
        filter.allowed_hours_utc[i] = 8 + i;
    }
    
    // 测试当前时间
    bool in_session = IsInTradingSession(filter);
    int current_hour = TimeHour(current_utc);
    Print("当前 UTC 小时: ", current_hour);
    Print("在允许的交易时段内: ", in_session ? "是" : "否");
    
    // 测试禁用时段过滤
    filter.enabled = false;
    bool in_session_disabled = IsInTradingSession(filter);
    Print("禁用时段过滤: ", in_session_disabled ? "允许" : "禁止");
    Print("预期结果: 允许");
    
    // 测试 3：综合时间过滤
    Print("--- 测试 3：综合时间过滤 ---");
    
    ParameterPack test_params;
    InitParameterPack(test_params);
    
    // 配置参数
    test_params.blackout_count = 3;
    for(int i = 0; i < 3; i++) {
        test_params.news_blackouts[i] = blackouts[i];
    }
    
    test_params.session_filter = filter;
    test_params.session_filter.enabled = true;
    
    bool can_open = CanOpenByTimeFilter(test_params);
    Print("综合时间过滤结果: ", can_open ? "允许开仓" : "禁止开仓");
    
    Print("========== 测试完成 ==========");
}

//+------------------------------------------------------------------+

#endif // TIME_FILTER_MQH
