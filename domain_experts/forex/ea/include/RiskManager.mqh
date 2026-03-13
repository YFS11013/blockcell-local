//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|                        MT4 Forex Strategy Executor - Risk Manager|
//|                                                                  |
//| 描述：风险管理模块                                                |
//| 功能：                                                            |
//|   - 手数计算                                                     |
//|   - 拆单逻辑                                                     |
//|   - 点差检查                                                     |
//|   - 日亏损熔断                                                   |
//|   - 连续亏损熔断                                                 |
//|   - 熔断恢复                                                     |
//|   - 交易结果记录                                                 |
//+------------------------------------------------------------------+
#property copyright "MT4 Forex Strategy Executor"
#property strict

#ifndef RISK_MANAGER_MQH
#define RISK_MANAGER_MQH

// 包含时间工具
#include "TimeUtils.mqh"

//+------------------------------------------------------------------+
//| 拆单结构体                                                        |
//+------------------------------------------------------------------+
struct LotSplit
{
    double lots;        // 手数
    double tp_price;    // 止盈价格
};

//+------------------------------------------------------------------+
//| 风险状态结构体                                                    |
//+------------------------------------------------------------------+
struct RiskState
{
    double daily_profit;              // 当日盈亏
    int consecutive_losses;           // 连续亏损笔数
    datetime circuit_breaker_until;   // 熔断恢复时间（UTC）
    bool is_safe_mode;                // 是否处于安全模式
    int last_reset_date;              // 上次重置日期（YYYYMMDD）
};

// 全局风险状态
RiskState g_risk_state;

//+------------------------------------------------------------------+
//| 初始化风险状态                                                    |
//+------------------------------------------------------------------+
void InitRiskState()
{
    g_risk_state.daily_profit = 0.0;
    g_risk_state.consecutive_losses = 0;
    g_risk_state.circuit_breaker_until = 0;
    g_risk_state.is_safe_mode = false;
    g_risk_state.last_reset_date = GetCurrentUTCDate();
    
    Print("INFO: RiskManager - 风险状态已初始化");
}

//+------------------------------------------------------------------+
//| 计算开仓手数                                                      |
//| 参数：                                                            |
//|   entry - 入场价格                                               |
//|   stop_loss - 止损价格                                           |
//|   risk_percent - 风险百分比（如 0.01 表示 1%）                   |
//| 返回：                                                            |
//|   规范化后的手数                                                 |
//| 说明：                                                            |
//|   1. 计算风险金额 = 账户余额 * risk_percent                      |
//|   2. 计算点数风险（使用绝对值）                                   |
//|   3. 计算手数                                                    |
//|   4. 规范化到 lot_step、min_lot、max_lot                         |
//+------------------------------------------------------------------+
double CalculatePositionSize(double entry, double stop_loss, double risk_percent)
{
    // 1. 计算风险金额（使用账户净值 Equity）
    double account_equity = AccountEquity();
    double risk_amount = account_equity * risk_percent;
    
    // 2. 计算点数风险（使用绝对值）
    double pip_risk = MathAbs(entry - stop_loss) / Point;
    
    if(pip_risk <= 0) {
        Print("ERROR: CalculatePositionSize - 无效的点数风险: ", pip_risk);
        return 0.0;
    }
    
    // 3. 计算手数
    double tick_value = MarketInfo(Symbol(), MODE_TICKVALUE);
    if(tick_value <= 0) {
        Print("ERROR: CalculatePositionSize - 无效的 TICKVALUE: ", tick_value);
        return 0.0;
    }
    
    double lots = risk_amount / (pip_risk * tick_value);
    
    // 4. 规范化手数
    double lot_step = MarketInfo(Symbol(), MODE_LOTSTEP);
    double min_lot = MarketInfo(Symbol(), MODE_MINLOT);
    double max_lot = MarketInfo(Symbol(), MODE_MAXLOT);
    
    // 校验 lot_step 有效性（防止除零）
    if(lot_step <= 0) {
        Print("ERROR: CalculatePositionSize - 无效的 LOTSTEP: ", lot_step);
        return 0.0;
    }
    
    // 向下取整到 lot_step
    lots = MathFloor(lots / lot_step) * lot_step;
    
    // 检查是否低于最小手数
    if(lots < min_lot) {
        // 不能上调到 min_lot，因为会超过风险限制
        // 返回 0 表示无法满足风险约束
        Print("WARN: CalculatePositionSize - 计算手数 ", lots, 
              " 低于最小手数 ", min_lot, 
              ", 无法满足风险约束，拒绝开仓");
        return 0.0;
    }
    
    // 确保不超过最大手数
    if(lots > max_lot) {
        lots = max_lot;
        Print("WARN: CalculatePositionSize - 手数超过最大值，调整为 ", max_lot);
    }
    
    Print("INFO: CalculatePositionSize - 入场=", entry, 
          ", 止损=", stop_loss, 
          ", 风险%=", risk_percent * 100, 
          ", 计算手数=", lots);
    
    return lots;
}

//+------------------------------------------------------------------+
//| 拆分手数到多个订单                                                |
//| 参数：                                                            |
//|   total_lots - 总手数                                            |
//|   ratios[] - 手数比例数组（总和应为 1.0）                        |
//|   tp_levels[] - 止盈价格数组                                     |
//|   tp_count - 实际止盈数量（用于处理定长数组）                    |
//|   splits[] - 输出的拆单结果数组                                  |
//| 返回：                                                            |
//|   true - 成功，false - 失败                                      |
//| 说明：                                                            |
//|   1. 按 ratios 拆分手数                                          |
//|   2. 规范化每个手数到 lot_step                                   |
//|   3. 将余量分配到最后一个订单                                     |
//|   4. 再次规范化并校验约束                                         |
//|   5. 验证总和误差 <= lot_step                                    |
//|   注意：使用 tp_count 而非 ArraySize，避免定长数组尾部无效元素   |
//+------------------------------------------------------------------+
bool SplitLots(double total_lots, double &ratios[], double &tp_levels[], int tp_count, LotSplit &splits[])
{
    // 检查参数有效性
    if(tp_count <= 0 || tp_count > ArraySize(ratios) || tp_count > ArraySize(tp_levels)) {
        Print("ERROR: SplitLots - 无效的 tp_count: ", tp_count, 
              ", ratios size=", ArraySize(ratios), 
              ", tp_levels size=", ArraySize(tp_levels));
        return false;
    }
    
    // 获取市场信息
    double lot_step = MarketInfo(Symbol(), MODE_LOTSTEP);
    double min_lot = MarketInfo(Symbol(), MODE_MINLOT);
    double max_lot = MarketInfo(Symbol(), MODE_MAXLOT);
    
    // 校验 lot_step 有效性（防止除零）
    if(lot_step <= 0) {
        Print("ERROR: SplitLots - 无效的 LOTSTEP: ", lot_step);
        return false;
    }
    
    // 调整数组大小
    ArrayResize(splits, tp_count);
    
    // 1. 计算每个订单的目标手数
    double target_lots[];
    ArrayResize(target_lots, tp_count);
    
    for(int i = 0; i < tp_count; i++) {
        target_lots[i] = total_lots * ratios[i];
    }
    
    // 2. 规范化每个手数到 lot_step
    double normalized_lots[];
    ArrayResize(normalized_lots, tp_count);
    
    for(int i = 0; i < tp_count; i++) {
        normalized_lots[i] = MathFloor(target_lots[i] / lot_step) * lot_step;
    }
    
    // 3. 计算余量
    double sum = 0;
    for(int i = 0; i < tp_count; i++) {
        sum += normalized_lots[i];
    }
    double remainder = total_lots - sum;
    
    // 4. 将余量分配到最后一个订单
    normalized_lots[tp_count - 1] += remainder;
    
    // 5. 再次规范化最后一个订单
    normalized_lots[tp_count - 1] = MathRound(normalized_lots[tp_count - 1] / lot_step) * lot_step;
    
    // 6. 确保每个订单在范围内
    for(int i = 0; i < tp_count; i++) {
        if(normalized_lots[i] < min_lot) {
            normalized_lots[i] = min_lot;
        }
        if(normalized_lots[i] > max_lot) {
            // 如果超过 max_lot，尝试将超出部分分配到前一个订单
            if(i > 0) {
                double excess = normalized_lots[i] - max_lot;
                normalized_lots[i] = max_lot;
                normalized_lots[i - 1] += excess;
                // 再次规范化前一个订单
                normalized_lots[i - 1] = MathRound(normalized_lots[i - 1] / lot_step) * lot_step;
                if(normalized_lots[i - 1] > max_lot) {
                    normalized_lots[i - 1] = max_lot;
                }
            } else {
                normalized_lots[i] = max_lot;
            }
        }
    }
    
    // 7. 最终验证：总和误差 <= lot_step
    sum = 0;
    for(int i = 0; i < tp_count; i++) {
        sum += normalized_lots[i];
    }
    double error = MathAbs(sum - total_lots);
    
    if(error > lot_step) {
        Print("ERROR: SplitLots - 拆单误差过大: ", error, " > ", lot_step);
        return false;
    }
    
    // 8. 填充结果
    for(int i = 0; i < tp_count; i++) {
        splits[i].lots = normalized_lots[i];
        splits[i].tp_price = tp_levels[i];
    }
    
    Print("INFO: SplitLots - 总手数=", total_lots, 
          ", 拆分数量=", tp_count, 
          ", 实际总和=", sum, 
          ", 误差=", error);
    
    for(int i = 0; i < tp_count; i++) {
        Print("  订单 ", i + 1, ": 手数=", splits[i].lots, ", 止盈=", splits[i].tp_price);
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 检查点差是否超过阈值                                              |
//| 参数：                                                            |
//|   max_spread_points - 最大允许点差（点数）                       |
//| 返回：                                                            |
//|   true - 点差在允许范围内，false - 点差超限                      |
//+------------------------------------------------------------------+
bool CheckSpread(double max_spread_points)
{
    // 获取当前买卖价
    double ask = MarketInfo(Symbol(), MODE_ASK);
    double bid = MarketInfo(Symbol(), MODE_BID);
    
    // 计算点差（点数）
    double current_spread = (ask - bid) / Point;
    
    // 判断是否超过阈值
    bool is_ok = (current_spread <= max_spread_points);
    
    if(!is_ok) {
        Print("WARN: CheckSpread - 点差超限: ", current_spread, " > ", max_spread_points);
    } else {
        Print("INFO: CheckSpread - 点差正常: ", current_spread, " <= ", max_spread_points);
    }
    
    return is_ok;
}

//+------------------------------------------------------------------+
//| 检查并处理日亏损熔断                                              |
//| 参数：                                                            |
//|   daily_max_loss - 单日最大亏损百分比（如 0.02 表示 2%）         |
//| 返回：                                                            |
//|   true - 允许交易，false - 触发熔断                              |
//| 说明：                                                            |
//|   1. 检查是否需要日切重置                                         |
//|   2. 检查当日累计亏损是否超过阈值                                 |
//|   3. 触发熔断时设置恢复时间为今天 23:59:59 UTC                   |
//+------------------------------------------------------------------+
bool CheckDailyLoss(double daily_max_loss)
{
    // 1. 检查是否需要日切重置
    int current_date = GetCurrentUTCDate();
    
    if(current_date != g_risk_state.last_reset_date) {
        // 日切，重置当日盈亏
        Print("INFO: CheckDailyLoss - 日切重置: ", 
              g_risk_state.last_reset_date, " -> ", current_date);
        g_risk_state.daily_profit = 0.0;
        g_risk_state.last_reset_date = current_date;
    }
    
    // 2. 检查当日累计亏损（使用账户净值 Equity）
    double account_equity = AccountEquity();
    double max_loss_amount = -account_equity * daily_max_loss;  // 负数
    
    if(g_risk_state.daily_profit <= max_loss_amount) {
        // 触发日亏损熔断
        
        // 3. 计算今天 23:59:59 UTC 的 datetime
        datetime current_utc = GetCurrentUTC();
        int current_seconds = TimeHour(current_utc) * 3600 + 
                             TimeMinute(current_utc) * 60 + 
                             TimeSeconds(current_utc);
        datetime today_end_utc = current_utc - current_seconds + (24 * 3600 - 1);
        
        g_risk_state.circuit_breaker_until = today_end_utc;
        
        Print("ERROR: CheckDailyLoss - 触发日亏损熔断: ",
              "当日盈亏=", g_risk_state.daily_profit,
              ", 阈值=", max_loss_amount,
              ", 恢复时间=", TimeToString(today_end_utc, TIME_DATE|TIME_SECONDS));
        
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 检查并处理连续亏损熔断                                            |
//| 参数：                                                            |
//|   consecutive_loss_limit - 连续亏损笔数限制                      |
//| 返回：                                                            |
//|   true - 允许交易，false - 触发熔断                              |
//| 说明：                                                            |
//|   触发熔断时设置恢复时间为当前时间 + 24 小时                      |
//+------------------------------------------------------------------+
bool CheckConsecutiveLoss(int consecutive_loss_limit)
{
    if(g_risk_state.consecutive_losses >= consecutive_loss_limit) {
        // 触发连续亏损熔断
        
        // 设置熔断恢复时间为当前时间（UTC）+ 24 小时
        datetime current_utc = GetCurrentUTC();
        g_risk_state.circuit_breaker_until = current_utc + 24 * 3600;
        
        Print("ERROR: CheckConsecutiveLoss - 触发连续亏损熔断: ",
              "连续亏损=", g_risk_state.consecutive_losses,
              ", 限制=", consecutive_loss_limit,
              ", 恢复时间=", TimeToString(g_risk_state.circuit_breaker_until, TIME_DATE|TIME_SECONDS));
        
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 检查并恢复熔断状态                                                |
//| 返回：                                                            |
//|   true - 已恢复或无熔断，false - 仍在熔断中                      |
//| 说明：                                                            |
//|   检查当前 UTC 时间是否超过 circuit_breaker_until                |
//|   如果超过，自动恢复正常交易状态                                  |
//+------------------------------------------------------------------+
bool CheckCircuitBreakerRecovery()
{
    // 如果没有熔断，直接返回 true
    if(g_risk_state.circuit_breaker_until == 0) {
        return true;
    }
    
    // 检查当前 UTC 时间是否超过熔断恢复时间
    datetime current_utc = GetCurrentUTC();
    
    if(current_utc > g_risk_state.circuit_breaker_until) {
        // 恢复正常交易状态
        Print("INFO: CheckCircuitBreakerRecovery - 熔断已恢复: ",
              "当前时间=", TimeToString(current_utc, TIME_DATE|TIME_SECONDS),
              ", 恢复时间=", TimeToString(g_risk_state.circuit_breaker_until, TIME_DATE|TIME_SECONDS));
        
        g_risk_state.circuit_breaker_until = 0;
        return true;
    }
    
    // 仍在熔断中
    Print("WARN: CheckCircuitBreakerRecovery - 仍在熔断中: ",
          "当前时间=", TimeToString(current_utc, TIME_DATE|TIME_SECONDS),
          ", 恢复时间=", TimeToString(g_risk_state.circuit_breaker_until, TIME_DATE|TIME_SECONDS));
    
    return false;
}

//+------------------------------------------------------------------+
//| 记录交易结果并更新风险状态                                        |
//| 参数：                                                            |
//|   ticket - 订单号                                                |
//|   profit - 盈亏金额                                              |
//| 说明：                                                            |
//|   1. 更新 daily_profit                                           |
//|   2. 更新 consecutive_losses                                     |
//|      - 盈利时重置为 0                                            |
//|      - 亏损时 +1                                                 |
//+------------------------------------------------------------------+
void RecordTradeResult(int ticket, double profit)
{
    // 1. 更新当日盈亏
    g_risk_state.daily_profit += profit;
    
    // 2. 更新连续亏损计数器
    if(profit > 0) {
        // 盈利，重置连续亏损
        if(g_risk_state.consecutive_losses > 0) {
            Print("INFO: RecordTradeResult - 盈利，重置连续亏损: ",
                  g_risk_state.consecutive_losses, " -> 0");
        }
        g_risk_state.consecutive_losses = 0;
    } else if(profit < 0) {
        // 亏损，增加计数
        g_risk_state.consecutive_losses++;
        Print("WARN: RecordTradeResult - 亏损，连续亏损计数: ",
              g_risk_state.consecutive_losses);
    }
    
    Print("INFO: RecordTradeResult - 订单=", ticket,
          ", 盈亏=", profit,
          ", 当日盈亏=", g_risk_state.daily_profit,
          ", 连续亏损=", g_risk_state.consecutive_losses);
}

//+------------------------------------------------------------------+
//| 检查是否允许开新仓                                                |
//| 参数：                                                            |
//|   daily_max_loss - 单日最大亏损百分比                            |
//|   consecutive_loss_limit - 连续亏损笔数限制                      |
//|   max_spread_points - 最大允许点差（点数）                       |
//| 返回：                                                            |
//|   true - 允许开仓，false - 禁止开仓                              |
//| 说明：                                                            |
//|   综合检查所有风控条件（熔断、日亏损、连续亏损、点差）            |
//+------------------------------------------------------------------+
bool CanOpenNewPosition(double daily_max_loss, int consecutive_loss_limit, double max_spread_points)
{
    // 1. 检查熔断恢复
    if(!CheckCircuitBreakerRecovery()) {
        return false;
    }
    
    // 2. 检查日亏损
    if(!CheckDailyLoss(daily_max_loss)) {
        return false;
    }
    
    // 3. 检查连续亏损
    if(!CheckConsecutiveLoss(consecutive_loss_limit)) {
        return false;
    }
    
    // 4. 检查点差
    if(!CheckSpread(max_spread_points)) {
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 获取风险状态信息（用于日志和调试）                                |
//| 返回：                                                            |
//|   风险状态的字符串描述                                            |
//+------------------------------------------------------------------+
string GetRiskStateInfo()
{
    string info = StringFormat(
        "RiskState: daily_profit=%.2f, consecutive_losses=%d, circuit_breaker_until=%s, last_reset_date=%d",
        g_risk_state.daily_profit,
        g_risk_state.consecutive_losses,
        TimeToString(g_risk_state.circuit_breaker_until, TIME_DATE|TIME_SECONDS),
        g_risk_state.last_reset_date
    );
    
    return info;
}

//+------------------------------------------------------------------+
//| 测试风险管理器函数                                                |
//+------------------------------------------------------------------+
void TestRiskManager()
{
    Print("========== RiskManager 测试 ==========");
    
    // 初始化风险状态
    InitRiskState();
    
    // 测试手数计算
    double entry = 1.1680;
    double stop_loss = 1.1720;
    double risk_percent = 0.01;
    double lots = CalculatePositionSize(entry, stop_loss, risk_percent);
    Print("计算手数: ", lots);
    
    // 测试拆单逻辑
    double ratios[] = {0.3, 0.4, 0.3};
    double tp_levels[] = {1.1550, 1.1500, 1.1350};
    int tp_count = 3;
    LotSplit splits[];
    
    if(SplitLots(lots, ratios, tp_levels, tp_count, splits)) {
        Print("拆单成功");
    }
    
    // 测试点差检查
    bool spread_ok = CheckSpread(20.0);
    Print("点差检查: ", spread_ok ? "通过" : "失败");
    
    // 测试日亏损检查
    bool daily_ok = CheckDailyLoss(0.02);
    Print("日亏损检查: ", daily_ok ? "通过" : "触发熔断");
    
    // 测试连续亏损检查
    bool consecutive_ok = CheckConsecutiveLoss(3);
    Print("连续亏损检查: ", consecutive_ok ? "通过" : "触发熔断");
    
    // 测试交易结果记录
    RecordTradeResult(12345, -100.0);
    RecordTradeResult(12346, -50.0);
    RecordTradeResult(12347, 200.0);
    
    // 打印风险状态
    Print(GetRiskStateInfo());
    
    Print("========== 测试完成 ==========");
}

//+------------------------------------------------------------------+

#endif // RISK_MANAGER_MQH

