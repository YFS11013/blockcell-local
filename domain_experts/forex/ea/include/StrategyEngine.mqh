//+------------------------------------------------------------------+
//|                                             StrategyEngine.mqh   |
//|                        MT4 Forex Strategy Executor - Strategy    |
//|                                                                  |
//| 描述：策略引擎模块                                                |
//| 功能：                                                            |
//|   - 评估入场条件（趋势、区间、回踩、形态）                        |
//|   - 判断是否满足开仓条件                                          |
//|   - 计算止损和止盈价格                                           |
//|   - 生成交易信号                                                 |
//+------------------------------------------------------------------+
#property copyright "MT4 Forex Strategy Executor"
#property strict

//+------------------------------------------------------------------+
//| 数据结构定义                                                      |
//+------------------------------------------------------------------+

// 形态类型枚举
enum PatternType {
    PATTERN_NONE,                // 无形态
    PATTERN_BEARISH_ENGULFING,   // 看跌吞没
    PATTERN_BEARISH_PIN_BAR      // 看跌 Pin Bar
};

// 信号结果结构
struct SignalResult {
    bool is_valid;               // 信号是否有效
    string reject_reason;        // 拒绝原因
    double entry_price;          // 入场价格
    double stop_loss;            // 止损价格
    double tp_levels[10];        // 止盈价格数组
    double tp_ratios[10];        // 止盈手数比例数组
    int tp_count;                // 止盈级别数量
    PatternType pattern;         // 识别的形态
    datetime signal_time;        // 信号时间
    
    // 条件判定详情
    bool trend_ok;               // 趋势过滤通过
    bool zone_ok;                // 区间过滤通过
    bool retracement_ok;         // 回踩确认通过
    bool pattern_ok;             // 形态确认通过
};

//+------------------------------------------------------------------+
//| Task 4.1: 实现趋势过滤                                            |
//| 检查价格是否低于 EMA200（做空条件）                               |
//+------------------------------------------------------------------+
bool CheckTrendFilter(int ema_trend_period)
{
    // 检查 K 线数量
    if(Bars < 2) {
        Print("趋势过滤: K 线数量不足 (Bars=", Bars, ")");
        return false;
    }
    
    // 使用已收盘的 K 线 [1]
    double close_price = Close[1];
    double ema_trend = iMA(Symbol(), PERIOD_H4, ema_trend_period, 0, MODE_EMA, PRICE_CLOSE, 1);
    
    // 做空条件：价格低于 EMA200
    bool trend_ok = (close_price < ema_trend);
    
    if(trend_ok) {
        Print("趋势过滤: 通过 - Close[1]=", DoubleToString(close_price, 5), 
              " < EMA", IntegerToString(ema_trend_period), "=", DoubleToString(ema_trend, 5));
    } else {
        Print("趋势过滤: 未通过 - Close[1]=", DoubleToString(close_price, 5), 
              " >= EMA", IntegerToString(ema_trend_period), "=", DoubleToString(ema_trend, 5));
    }
    
    return trend_ok;
}

//+------------------------------------------------------------------+
//| Task 4.2: 实现区间过滤                                            |
//| 检查价格是否在入场区间内                                          |
//+------------------------------------------------------------------+
bool CheckPriceZone(double zone_min, double zone_max)
{
    // 检查 K 线数量
    if(Bars < 2) {
        Print("区间过滤: K 线数量不足 (Bars=", Bars, ")");
        return false;
    }
    
    // 使用已收盘的 K 线 [1]
    double close_price = Close[1];
    
    // 检查价格是否在区间内
    bool zone_ok = (close_price >= zone_min && close_price <= zone_max);
    
    if(zone_ok) {
        Print("区间过滤: 通过 - Close[1]=", DoubleToString(close_price, 5), 
              " 在区间 [", DoubleToString(zone_min, 5), ", ", DoubleToString(zone_max, 5), "] 内");
    } else {
        Print("区间过滤: 未通过 - Close[1]=", DoubleToString(close_price, 5), 
              " 不在区间 [", DoubleToString(zone_min, 5), ", ", DoubleToString(zone_max, 5), "] 内");
    }
    
    return zone_ok;
}

//+------------------------------------------------------------------+
//| Task 4.3: 实现 EMA 回踩检测                                       |
//| 检查最近 N 根 K 线是否触及 EMA50                                  |
//+------------------------------------------------------------------+
bool CheckEMARetracement(int ema_fast_period, int lookback, double tolerance)
{
    // 检查 K 线数量（需要至少 lookback + 1 根）
    if(Bars < lookback + 1) {
        Print("回踩检测: K 线数量不足 (Bars=", Bars, ", 需要=", lookback + 1, ")");
        return false;
    }
    
    // 检查最近 lookback_period 根已收盘的 K 线（从 [1] 开始）
    for(int i = 1; i <= lookback; i++) {
        double low_price = Low[i];
        double ema_fast = iMA(Symbol(), PERIOD_H4, ema_fast_period, 0, MODE_EMA, PRICE_CLOSE, i);
        
        // 计算价格与 EMA 的距离（点数）
        double distance = MathAbs(low_price - ema_fast) / Point;
        
        // 如果距离在容差范围内，视为回踩
        if(distance <= tolerance) {
            Print("回踩检测: 通过 - K线[", IntegerToString(i), "] Low=", DoubleToString(low_price, 5),
                  " 接近 EMA", IntegerToString(ema_fast_period), "=", DoubleToString(ema_fast, 5),
                  ", 距离=", DoubleToString(distance, 1), " 点");
            return true;
        }
    }
    
    Print("回踩检测: 未通过 - 最近 ", IntegerToString(lookback), " 根 K 线未触及 EMA", 
          IntegerToString(ema_fast_period), " (容差 ", DoubleToString(tolerance, 1), " 点)");
    return false;
}

//+------------------------------------------------------------------+
//| Task 4.4: 实现形态识别                                            |
//| 检查看跌吞没和看跌 Pin Bar 形态                                   |
//+------------------------------------------------------------------+
PatternType CheckPattern(string &patterns[], int pattern_count)
{
    // 检查 K 线数量
    if(Bars < 3) {
        Print("形态识别: K 线数量不足 (Bars=", Bars, ")");
        return PATTERN_NONE;
    }
    
    // 检查看跌吞没形态
    bool check_engulfing = false;
    bool check_pinbar = false;
    
    for(int i = 0; i < pattern_count; i++) {
        if(patterns[i] == "bearish_engulfing") check_engulfing = true;
        if(patterns[i] == "bearish_pin_bar") check_pinbar = true;
    }
    
    // 看跌吞没形态检测
    if(check_engulfing) {
        // 使用 [1] 和 [2]（已收盘的两根 K 线）
        double current_open = Open[1];
        double current_close = Close[1];
        double prev_open = Open[2];
        double prev_close = Close[2];
        
        double current_body = MathAbs(current_close - current_open);
        double prev_body = MathAbs(prev_close - prev_open);
        
        bool is_bearish_engulfing = 
            (current_close < current_open) &&      // [1] 为阴线
            (prev_close > prev_open) &&            // [2] 为阳线
            (current_open > prev_close) &&         // [1] 开盘高于 [2] 收盘
            (current_close < prev_open);           // [1] 收盘低于 [2] 开盘
        
        if(is_bearish_engulfing) {
            Print("形态识别: 看跌吞没 - K[1] Open=", DoubleToString(current_open, 5),
                  " Close=", DoubleToString(current_close, 5),
                  ", K[2] Open=", DoubleToString(prev_open, 5),
                  " Close=", DoubleToString(prev_close, 5));
            return PATTERN_BEARISH_ENGULFING;
        }
    }
    
    // 看跌 Pin Bar 形态检测
    if(check_pinbar) {
        // 使用 [1]（刚收盘的 K 线）
        double open_price = Open[1];
        double close_price = Close[1];
        double high_price = High[1];
        double low_price = Low[1];
        
        double body = MathAbs(close_price - open_price);
        double upper_shadow = high_price - MathMax(open_price, close_price);
        double lower_shadow = MathMin(open_price, close_price) - low_price;
        
        bool is_bearish_pin_bar = 
            (close_price < open_price) &&          // 阴线
            (upper_shadow >= body * 2.0) &&        // 上影线 >= 实体 * 2
            (lower_shadow <= body * 0.5);          // 下影线 <= 实体 * 0.5
        
        if(is_bearish_pin_bar) {
            Print("形态识别: 看跌 Pin Bar - K[1] High=", DoubleToString(high_price, 5),
                  " Open=", DoubleToString(open_price, 5),
                  " Close=", DoubleToString(close_price, 5),
                  " Low=", DoubleToString(low_price, 5),
                  ", 上影线=", DoubleToString(upper_shadow, 5),
                  " 实体=", DoubleToString(body, 5),
                  " 下影线=", DoubleToString(lower_shadow, 5));
            return PATTERN_BEARISH_PIN_BAR;
        }
    }
    
    Print("形态识别: 未识别到有效形态");
    return PATTERN_NONE;
}

//+------------------------------------------------------------------+
//| Task 4.5: 实现止损计算                                            |
//| 计算止损价格：max(invalid_above, Signal_K 高点 + buffer)         |
//+------------------------------------------------------------------+
double CalculateStopLoss(double invalid_above, double signal_high, double buffer)
{
    // buffer 默认为 10 点
    double buffer_price = buffer * Point;
    
    // 计算止损：取 invalid_above 和 (Signal_K 高点 + buffer) 的较大值
    double stop_loss = MathMax(invalid_above, signal_high + buffer_price);
    
    Print("止损计算: invalid_above=", DoubleToString(invalid_above, 5),
          ", Signal_K High=", DoubleToString(signal_high, 5),
          ", buffer=", DoubleToString(buffer, 1), " 点",
          " => 止损=", DoubleToString(stop_loss, 5));
    
    return stop_loss;
}

//+------------------------------------------------------------------+
//| Task 4.6: 实现信号评估主函数                                      |
//| 整合所有入场条件判断，返回信号结果                                |
//+------------------------------------------------------------------+
SignalResult EvaluateEntrySignal(ParameterPack &params)
{
    SignalResult signal;
    signal.is_valid = false;
    signal.reject_reason = "";
    signal.entry_price = 0;
    signal.stop_loss = 0;
    signal.tp_count = 0;
    signal.pattern = PATTERN_NONE;
    signal.signal_time = Time[1];  // Signal_K 的时间
    
    signal.trend_ok = false;
    signal.zone_ok = false;
    signal.retracement_ok = false;
    signal.pattern_ok = false;
    
    Print("========== 信号评估开始 ==========");
    Print("参数版本: ", params.version);
    Print("Signal_K 时间: ", TimeToString(signal.signal_time));
    
    // 1. 趋势过滤
    signal.trend_ok = CheckTrendFilter(params.ema_trend);
    if(!signal.trend_ok) {
        signal.reject_reason = "趋势过滤未通过";
        Print("========== 信号评估结束: 拒绝 - ", signal.reject_reason, " ==========");
        return signal;
    }
    
    // 2. 区间过滤
    signal.zone_ok = CheckPriceZone(params.entry_zone_min, params.entry_zone_max);
    if(!signal.zone_ok) {
        signal.reject_reason = "区间过滤未通过";
        Print("========== 信号评估结束: 拒绝 - ", signal.reject_reason, " ==========");
        return signal;
    }
    
    // 3. 回踩确认
    signal.retracement_ok = CheckEMARetracement(params.ema_fast, params.lookback_period, params.touch_tolerance);
    if(!signal.retracement_ok) {
        signal.reject_reason = "回踩确认未通过";
        Print("========== 信号评估结束: 拒绝 - ", signal.reject_reason, " ==========");
        return signal;
    }
    
    // 4. 形态确认
    signal.pattern = CheckPattern(params.patterns, params.pattern_count);
    signal.pattern_ok = (signal.pattern != PATTERN_NONE);
    if(!signal.pattern_ok) {
        signal.reject_reason = "形态确认未通过";
        Print("========== 信号评估结束: 拒绝 - ", signal.reject_reason, " ==========");
        return signal;
    }
    
    // 所有条件满足，生成有效信号
    signal.is_valid = true;
    signal.entry_price = Bid;  // 做空使用 Bid 价
    
    // 计算止损
    double signal_high = High[1];  // Signal_K 的高点
    signal.stop_loss = CalculateStopLoss(params.invalid_above, signal_high, 10);
    
    // 复制止盈参数
    signal.tp_count = params.tp_count;
    for(int i = 0; i < params.tp_count; i++) {
        signal.tp_levels[i] = params.tp_levels[i];
        signal.tp_ratios[i] = params.tp_ratios[i];
    }
    
    Print("========== 信号评估结束: 有效信号 ==========");
    Print("入场价格: ", DoubleToString(signal.entry_price, 5));
    Print("止损价格: ", DoubleToString(signal.stop_loss, 5));
    Print("形态类型: ", PatternTypeToString(signal.pattern));
    
    return signal;
}

//+------------------------------------------------------------------+
//| 形态类型转字符串                                                  |
//+------------------------------------------------------------------+
string PatternTypeToString(PatternType pattern)
{
    switch(pattern) {
        case PATTERN_BEARISH_ENGULFING: return "看跌吞没";
        case PATTERN_BEARISH_PIN_BAR:   return "看跌 Pin Bar";
        case PATTERN_NONE:
        default:                        return "无";
    }
}

//+------------------------------------------------------------------+
