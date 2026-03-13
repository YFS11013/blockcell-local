//+------------------------------------------------------------------+
//|                                            PositionManager.mqh   |
//|                        MT4 Forex Strategy Executor System V1.0   |
//|                                                                  |
//| 模块：持仓管理器                                                  |
//| 职责：跟踪所有持仓、监控止损和止盈、处理部分平仓、更新持仓状态     |
//+------------------------------------------------------------------+
#property strict

#ifndef POSITION_MANAGER_MQH
#define POSITION_MANAGER_MQH

#include "Logger.mqh"
#include "RiskManager.mqh"

//+------------------------------------------------------------------+
//| 持仓统计结构体                                                    |
//+------------------------------------------------------------------+
struct PositionStats {
    int total_positions;      // 总持仓数
    double total_lots;        // 总手数
    double total_profit;      // 总盈利
    double total_loss;        // 总亏损
};

//+------------------------------------------------------------------+
//| 持仓订单信息结构体                                                |
//+------------------------------------------------------------------+
struct PositionOrderInfo {
    int ticket;               // 订单号
    double open_price;        // 开仓价格
    double stop_loss;         // 止损价格
    double take_profit;       // 止盈价格
    double lots;              // 手数
    datetime open_time;       // 开仓时间
    double actual_slippage;   // 实际滑点
    string comment;           // 订单备注
    int cmd;                  // 订单类型
    double current_profit;    // 当前盈亏
};

//+------------------------------------------------------------------+
//| 全局变量                                                          |
//+------------------------------------------------------------------+

// 已跟踪的订单列表（用于检测平仓事件）
int g_TrackedOrders[];

//+------------------------------------------------------------------+
//| 初始化持仓管理器                                                  |
//+------------------------------------------------------------------+
void InitPositionManager()
{
    LogInfo("PositionManager", "持仓管理器初始化");
    
    // 初始化跟踪列表
    ArrayResize(g_TrackedOrders, 0);
    
    // 扫描现有持仓
    int positions[];
    int count = GetOpenPositions(positions);
    
    if(count > 0) {
        LogInfo("PositionManager", "检测到 " + IntegerToString(count) + " 个现有持仓");
        
        // 将现有持仓加入跟踪列表
        ArrayResize(g_TrackedOrders, count);
        for(int i = 0; i < count; i++) {
            g_TrackedOrders[i] = positions[i];
        }
    } else {
        LogInfo("PositionManager", "当前无持仓");
    }
}

//+------------------------------------------------------------------+
//| 获取所有持仓订单                                                  |
//| 返回：持仓订单数量                                                |
//| 参数：positions - 输出数组，存储订单号                            |
//+------------------------------------------------------------------+
int GetOpenPositions(int &positions[])
{
    ArrayResize(positions, 0);
    
    int total = OrdersTotal();
    int count = 0;
    
    for(int i = 0; i < total; i++) {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            LogWarn("PositionManager", "OrderSelect 失败，索引: " + IntegerToString(i));
            continue;
        }
        
        // 只处理当前品种的订单
        if(OrderSymbol() != Symbol()) {
            continue;
        }
        
        // 只处理市价单（持仓）
        int order_type = OrderType();
        if(order_type != OP_BUY && order_type != OP_SELL) {
            continue;
        }
        
        // 添加到结果数组
        ArrayResize(positions, count + 1);
        positions[count] = OrderTicket();
        count++;
    }
    
    LogDebug("PositionManager", "扫描到 " + IntegerToString(count) + " 个持仓订单");
    
    return count;
}

//+------------------------------------------------------------------+
//| 获取订单详细信息                                                  |
//| 返回：是否成功获取                                                |
//| 参数：ticket - 订单号                                             |
//|       info - 输出结构体，存储订单信息                             |
//+------------------------------------------------------------------+
bool GetPositionOrderInfo(int ticket, PositionOrderInfo &info)
{
    if(!OrderSelect(ticket, SELECT_BY_TICKET)) {
        LogWarn("PositionManager", "OrderSelect 失败，订单号: " + IntegerToString(ticket));
        return false;
    }
    
    // 填充订单信息
    info.ticket = OrderTicket();
    info.open_price = OrderOpenPrice();
    info.stop_loss = OrderStopLoss();
    info.take_profit = OrderTakeProfit();
    info.lots = OrderLots();
    info.open_time = OrderOpenTime();
    info.comment = OrderComment();
    info.cmd = OrderType();
    info.current_profit = OrderProfit() + OrderSwap() + OrderCommission();
    
    // 计算实际滑点（如果是刚开仓的订单）
    // 注意：这里假设订单备注中包含预期开仓价格信息
    // 实际实现中，可能需要在开仓时记录预期价格
    info.actual_slippage = 0.0;  // 简化实现
    
    return true;
}

//+------------------------------------------------------------------+
//| 获取持仓统计信息                                                  |
//| 返回：持仓统计结构体                                              |
//+------------------------------------------------------------------+
PositionStats GetPositionStats()
{
    PositionStats stats;
    stats.total_positions = 0;
    stats.total_lots = 0.0;
    stats.total_profit = 0.0;
    stats.total_loss = 0.0;
    
    int positions[];
    int count = GetOpenPositions(positions);
    
    stats.total_positions = count;
    
    for(int i = 0; i < count; i++) {
        PositionOrderInfo info;
        if(GetPositionOrderInfo(positions[i], info)) {
            stats.total_lots += info.lots;
            
            if(info.current_profit > 0) {
                stats.total_profit += info.current_profit;
            } else {
                stats.total_loss += info.current_profit;
            }
        }
    }
    
    LogDebug("PositionManager", 
             "持仓统计: 数量=" + IntegerToString(stats.total_positions) + 
             ", 手数=" + DoubleToString(stats.total_lots, 2) + 
             ", 盈利=" + DoubleToString(stats.total_profit, 2) + 
             ", 亏损=" + DoubleToString(stats.total_loss, 2));
    
    return stats;
}

//+------------------------------------------------------------------+
//| 检查订单是否存在                                                  |
//| 返回：订单是否存在                                                |
//| 参数：ticket - 订单号                                             |
//+------------------------------------------------------------------+
bool IsOrderExists(int ticket)
{
    if(!OrderSelect(ticket, SELECT_BY_TICKET)) {
        return false;
    }
    
    // 检查订单是否已关闭
    if(OrderCloseTime() != 0) {
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 从跟踪列表中移除订单                                              |
//| 参数：ticket - 订单号                                             |
//+------------------------------------------------------------------+
void RemoveFromTrackedOrders(int ticket)
{
    int size = ArraySize(g_TrackedOrders);
    int new_size = 0;
    int temp[];
    ArrayResize(temp, size);
    
    // 复制除了指定订单外的所有订单
    for(int i = 0; i < size; i++) {
        if(g_TrackedOrders[i] != ticket) {
            temp[new_size] = g_TrackedOrders[i];
            new_size++;
        }
    }
    
    // 更新跟踪列表
    ArrayResize(g_TrackedOrders, new_size);
    for(int i = 0; i < new_size; i++) {
        g_TrackedOrders[i] = temp[i];
    }
    
    LogDebug("PositionManager", "从跟踪列表移除订单: " + IntegerToString(ticket));
}

//+------------------------------------------------------------------+
//| 添加订单到跟踪列表                                                |
//| 参数：ticket - 订单号                                             |
//+------------------------------------------------------------------+
void AddToTrackedOrders(int ticket)
{
    int size = ArraySize(g_TrackedOrders);
    
    // 检查是否已存在
    for(int i = 0; i < size; i++) {
        if(g_TrackedOrders[i] == ticket) {
            LogDebug("PositionManager", "订单已在跟踪列表中: " + IntegerToString(ticket));
            return;
        }
    }
    
    // 添加到列表
    ArrayResize(g_TrackedOrders, size + 1);
    g_TrackedOrders[size] = ticket;
    
    LogDebug("PositionManager", "添加订单到跟踪列表: " + IntegerToString(ticket));
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| 检查持仓状态                                                      |
//| 职责：检查订单是否已平仓，触发交易结果记录                         |
//+------------------------------------------------------------------+
void CheckPositions()
{
    // 获取当前所有持仓
    int current_positions[];
    int current_count = GetOpenPositions(current_positions);
    
    // 检查跟踪列表中的订单是否已平仓
    int tracked_size = ArraySize(g_TrackedOrders);
    
    for(int i = 0; i < tracked_size; i++) {
        int ticket = g_TrackedOrders[i];
        
        // 检查订单是否仍然存在
        if(!IsOrderExists(ticket)) {
            // 订单已平仓，记录交易结果
            LogInfo("PositionManager", "检测到订单已平仓: " + IntegerToString(ticket));
            
            // 获取订单信息（从历史订单中）
            if(OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY)) {
                double profit = OrderProfit() + OrderSwap() + OrderCommission();
                datetime close_time = OrderCloseTime();
                double close_price = OrderClosePrice();
                
                LogInfo("PositionManager", 
                        "订单 " + IntegerToString(ticket) + " 平仓详情: " +
                        "平仓价=" + DoubleToString(close_price, 5) + 
                        ", 盈亏=" + DoubleToString(profit, 2) + 
                        ", 平仓时间=" + TimeToString(close_time));
                
                // 记录交易结果到风险管理器
                RecordTradeResult(ticket, profit);
                
                // 记录到日志
                LogOrderClose(ticket, profit, close_price, close_time);
            } else {
                LogWarn("PositionManager", "无法从历史订单中获取订单信息: " + IntegerToString(ticket));
            }
            
            // 从跟踪列表中移除
            RemoveFromTrackedOrders(ticket);
            
            // 由于修改了数组，需要重新开始循环
            i--;
            tracked_size = ArraySize(g_TrackedOrders);
        }
    }
    
    // 检查是否有新的持仓需要加入跟踪列表
    for(int i = 0; i < current_count; i++) {
        int ticket = current_positions[i];
        
        // 检查是否已在跟踪列表中
        bool is_tracked = false;
        for(int j = 0; j < ArraySize(g_TrackedOrders); j++) {
            if(g_TrackedOrders[j] == ticket) {
                is_tracked = true;
                break;
            }
        }
        
        // 如果不在跟踪列表中，添加进去
        if(!is_tracked) {
            LogInfo("PositionManager", "检测到新持仓，加入跟踪列表: " + IntegerToString(ticket));
            AddToTrackedOrders(ticket);
        }
    }
    
    // 定期输出持仓统计（每小时一次）
    static datetime last_stats_time = 0;
    if(TimeCurrent() - last_stats_time >= 3600) {
        PositionStats stats = GetPositionStats();
        
        if(stats.total_positions > 0) {
            LogInfo("PositionManager", 
                    "持仓统计报告: " +
                    "数量=" + IntegerToString(stats.total_positions) + 
                    ", 总手数=" + DoubleToString(stats.total_lots, 2) + 
                    ", 总盈利=" + DoubleToString(stats.total_profit, 2) + 
                    ", 总亏损=" + DoubleToString(stats.total_loss, 2) + 
                    ", 净盈亏=" + DoubleToString(stats.total_profit + stats.total_loss, 2));
        }
        
        last_stats_time = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
//| 记录订单平仓到日志                                                |
//| 参数：ticket - 订单号                                             |
//|       profit - 盈亏金额                                           |
//|       close_price - 平仓价格                                      |
//|       close_time - 平仓时间                                       |
//+------------------------------------------------------------------+
void LogOrderClose(int ticket, double profit, double close_price, datetime close_time)
{
    string decision = (profit > 0) ? "PROFIT" : "LOSS";
    
    string message = "订单平仓: " +
                    "ticket=" + IntegerToString(ticket) + 
                    ", close_price=" + DoubleToString(close_price, 5) + 
                    ", profit=" + DoubleToString(profit, 2) + 
                    ", close_time=" + TimeToString(close_time) + 
                    ", decision=" + decision;
    
    if(profit > 0) {
        LogInfo("PositionManager", message);
    } else {
        LogWarn("PositionManager", message);
    }
}

//+------------------------------------------------------------------+
//| 清理持仓管理器资源                                                |
//+------------------------------------------------------------------+
void CleanupPositionManager()
{
    LogInfo("PositionManager", "清理持仓管理器资源");
    
    // 清空跟踪列表
    ArrayResize(g_TrackedOrders, 0);
}

//+------------------------------------------------------------------+
//| 获取跟踪订单数量                                                  |
//| 返回：跟踪订单数量                                                |
//+------------------------------------------------------------------+
int GetTrackedOrderCount()
{
    return ArraySize(g_TrackedOrders);
}

//+------------------------------------------------------------------+
//| 打印跟踪列表（调试用）                                            |
//+------------------------------------------------------------------+
void PrintTrackedOrders()
{
    int size = ArraySize(g_TrackedOrders);
    
    if(size == 0) {
        LogDebug("PositionManager", "跟踪列表为空");
        return;
    }
    
    string list = "跟踪列表 (" + IntegerToString(size) + " 个订单): ";
    for(int i = 0; i < size; i++) {
        if(i > 0) list += ", ";
        list += IntegerToString(g_TrackedOrders[i]);
    }
    
    LogDebug("PositionManager", list);
}

//+------------------------------------------------------------------+

#endif // POSITION_MANAGER_MQH
