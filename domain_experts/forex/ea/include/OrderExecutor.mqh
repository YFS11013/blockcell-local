//+------------------------------------------------------------------+
//|                                              OrderExecutor.mqh   |
//|                        MT4 Forex Strategy Executor - Order Exec  |
//|                                                                  |
//| 描述：订单执行器模块                                              |
//| 功能：                                                            |
//|   - 执行开仓操作                                                 |
//|   - 设置止损和止盈                                               |
//|   - 处理订单错误和重试                                           |
//|   - 记录实际滑点                                                 |
//+------------------------------------------------------------------+
#property copyright "MT4 Forex Strategy Executor"
#property strict

// ===== UNIT TEST 宏重定向（严格隔离，不污染生产构建）=====
#ifdef UNIT_TEST
  #define ORDER_SEND      MockOrderSend
  #define GET_LAST_ERROR  MockGetLastError
#else
  #define ORDER_SEND      OrderSend
  #define GET_LAST_ERROR  GetLastError
#endif
// ===== END UNIT TEST =====

#ifndef ORDER_EXECUTOR_MQH
#define ORDER_EXECUTOR_MQH

// 包含风险管理器（用于 LotSplit 结构体）
#include "RiskManager.mqh"

//+------------------------------------------------------------------+
//| 订单信息结构体                                                    |
//+------------------------------------------------------------------+
struct OrderExecutorInfo
{
    int ticket;              // 订单号
    double open_price;       // 开仓价格
    double stop_loss;        // 止损价格
    double take_profit;      // 止盈价格
    double lots;             // 手数
    datetime open_time;      // 开仓时间
    double actual_slippage;  // 实际滑点（点数）
    string comment;          // 订单备注
};

//+------------------------------------------------------------------+
//| Task 6.3: 错误分类辅助函数                                        |
//| 判断错误是否可重试                                                |
//| 返回：true - 可重试，false - 不可重试                            |
//+------------------------------------------------------------------+
bool IsRetryableError(int error_code)
{
    // 可重试错误列表
    switch(error_code) {
        case 4:    // ERR_SERVER_BUSY - 交易服务器繁忙
        case 6:    // ERR_NO_CONNECTION - 无连接到交易服务器
        case 8:    // ERR_TOO_FREQUENT_REQUESTS - 请求过于频繁
        case 128:  // ERR_TRADE_TIMEOUT - 交易超时
        case 135:  // ERR_PRICE_CHANGED - 价格改变
        case 136:  // ERR_OFF_QUOTES - 无报价
        case 137:  // ERR_BROKER_BUSY - 经纪商繁忙
        case 138:  // ERR_REQUOTE - 重新报价
        case 146:  // ERR_TRADE_CONTEXT_BUSY - 交易上下文繁忙
            return true;
        
        // 不可重试错误
        case 130:  // ERR_INVALID_STOPS - 无效止损
        case 131:  // ERR_INVALID_TRADE_VOLUME - 无效交易量
        case 132:  // ERR_MARKET_CLOSED - 市场关闭
        case 133:  // ERR_TRADE_DISABLED - 交易被禁用
        case 134:  // ERR_NOT_ENOUGH_MONEY - 资金不足
        case 139:  // ERR_ORDER_LOCKED - 订单被锁定
        case 145:  // ERR_MODIFICATION_DENIED - 修改被禁止
        case 148:  // ERR_TRADE_TOO_MANY_ORDERS - 订单数量超过限制
            return false;
        
        default:
            // 未知错误，保守起见不重试
            return false;
    }
}

//+------------------------------------------------------------------+
//| Task 6.1 & 6.3: 实现单笔开仓（含错误处理和重试逻辑）              |
//| 参数：                                                            |
//|   lots - 手数                                                    |
//|   entry - 入场价格（参考价格，实际使用 Bid/Ask）                 |
//|   stop_loss - 止损价格                                           |
//|   take_profit - 止盈价格                                         |
//|   slippage - 最大允许滑点（点数）                                |
//|   magic - EA 魔术号（必须 > 0，用于区分本 EA 订单）              |
//| 返回：                                                            |
//|   订单号（>0 成功，-1 失败）                                     |
//| 说明：                                                            |
//|   1. 校验 magic > 0，否则记录警告并直接返回 -1（不进重试）        |
//|   2. 准备订单参数（V1 固定做空 OP_SELL）                         |
//|   3. 执行 OrderSend（最多重试 3 次）                             |
//|   4. 识别可重试和不可重试错误                                    |
//|   5. 实现重试逻辑（间隔 1 秒）                                   |
//|   6. 记录实际滑点                                                |
//|   7. 所有异常情况优先保护账户安全                                |
//+------------------------------------------------------------------+
int OpenPosition(double lots, double entry, double stop_loss, double take_profit, int slippage, int magic)
{
    Print("========== OpenPosition 开始 ==========");
    Print("参数: lots=", lots, ", entry=", entry, ", sl=", stop_loss, ", tp=", take_profit, ", slippage=", slippage, ", magic=", magic);
    
    // 1. 校验 magic 参数（参数非法不进重试，直接返回失败）
    if(magic <= 0) {
        Print("WARN: OpenPosition called with invalid magic=", magic, ", rejecting (magic must be > 0)");
        Print("========== OpenPosition 结束: 失败（magic 参数非法）==========");
        return -1;
    }
    
    // 2. 准备订单参数
    int cmd = OP_SELL;  // V1 固定做空
    double volume = lots;
    int slippage_points = slippage;
    double stoploss = stop_loss;
    double takeprofit = take_profit;
    string comment = "ForexStrategyExecutor";  // 基础备注，后续可添加版本号等信息
    datetime expiration = 0;  // 过期时间（0 表示不过期）
    color arrow_color = clrRed;  // 箭头颜色
    
    // 2. 执行 OrderSend（最多重试 3 次）
    int max_retries = 3;
    int retry_delay = 1000;  // 1 秒（毫秒）
    
    for(int attempt = 1; attempt <= max_retries; attempt++) {
        // 获取当前价格（每次重试都刷新价格）
        double price = Bid;  // 做空使用 Bid 价
        
        Print("尝试 ", attempt, "/", max_retries, ": Symbol=", Symbol(), ", cmd=OP_SELL, volume=", volume, 
              ", price=", price, ", slippage=", slippage_points, 
              ", sl=", stoploss, ", tp=", takeprofit);
        
        // 执行 OrderSend
        int ticket = ORDER_SEND(Symbol(), cmd, volume, price, slippage_points, 
                              stoploss, takeprofit, comment, magic, expiration, arrow_color);
        
        // 3. 检查结果
        if(ticket > 0) {
            // 开仓成功
            Print("INFO: OpenPosition - 开仓成功, ticket=", ticket, ", 尝试次数=", attempt);
            
            // 4. Task 6.4: 记录实际滑点
            if(OrderSelect(ticket, SELECT_BY_TICKET)) {
                double actual_open_price = OrderOpenPrice();
                double actual_slippage = MathAbs(actual_open_price - price) / Point;
                
                Print("INFO: 实际滑点记录 - 预期价格=", price, 
                      ", 实际成交价=", actual_open_price, 
                      ", 滑点=", DoubleToString(actual_slippage, 1), " 点");
                
                // 检查滑点是否超过允许范围
                if(actual_slippage > slippage_points) {
                    Print("WARN: 实际滑点 (", DoubleToString(actual_slippage, 1), 
                          " 点) 超过允许滑点 (", slippage_points, " 点)");
                    // 注意：订单已经成交，这里只是记录警告
                    // 根据需求 3.6，记录滑点事件到日志
                }
            } else {
                Print("WARN: 无法选择订单 ", ticket, " 来记录滑点，错误码=", GET_LAST_ERROR());
            }
            
            Print("========== OpenPosition 结束: 成功 ==========");
            return ticket;
        } else {
            // 开仓失败
            int error = GET_LAST_ERROR();
            Print("ERROR: OpenPosition - 尝试 ", attempt, " 失败, 错误码=", error, ", 错误信息=", ErrorDescription(error));
            
            // 5. 判断是否可重试
            if(!IsRetryableError(error)) {
                // 不可重试错误，立即放弃
                Print("ERROR: 不可重试错误，放弃开仓");
                Print("========== OpenPosition 结束: 失败（不可重试） ==========");
                return -1;
            }
            
            // 可重试错误
            if(attempt < max_retries) {
                // 还有重试机会，等待后重试
                Print("WARN: 可重试错误，等待 ", retry_delay, " 毫秒后重试...");
                Sleep(retry_delay);
            } else {
                // 已达到最大重试次数
                Print("ERROR: 已达到最大重试次数，放弃开仓");
                Print("========== OpenPosition 结束: 失败（重试次数耗尽） ==========");
                return -1;
            }
        }
    }
    
    // 理论上不会到达这里
    Print("========== OpenPosition 结束: 失败（未知原因） ==========");
    return -1;
}

//+------------------------------------------------------------------+
//| Task 6.2: 实现批量开仓（拆单）                                    |
//| 参数：                                                            |
//|   splits[] - 拆单结果数组（包含手数和止盈价格）                  |
//|   split_count - 拆单数量                                         |
//|   entry - 入场价格（参考价格）                                   |
//|   stop_loss - 止损价格（所有订单共享）                           |
//|   slippage - 最大允许滑点（点数）                                |
//|   tickets[] - 输出的订单号数组                                   |
//| 返回：                                                            |
//|   成功开仓的订单数量                                             |
//| 说明：                                                            |
//|   1. 遍历拆单数组                                                |
//|   2. 为每个拆分订单设置对应的止盈价格                            |
//|   3. 调用 OpenPosition 执行开仓                                  |
//|   4. 记录所有成功的订单号                                        |
//+------------------------------------------------------------------+
int OpenMultiplePositions(LotSplit &splits[], int split_count, double entry, double stop_loss, int slippage, int &tickets[], int magic)
{
    Print("========== OpenMultiplePositions 开始 ==========");
    Print("拆单数量: ", split_count, ", entry=", entry, ", sl=", stop_loss, ", slippage=", slippage, ", magic=", magic);
    
    // 调整输出数组大小
    ArrayResize(tickets, split_count);
    
    int success_count = 0;
    
    // 遍历拆单数组
    for(int i = 0; i < split_count; i++) {
        double lots = splits[i].lots;
        double tp_price = splits[i].tp_price;
        
        Print("开仓订单 ", i + 1, "/", split_count, ": lots=", lots, ", tp=", tp_price);
        
        // 调用 OpenPosition 执行开仓（透传 magic 参数）
        int ticket = OpenPosition(lots, entry, stop_loss, tp_price, slippage, magic);
        
        if(ticket > 0) {
            // 开仓成功
            tickets[i] = ticket;
            success_count++;
            Print("INFO: 订单 ", i + 1, " 开仓成功, ticket=", ticket);
        } else {
            // 开仓失败
            tickets[i] = -1;
            Print("ERROR: 订单 ", i + 1, " 开仓失败");
            
            // 继续尝试开启其他订单（不因一个失败而全部放弃）
            // 但记录失败情况
        }
        
        // 在订单之间添加短暂延迟，避免请求过于频繁
        if(i < split_count - 1) {
            Sleep(100);  // 延迟 100 毫秒
        }
    }
    
    Print("========== OpenMultiplePositions 结束 ==========");
    Print("成功开仓: ", success_count, "/", split_count);
    
    return success_count;
}

//+------------------------------------------------------------------+
//| 获取订单信息                                                      |
//| 参数：                                                            |
//|   ticket - 订单号                                                |
//|   info - 输出的订单信息结构体                                    |
//| 返回：                                                            |
//|   true - 成功，false - 失败                                      |
//+------------------------------------------------------------------+
bool GetOrderExecutorInfo(int ticket, OrderExecutorInfo &info)
{
    if(!OrderSelect(ticket, SELECT_BY_TICKET)) {
        Print("ERROR: GetOrderInfo - 无法选择订单 ", ticket, ", 错误码=", GET_LAST_ERROR());
        return false;
    }
    
    info.ticket = OrderTicket();
    info.open_price = OrderOpenPrice();
    info.stop_loss = OrderStopLoss();
    info.take_profit = OrderTakeProfit();
    info.lots = OrderLots();
    info.open_time = OrderOpenTime();
    info.comment = OrderComment();
    
    // 计算实际滑点（需要知道预期价格，这里暂时设为 0）
    info.actual_slippage = 0;
    
    return true;
}

//+------------------------------------------------------------------+
//| 错误描述辅助函数                                                  |
//| 将 MT4 错误码转换为可读的错误描述                                 |
//+------------------------------------------------------------------+
string ErrorDescription(int error_code)
{
    string error_string;
    
    switch(error_code) {
        // 常见错误
        case 0:   error_string = "无错误"; break;
        case 1:   error_string = "无错误，但结果未知"; break;
        case 2:   error_string = "一般错误"; break;
        case 3:   error_string = "无效参数"; break;
        case 4:   error_string = "交易服务器繁忙"; break;
        case 5:   error_string = "旧版本的客户端"; break;
        case 6:   error_string = "无连接到交易服务器"; break;
        case 7:   error_string = "没有足够的权限"; break;
        case 8:   error_string = "请求过于频繁"; break;
        case 9:   error_string = "不合规的操作扰乱了服务器的运作"; break;
        
        // 账户错误
        case 64:  error_string = "账户被禁用"; break;
        case 65:  error_string = "无效的账户"; break;
        
        // 交易错误
        case 128: error_string = "交易超时"; break;
        case 129: error_string = "无效价格"; break;
        case 130: error_string = "无效止损"; break;
        case 131: error_string = "无效交易量"; break;
        case 132: error_string = "市场关闭"; break;
        case 133: error_string = "交易被禁用"; break;
        case 134: error_string = "资金不足"; break;
        case 135: error_string = "价格改变"; break;
        case 136: error_string = "无报价"; break;
        case 137: error_string = "经纪商繁忙"; break;
        case 138: error_string = "重新报价"; break;
        case 139: error_string = "订单被锁定"; break;
        case 140: error_string = "只允许买入"; break;
        case 141: error_string = "请求过多"; break;
        case 145: error_string = "修改被禁止，订单太接近市场"; break;
        case 146: error_string = "交易上下文繁忙"; break;
        case 147: error_string = "使用过期价格"; break;
        case 148: error_string = "订单数量超过限制"; break;
        
        // 其他错误
        default:  error_string = "未知错误 (" + IntegerToString(error_code) + ")"; break;
    }
    
    return error_string;
}

//+------------------------------------------------------------------+

#endif // ORDER_EXECUTOR_MQH
