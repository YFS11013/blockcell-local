# 设计文档：MT4 外汇策略执行系统

## 概述

本系统实现"AI 决策建议 + EA 确定性执行"的外汇交易自动化方案。系统分为两个独立组件：

1. **Blockcell 参数生成器**：通过 AI 技能分析市场并生成策略参数包（JSON 格式）
2. **MT4 EA 执行器**：读取参数包并按规则执行交易，确保可追溯、可回测、可风控

V1 版本专注于 EUR/USD H4 空头策略，采用 EMA 趋势过滤、回踩确认、形态触发的交易框架。

### 设计原则

1. **安全优先**：参数异常或过期时，EA 进入 Safe_Mode，停止开新仓但继续管理持仓
2. **分层明确**：Blockcell 只生成建议，EA 只做确定性执行，职责清晰
3. **可追溯性**：每次决策都记录参数版本、触发条件、执行结果
4. **可回测性**：核心逻辑可在 MT4 Strategy Tester 中复现
5. **配置化**：策略参数通过 JSON 配置，避免硬编码

## 架构

### 系统架构图

```
┌─────────────────────────────────────────────────────────────┐
│                      Blockcell 侧                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ forex_news   │  │forex_analysis│  │forex_strategy│      │
│  │   Skill      │  │    Skill     │  │    Skill     │      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         │                  │                  │              │
│         └──────────────────┼──────────────────┘              │
│                            ▼                                 │
│                  ┌──────────────────┐                        │
│                  │ Parameter Pack   │                        │
│                  │   Generator      │                        │
│                  └────────┬─────────┘                        │
│                           │                                  │
│                           ▼                                  │
│                  signal_pack.json                            │
└───────────────────────────┼──────────────────────────────────┘
                            │ (File System)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                       MT4 EA 侧                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                   EA Main Loop                       │   │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐    │   │
│  │  │ Parameter  │  │  Strategy  │  │    Risk    │    │   │
│  │  │  Loader    │→ │  Engine    │→ │  Manager   │    │   │
│  │  └────────────┘  └────────────┘  └────────────┘    │   │
│  │         │               │                │          │   │
│  │         ▼               ▼                ▼          │   │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐   │   │
│  │  │   Logger   │  │  Position  │  │   Order    │   │   │
│  │  │            │  │  Manager   │  │  Executor  │   │   │
│  │  └────────────┘  └────────────┘  └────────────┘   │   │
│  └──────────────────────────────────────────────────────┘   │
│                           │                                  │
│                           ▼                                  │
│                    MT4 Trading Server                        │
└─────────────────────────────────────────────────────────────┘
```

### 数据流

1. **参数生成流程**：
   - Blockcell 定时或手动触发参数生成
   - AI 技能分析新闻、技术面、基本面
   - 生成包含所有必需字段的 JSON 参数包
   - 保存到 EA 可访问的路径

2. **交易执行流程**：
   - EA 定时检查并加载参数包
   - 校验参数有效性和固定值
   - 按参数选择优先级规则选择使用哪个参数
   - 在每根 H4 K 线收盘时评估入场条件
   - 满足条件时在下一根 K 线开盘执行开仓
   - 持续管理持仓（止损、止盈）
   - 记录所有决策和执行结果


## 组件与接口

### 1. Parameter Loader（参数加载器）

**职责**：
- 从文件系统读取 signal_pack.json
- 解析 JSON 并校验字段完整性
- 校验 V1 固定值（symbol/timeframe/bias）
- 按优先级规则选择有效参数
- 管理参数生命周期

**接口**：
```mql4
// 加载参数包
bool LoadParameterPack(string filePath);

// 获取当前有效参数
ParameterPack GetCurrentParameters();

// 检查参数是否有效
bool IsParameterValid();

// 获取参数状态
string GetParameterStatus(); // "valid", "expired", "not_effective", "invalid", "safe_mode"

// 保存参数包到备份文件（用于"旧参数"持久化）
bool SaveParameterBackup(ParameterPack params, string backupPath);

// 从备份文件加载旧参数
bool LoadParameterBackup(string backupPath, ParameterPack &params);
```

**数据结构**：
```mql4
struct ParameterPack {
    string version;
    string symbol;
    string timeframe;
    string bias;
    datetime valid_from;
    datetime valid_to;
    double entry_zone_min;
    double entry_zone_max;
    double invalid_above;
    double tp_levels[];
    double tp_ratios[];
    int ema_fast;
    int ema_trend;
    int lookback_period;
    double touch_tolerance;
    string patterns[];
    double risk_per_trade;
    double risk_daily_max_loss;
    int risk_consecutive_loss_limit;
    double max_spread_points;
    double max_slippage_points;
    NewsBlackout news_blackouts[];
    SessionFilter session_filter;
    string comment;
};

struct NewsBlackout {
    datetime start;
    datetime end;
    string reason;
};

struct SessionFilter {
    bool enabled;
    int allowed_hours_utc[];
};
```

**参数选择优先级逻辑**：
```
1. 尝试加载新参数包（signal_pack.json）
2. 尝试加载旧参数包备份（signal_pack_backup.json）
3. 过滤出当前时间在 [valid_from, valid_to] 之间的参数
4. 如果有多个有效参数，选择 version 字段值最大的
5. 如果没有有效参数但旧参数仍在有效期内，继续使用旧参数
6. 如果选择了新参数，保存到备份文件（覆盖旧备份）
7. 如果没有任何有效参数，进入 Safe_Mode
```

**备份文件管理**：
- 主参数文件：signal_pack.json（由 Blockcell 生成）
- 备份文件：signal_pack_backup.json（由 EA 维护）
- EA 每次成功加载新参数后，将其保存到备份文件
- EA 重启时，同时读取主文件和备份文件，按优先级选择

**校验规则**：
- 必需字段完整性检查
- symbol == "EURUSD"
- timeframe == "H4"
- bias == "short_only"
- tp_levels 和 tp_ratios 长度相同
- abs(sum(tp_ratios) - 1.0) <= 1e-6
- 时间格式为 ISO 8601（YYYY-MM-DDTHH:MM:SSZ）
- 可选字段（news_blackout, session_filter）如果提供则必须正确解析

**可选字段解析策略**（修复 news_blackout/session_filter 解析问题）：
```mql4
// 解析 news_blackout 数组
bool ParseNewsBlackout(string json, ParameterPack &params) {
    // 字段不存在时返回 true（可选字段）
    if(StringFind(json, "\"news_blackout\"") < 0) {
        params.blackout_count = 0;
        return true;
    }
    
    // 字段存在但解析失败时返回 false
    // 解析所有时间窗口对象...
    // 校验 start/end 时间格式...
    
    return true;  // 解析成功
}

// 解析 session_filter 对象
bool ParseSessionFilter(string json, ParameterPack &params) {
    // 字段不存在时返回 true（可选字段）
    if(StringFind(json, "\"session_filter\"") < 0) {
        params.session_filter.enabled = false;
        return true;
    }
    
    // 字段存在但解析失败时返回 false
    // 解析 enabled 和 allowed_hours_utc...
    // 校验小时范围 [0, 23]...
    
    return true;  // 解析成功
}
```

**关键要点**：
- 可选字段不存在时：初始化为默认值（blackout_count=0, enabled=false），返回 true
- 可选字段存在但格式错误时：设置 error_message，返回 false，拒绝加载参数包
- 禁止使用硬编码默认值覆盖已提供的配置
- 解析失败时进入 Safe_Mode（符合需求 4.3）


### 2. Strategy Engine（策略引擎）

**职责**：
- 评估入场条件（趋势、区间、回踩、形态）
- 判断是否满足开仓条件
- 计算止损和止盈价格
- 生成交易信号

**接口**：
```mql4
// 评估入场信号
SignalResult EvaluateEntrySignal(ParameterPack params);

// 检查趋势过滤
bool CheckTrendFilter(int ema_trend_period);

// 检查价格区间
bool CheckPriceZone(double zone_min, double zone_max);

// 检查 EMA 回踩
bool CheckEMARetracement(int ema_fast_period, int lookback, double tolerance);

// 检查形态确认
PatternType CheckPattern(string patterns[]);

// 计算止损价格
double CalculateStopLoss(double invalid_above, double signal_high, double buffer);

// 计算开仓手数
double CalculateLotSize(double stop_loss, double risk_percent);
```

**数据结构**：
```mql4
struct SignalResult {
    bool is_valid;
    string reject_reason;
    double entry_price;
    double stop_loss;
    double tp_levels[];
    double tp_ratios[];
    PatternType pattern;
    datetime signal_time;
};

enum PatternType {
    PATTERN_NONE,
    PATTERN_BEARISH_ENGULFING,
    PATTERN_BEARISH_PIN_BAR
};
```

**策略逻辑**：

1. **趋势过滤**：
   ```
   // 使用已收盘的 K 线（[1]）进行判断
   Close[1] < iMA(Symbol(), PERIOD_H4, ema_trend, 0, MODE_EMA, PRICE_CLOSE, 1)
   ```

2. **区间过滤**：
   ```
   // 使用已收盘的 K 线（[1]）进行判断
   entry_zone_min <= Close[1] <= entry_zone_max
   ```

3. **回踩过滤**：
   ```
   // 检查最近 lookback_period 根已收盘的 K 线（从 [1] 开始）
   for i = 1 to lookback_period:
       ema50 = iMA(Symbol(), PERIOD_H4, ema_fast, 0, MODE_EMA, PRICE_CLOSE, i)
       if abs(Low[i] - ema50) <= touch_tolerance * Point:
           return true
   return false
   ```

4. **形态确认 - 看跌吞没**：
   ```
   // 使用 [1] 和 [2]（已收盘的两根 K 线）
   current_body = abs(Close[1] - Open[1])
   prev_body = abs(Close[2] - Open[2])
   
   is_bearish_engulfing = 
       Close[1] < Open[1] &&           // [1] 为阴线
       Close[2] > Open[2] &&           // [2] 为阳线
       Open[1] > Close[2] &&           // [1] 开盘高于 [2] 收盘
       Close[1] < Open[2]              // [1] 收盘低于 [2] 开盘
   ```

5. **形态确认 - 看跌 Pin Bar**：
   ```
   // 使用 [1]（刚收盘的 K 线）
   body = abs(Close[1] - Open[1])
   upper_shadow = High[1] - MathMax(Open[1], Close[1])
   lower_shadow = MathMin(Open[1], Close[1]) - Low[1]
   
   is_bearish_pin_bar = 
       Close[1] < Open[1] &&           // 阴线
       upper_shadow >= body * 2.0 &&   // 上影线 >= 实体 * 2
       lower_shadow <= body * 0.5      // 下影线 <= 实体 * 0.5
   ```

6. **止损计算**：
   ```
   buffer = 10 * Point  // 默认 10 点
   // 使用 [1]（Signal_K，刚收盘的 K 线）
   stop_loss = MathMax(invalid_above, High[1] + buffer)
   ```

**信号评估时机**：
- 在每根 H4 K 线收盘时（OnTick 中检测 K 线变化）
- 评估时使用已收盘的 K 线数据（[1], [2], ...）
- 如果所有条件满足，生成完整的信号快照并缓存到全局变量 `g_CachedSignal`
- 在下一根 K 线首个 tick 时（检测到新 K 线）执行开仓

**信号缓存机制**（修复 Signal_K 执行时序问题）：
```mql4
// 全局变量
bool g_PendingSignal = false;
SignalResult g_CachedSignal;  // 缓存的信号快照

// 在 K 线收盘时评估并缓存信号
void EvaluateEntrySignal() {
    SignalResult signal = EvaluateEntrySignal(params);
    
    if(signal.is_valid) {
        g_CachedSignal = signal;  // 缓存完整的信号快照
        g_PendingSignal = true;
        // 信号包含：entry_price, stop_loss, tp_levels, tp_ratios, signal_time
    }
}

// 在下一根 K 线首个 tick 时执行
void ExecutePendingSignal() {
    // 直接使用缓存的信号，不再重新评估
    SignalResult signal = g_CachedSignal;
    
    // 执行开仓逻辑...
}
```

**关键要点**：
- Signal_K 是触发信号的那根 K 线（已收盘的 [1]）
- 信号数据必须在 Signal_K 收盘时完整缓存
- 执行阶段不得重新评估 Signal_K，必须使用缓存的数据
- 这确保了"Signal_K 收盘后下一根 K 线首个 tick 执行"的语义正确


### 3. Risk Manager（风险管理器）

**职责**：
- 计算开仓手数（基于风险百分比）
- 监控日亏损和连续亏损
- 执行熔断机制
- 检查点差和滑点限制

**接口**：
```mql4
// 检查是否允许开仓
bool CanOpenNewPosition();

// 计算手数
double CalculatePositionSize(double entry, double stop_loss, double risk_percent);

// 拆分手数到多个订单
LotSplit[] SplitLots(double total_lots, double ratios[]);

// 检查点差
bool CheckSpread(double max_spread_points);

// 记录交易结果
void RecordTradeResult(int ticket, double profit);

// 检查日亏损限制
bool CheckDailyLoss(double max_loss_percent);

// 检查连续亏损限制
bool CheckConsecutiveLoss(int max_consecutive);

// 重置熔断状态
void ResetCircuitBreaker();
```

**数据结构**：
```mql4
struct LotSplit {
    double lots;
    double tp_price;
};

struct RiskState {
    double daily_profit;
    int consecutive_losses;
    datetime circuit_breaker_until;  // UTC 时间
    bool is_safe_mode;
    int last_reset_date;  // 格式：YYYYMMDD，用于日切判断
};
```

**手数计算逻辑**：
```
1. 计算风险金额：risk_amount = AccountBalance() * risk_per_trade
2. 计算点数风险（使用绝对值）：pip_risk = MathAbs(entry - stop_loss) / Point
3. 计算手数：lots = risk_amount / (pip_risk * MarketInfo(Symbol(), MODE_TICKVALUE))
4. 规范化手数：
   - 向下取整到 lot_step
   - 确保 >= min_lot
   - 确保 <= max_lot
```

**拆单逻辑**：
```
1. 计算每个订单的目标手数：target_lots[i] = total_lots * tp_ratios[i]
2. 规范化每个手数到 lot_step：
   normalized_lots[i] = MathFloor(target_lots[i] / lot_step) * lot_step
3. 计算余量：remainder = total_lots - sum(normalized_lots)
4. 将余量分配到最后一个订单：
   normalized_lots[last] += remainder
5. 再次规范化最后一个订单：
   normalized_lots[last] = MathRound(normalized_lots[last] / lot_step) * lot_step
6. 确保每个订单 >= min_lot 且 <= max_lot
7. 如果最后一个订单超过 max_lot，将超出部分分配到前一个订单
8. 最终验证：abs(sum(normalized_lots) - total_lots) <= lot_step
```

**熔断机制**：
```
1. 日亏损熔断：
   // 将服务器时间转换为 UTC
   current_time_utc = ConvertToUTC(TimeCurrent())
   current_date_utc = TimeYear(current_time_utc) * 10000 + 
                      TimeMonth(current_time_utc) * 100 + 
                      TimeDay(current_time_utc)
   
   // 每天 00:00 UTC 重置 daily_profit
   if current_date_utc != last_reset_date:
       daily_profit = 0
       last_reset_date = current_date_utc
   
   // 每次平仓后累加 profit 到 daily_profit
   daily_profit += profit
   
   // 如果 daily_profit <= -AccountBalance() * daily_max_loss：
   if daily_profit <= -AccountBalance() * daily_max_loss:
       // 计算今天 23:59:59 UTC 的 datetime
       // 方法：当前 UTC 日期 + 23:59:59 - 当前 UTC 时间的时分秒
       int current_seconds = TimeHour(current_time_utc) * 3600 + 
                            TimeMinute(current_time_utc) * 60 + 
                            TimeSeconds(current_time_utc)
       datetime today_end_utc = current_time_utc - current_seconds + (24 * 3600 - 1)
       circuit_breaker_until = today_end_utc
       // 禁止开新仓

2. 连续亏损熔断：
   // 维护 consecutive_losses 计数器
   // 盈利时重置为 0
   // 亏损时 +1
   if consecutive_losses >= consecutive_loss_limit:
       // 设置熔断恢复时间为当前时间（UTC）+ 24 小时
       circuit_breaker_until = ConvertToUTC(TimeCurrent()) + 24 * 3600
       // 禁止开新仓

3. 熔断恢复：
   // 每次检查时判断当前 UTC 时间是否超过熔断恢复时间
   current_time_utc = ConvertToUTC(TimeCurrent())
   if current_time_utc > circuit_breaker_until:
       // 重置熔断状态
       circuit_breaker_until = 0
       // 恢复正常交易
```

**点差检查**：
```
current_spread = (Ask - Bid) / Point
if current_spread > max_spread_points:
    reject opening position
```


### 4. Order Executor（订单执行器）

**职责**：
- 执行开仓操作
- 设置止损和止盈
- 处理订单错误和重试
- 记录实际滑点

**接口**：
```mql4
// 开仓
int OpenPosition(double lots, double entry, double stop_loss, double take_profit, int slippage);

// 批量开仓（拆单）
int[] OpenMultiplePositions(LotSplit splits[], double entry, double stop_loss, int slippage);

// 修改订单
bool ModifyOrder(int ticket, double stop_loss, double take_profit);

// 平仓
bool ClosePosition(int ticket);

// 获取订单信息
OrderInfo GetOrderInfo(int ticket);
```

**数据结构**：
```mql4
struct OrderInfo {
    int ticket;
    double open_price;
    double stop_loss;
    double take_profit;
    double lots;
    datetime open_time;
    double actual_slippage;
    string comment;
};
```

**开仓逻辑**：
```
1. 准备订单参数：
   - cmd = OP_SELL（V1 只做空）
   - volume = lots
   - price = Bid
   - slippage = max_slippage_points
   - stoploss = stop_loss
   - takeprofit = take_profit
   - comment = "v" + param_version + "|" + pattern_type

2. 执行 OrderSend：
   ticket = OrderSend(Symbol(), cmd, volume, price, slippage, stoploss, takeprofit, comment)

3. 检查结果：
   - 如果 ticket > 0：成功
   - 如果 ticket == -1：
     * 获取错误码：error = GetLastError()
     * 记录错误日志
     * 根据错误类型决定是否重试（最多 3 次）

4. 记录实际滑点：
   if OrderSelect(ticket, SELECT_BY_TICKET):
       actual_slippage = abs(OrderOpenPrice() - price) / Point
       if actual_slippage > max_slippage_points:
           log warning
```

**错误处理**：
```
可重试错误（最多 3 次，间隔 1 秒）：
- ERR_SERVER_BUSY (4)
- ERR_NO_CONNECTION (6)
- ERR_TOO_FREQUENT_REQUESTS (8)
- ERR_TRADE_TIMEOUT (128)
- ERR_PRICE_CHANGED (135)
- ERR_REQUOTE (138)

不可重试错误（立即放弃）：
- ERR_INVALID_STOPS (130)
- ERR_INVALID_TRADE_VOLUME (131)
- ERR_MARKET_CLOSED (132)
- ERR_TRADE_DISABLED (133)
- ERR_NOT_ENOUGH_MONEY (134)
- ERR_OFF_QUOTES (136)
```


### 5. Position Manager（持仓管理器）

**职责**：
- 跟踪所有持仓
- 监控止损和止盈
- 处理部分平仓
- 更新持仓状态

**接口**：
```mql4
// 获取所有持仓
int[] GetOpenPositions();

// 检查持仓状态
void CheckPositions();

// 获取持仓统计
PositionStats GetPositionStats();
```

**数据结构**：
```mql4
struct PositionStats {
    int total_positions;
    double total_lots;
    double total_profit;
    double total_loss;
};
```

**持仓管理逻辑**：
```
1. 定期扫描所有订单（每个 Tick）
2. 对于每个持仓：
   - 检查是否已触发止损或止盈（MT4 自动处理）
   - 记录平仓事件
   - 更新风险状态（日亏损、连续亏损）
3. 清理已关闭的订单记录
```

### 6. Logger（日志记录器）

**职责**：
- 记录所有决策和执行结果
- 提供审计追踪
- 支持多种日志级别

**接口**：
```mql4
// 记录参数加载
void LogParameterLoad(string version, string status);

// 记录信号评估
void LogSignalEvaluation(SignalResult signal);

// 记录开仓
void LogOrderOpen(int ticket, OrderInfo info);

// 记录拒单
void LogOrderReject(string reason);

// 记录熔断
void LogCircuitBreaker(string type, string reason);

// 记录平仓
void LogOrderClose(int ticket, double profit);
```

**日志格式**：
```
[YYYY-MM-DDTHH:MM:SSZ] [LEVEL] [COMPONENT] message
```

**日志级别**：
- ERROR：错误（参数加载失败、订单失败）
- WARN：警告（滑点超限、点差过大）
- INFO：信息（参数加载成功、信号评估、订单执行）
- DEBUG：调试（详细的计算过程）

**日志内容**：
```
参数加载：
[2025-03-09T08:00:00Z] [INFO] [ParamLoader] Loaded parameter pack v20250309-0800, valid until 2025-03-10T08:00:00Z

信号评估：
[2025-03-09T12:00:00Z] [INFO] [Strategy] Signal evaluation: trend=OK, zone=OK, retracement=OK, pattern=BEARISH_ENGULFING, decision=OPEN

订单执行：
[2025-03-09T12:00:05Z] [INFO] [OrderExec] Opened ticket #12345, lots=0.30, entry=1.1680, sl=1.1720, tp=1.1550, slippage=0.5

拒单：
[2025-03-09T14:00:00Z] [WARN] [Strategy] Order rejected: spread 25 > max 20

熔断：
[2025-03-09T16:00:00Z] [ERROR] [RiskMgr] Circuit breaker triggered: daily loss -2.1% >= -2.0%, trading suspended until 2025-03-09T23:59:59Z

停机日志：
[2025-03-09T18:00:00Z] [INFO] [EA] EA 已停止
```

**日志关闭顺序**（修复 OnDeinit 日志顺序问题）：
```mql4
void OnDeinit(const int reason) {
    // 1. 保存状态
    SaveEAState();
    
    // 2. 清理资源
    CleanupResources();
    
    // 3. 写入停机末条日志
    LogInfo("EA", "EA 已停止");
    
    // 4. 最后关闭日志系统
    CloseLogger();
}
```

**关键要点**：
- 所有日志必须在 CloseLogger() 之前写入
- 停机末条日志必须同时出现在 MT4 日志窗口和日志文件中
- 确保日志完整性，避免日志丢失


### 7. Time Filter（时间过滤器）

**职责**：
- 检查新闻禁开仓窗口
- 检查交易时段限制
- 处理 UTC 时间转换

**接口**：
```mql4
// 检查是否在新闻窗口内
bool IsInNewsBlackout(NewsBlackout blackouts[]);

// 检查是否在允许的交易时段
bool IsInTradingSession(SessionFilter filter);

// UTC 时间转换
datetime ConvertToUTC(datetime local_time);
```

**时间过滤逻辑**：
```
1. 新闻窗口检查：
   // 将 MT4 服务器时间转换为 UTC
   current_time_utc = ConvertToUTC(TimeCurrent())
   for each blackout in news_blackouts:
       if blackout.start <= current_time_utc <= blackout.end:
           return true (在禁开仓窗口内)
   return false

2. 交易时段检查：
   if !session_filter.enabled:
       return true
   
   // 将 MT4 服务器时间转换为 UTC
   current_time_utc = ConvertToUTC(TimeCurrent())
   current_hour = TimeHour(current_time_utc)
   for each hour in allowed_hours_utc:
       if current_hour == hour:
           return true
   return false
```

**UTC 时间转换**：
```mql4
// EA 全局输入参数（在文件顶部声明）
input int ServerUTCOffset = 2;  // 服务器时区偏移，例如：+2 表示 UTC+2

// 将 MT4 服务器时间转换为 UTC
datetime ConvertToUTC(datetime server_time) {
    return server_time - ServerUTCOffset * 3600;
}
```

**配置说明**：
- 用户需要在 EA 输入参数中手动配置 ServerUTCOffset
- 常见值：
  - 0：服务器已经是 UTC
  - +2：欧洲夏令时（CEST）
  - +3：莫斯科时间（MSK）
  - -5：美国东部时间（EST）
- 可以通过对比已知 UTC 时间和服务器时间来确定偏移值

### 8. Blockcell Parameter Generator（参数生成器）

**职责**：
- 调用 AI 技能分析市场
- 生成策略参数包
- 保存到指定路径

**实现方式**：
- 使用 Blockcell 的 Skill 系统
- 创建专门的 forex_strategy_generator Skill
- 或通过 Rhai 脚本调用现有技能组合

**Skill 接口**（伪代码）：
```rhai
// forex_strategy_generator.rhai

fn generate_signal_pack(symbol, timeframe) {
    // 1. 获取新闻分析
    let news = call_skill("forex_news", #{
        symbol: symbol,
        lookback_hours: 24
    });
    
    // 2. 获取技术分析
    let analysis = call_skill("forex_analysis", #{
        symbol: symbol,
        timeframe: timeframe
    });
    
    // 3. 生成策略参数
    let strategy = call_skill("forex_strategy", #{
        symbol: symbol,
        timeframe: timeframe,
        news: news,
        analysis: analysis
    });
    
    // 4. 构建参数包
    let param_pack = #{
        version: format_version(now_utc()),
        symbol: symbol,
        timeframe: timeframe,
        bias: "short_only",
        valid_from: format_iso8601(now_utc()),  // 使用 UTC 时间
        valid_to: format_iso8601(now_utc() + 24h),  // 使用 UTC 时间
        entry_zone: strategy.entry_zone,
        invalid_above: strategy.invalid_above,
        tp_levels: strategy.tp_levels,
        tp_ratios: [0.3, 0.4, 0.3],
        ema_fast: 50,
        ema_trend: 200,
        lookback_period: 10,
        touch_tolerance: 10,
        pattern: ["bearish_engulfing", "bearish_pin_bar"],
        risk: #{
            per_trade: 0.01,
            daily_max_loss: 0.02,
            consecutive_loss_limit: 3
        },
        max_spread_points: 20,
        max_slippage_points: 10,
        news_blackout: format_news_blackout_iso8601(news.blackout_windows),  // 转换时间为 ISO 8601
        session_filter: #{
            enabled: true,
            allowed_hours_utc: [8,9,10,11,12,13,14,15,16]
        },
        comment: strategy.comment
    };
    
    // 5. 保存到文件
    save_json("workspace/ea/signal_pack.json", param_pack);
    
    return param_pack;
}

// 辅助函数：将 datetime 转换为 ISO 8601 字符串
fn format_iso8601(dt) {
    // 注意：dt 应该是 UTC 时间
    // 如果 now() 返回的是本地时间，需要先转换为 UTC
    // 格式：YYYY-MM-DDTHH:MM:SSZ
    return dt.format("%Y-%m-%dT%H:%M:%SZ");
}

// 辅助函数：获取当前 UTC 时间
fn now_utc() {
    // V1 实现方案：要求 Blockcell 运行在 UTC 时区环境
    // 部署时必须确保 Blockcell 主机配置为 UTC 时区
    // 或通过环境变量 TZ=UTC 启动 Blockcell
    
    // 启动时验证时区（伪代码）
    // if get_system_timezone() != "UTC":
    //     throw "Blockcell must run in UTC timezone for forex parameter generation"
    
    return now();  // 在 UTC 环境下，now() 返回 UTC 时间
}
```

**V1 部署要求**：
- Blockcell 必须在 UTC 时区环境中运行
- Linux/Mac：设置环境变量 `TZ=UTC` 或修改系统时区
- Windows：修改系统时区为 UTC（不推荐）或使用 WSL/Docker 容器
- 建议使用 Docker 容器运行 Blockcell，容器时区设置为 UTC

```rhai
// 辅助函数：转换新闻窗口时间为 ISO 8601
fn format_news_blackout_iso8601(windows) {
    let result = [];
    for window in windows {
        result.push(#{
            start: format_iso8601(window.start),
            end: format_iso8601(window.end),
            reason: window.reason
        });
    }
    return result;
}
```

**定时触发**：
- 使用 Blockcell 的 Cron 功能
- 配置每天 UTC 06:00 触发（亚洲早盘前）
- 或通过 Gateway API 手动触发


## 数据模型

### EA 状态机

```
┌─────────────┐
│ INITIALIZING│
└──────┬──────┘
       │
       ▼
┌─────────────┐     参数无效/过期
│   LOADING   ├──────────────────┐
│  PARAMETERS │                  │
└──────┬──────┘                  │
       │ 参数有效                 │
       ▼                         ▼
┌─────────────┐            ┌──────────┐
│   RUNNING   │            │SAFE_MODE │
└──────┬──────┘            └────┬─────┘
       │                        │
       │ 熔断触发                │
       ├────────────────────────┤
       │                        │
       │ 熔断恢复/参数恢复        │
       └────────────────────────┘
```

### 状态说明

- **INITIALIZING**：EA 启动，初始化组件
- **LOADING_PARAMETERS**：加载和校验参数包
- **RUNNING**：正常运行，可以开新仓和管理持仓
- **SAFE_MODE**：安全模式，只管理持仓，不开新仓

### 状态转换条件

- INITIALIZING → LOADING_PARAMETERS：启动完成
- LOADING_PARAMETERS → RUNNING：参数有效
- LOADING_PARAMETERS → SAFE_MODE：参数无效/过期
- RUNNING → SAFE_MODE：熔断触发或参数过期
- SAFE_MODE → RUNNING：熔断恢复且参数有效

## 正确性属性

*属性是一个特征或行为，应该在系统的所有有效执行中保持为真。属性是人类可读规范和机器可验证正确性保证之间的桥梁。*

### 参数加载与校验属性

**属性 1：参数完整性校验**
*对于任意* 参数包 JSON，如果缺失任一必需字段，则系统应拒绝加载该参数包
**验证：需求 1.3**

**属性 2：固定值校验**
*对于任意* 参数包，如果 symbol ≠ "EURUSD" 或 timeframe ≠ "H4" 或 bias ≠ "short_only"，则系统应拒绝加载并进入 Safe_Mode
**验证：需求 1.7, 1.8, 1.9**

**属性 3：参数选择优先级**
*对于任意* 一组参数包（新旧参数），系统应按以下优先级选择：(1) 当前时间在有效期内的参数中选择 version 最大的；(2) 若无有效参数但旧参数仍有效，继续使用旧参数；(3) 若无任何有效参数，进入 Safe_Mode
**验证：需求 1.6, 8.4**

**属性 4：时间格式解析**
*对于任意* 符合 ISO 8601 格式（YYYY-MM-DDTHH:MM:SSZ）的时间字符串，系统应正确解析为 datetime 类型
**验证：需求 1.12, 4.6, 8.5**

**属性 5：tp_ratios 总和校验**
*对于任意* tp_ratios 数组，如果 abs(sum(tp_ratios) - 1.0) > 1e-6，则系统应拒绝加载该参数包
**验证：需求 1.2（隐含）**

### 策略执行属性

**属性 6：趋势过滤一致性**
*对于任意* 价格 P 和 EMA200 值 E，当 bias = "short_only" 时，系统允许做空当且仅当 P < E
**验证：需求 2.1**

**属性 7：区间过滤一致性**
*对于任意* 价格 P 和入场区间 [min, max]，系统继续评估入场条件当且仅当 min ≤ P ≤ max
**验证：需求 2.2, 2.3**

**属性 8：回踩检测正确性**
*对于任意* K 线序列和 EMA50 值序列，如果最近 lookback_period 根 K 线中存在任一 K 线的最低价在 EMA50 ± touch_tolerance 点范围内，则系统应标记回踩条件满足
**验证：需求 2.4**

**属性 9：看跌吞没形态识别**
*对于任意* 连续两根 K 线，如果当前 K 线为阴线、前一 K 线为阳线、当前开盘高于前一收盘、当前收盘低于前一开盘，则系统应识别为看跌吞没形态
**验证：需求 2.5**

**属性 10：看跌 Pin Bar 形态识别**
*对于任意* K 线，如果为阴线、上影线 >= 实体 * 2、下影线 <= 实体 * 0.5，则系统应识别为看跌 Pin Bar 形态
**验证：需求 2.6**

**属性 11：止损计算正确性**
*对于任意* invalid_above 价格和 Signal_K 高点，止损价格应等于 max(invalid_above, Signal_K 高点 + buffer)
**验证：需求 2.8**

**属性 12：拆单手数精度**
*对于任意* 总手数和 tp_ratios，拆分后所有订单的手数总和与总手数的误差应不超过一个 lot_step
**验证：需求 2.10**

**属性 13：拆单余量分配**
*对于任意* 拆单操作，如果存在舍入余量，则余量应分配到最后一个订单
**验证：需求 2.11**

**属性 14：拆单止盈对应**
*对于任意* tp_levels 数组和拆单结果，第 i 个订单的止盈价格应等于 tp_levels[i]
**验证：需求 2.12**

**属性 15：入场条件完整性**
*对于任意* 市场状态，如果任一入场条件（趋势、区间、回踩、形态）不满足，则系统应拒绝开仓
**验证：需求 2.13**

### 风险管理属性

**属性 16：单笔风险限制**
*对于任意* 账户净值、风险百分比和止损距离，计算出的手数应确保单笔风险 ≤ 账户净值 * risk.per_trade
**验证：需求 3.1**

**属性 17：点差过滤**
*对于任意* 当前点差，如果点差 > max_spread_points，则系统应拒绝开仓
**验证：需求 3.4**

### 时间过滤属性

**属性 18：新闻窗口过滤**
*对于任意* 当前时间和 news_blackout 窗口数组，如果当前时间在任一窗口内，则系统应禁止开新仓
**验证：需求 4.1**

**属性 19：交易时段过滤**
*对于任意* 当前时间和 session_filter，如果 session_filter.enabled = true 且当前小时不在 allowed_hours_utc 中，则系统应禁止开新仓
**验证：需求 4.2**

**属性 20：多窗口重叠处理**
*对于任意* 多个重叠的 news_blackout 窗口，系统应识别所有窗口并在任一窗口内禁止开仓
**验证：需求 4.3**

### Blockcell 参数生成属性

**属性 21：参数包字段完整性**
*对于任意* Blockcell 生成的参数包，应包含所有必需字段
**验证：需求 7.2**

**属性 22：版本号唯一性**
*对于任意* 两次参数包生成操作，生成的版本号应不同
**验证：需求 7.4**


## 错误处理

### 错误分类

1. **参数错误**：
   - 文件不存在
   - JSON 格式错误
   - 必需字段缺失
   - 固定值不匹配
   - 时间格式错误
   - 处理：拒绝加载，进入 Safe_Mode（如无旧参数）或保持旧参数

2. **订单错误**：
   - 服务器繁忙（可重试）
   - 网络连接中断（可重试）
   - 价格变化（可重试）
   - 止损无效（不可重试）
   - 手数无效（不可重试）
   - 资金不足（不可重试）
   - 处理：记录错误，可重试错误最多重试 3 次，不可重试错误立即放弃

3. **市场数据错误**：
   - 点差异常
   - 价格跳空
   - 数据缺失
   - 处理：采用保守策略，拒绝开仓

4. **系统错误**：
   - 内存不足
   - 文件系统错误
   - 未预期的异常
   - 处理：记录错误，进入 Safe_Mode，保护账户安全

### 错误恢复策略

```
1. 参数加载失败：
   - 如果有旧参数且仍有效：继续使用旧参数
   - 如果无旧参数或旧参数已过期：进入 Safe_Mode
   - 定期重试加载（每 5 分钟）

2. 订单执行失败：
   - 可重试错误：等待 1 秒后重试，最多 3 次
   - 不可重试错误：记录错误，放弃本次开仓
   - 不影响后续信号评估

3. 熔断触发：
   - 记录熔断原因和恢复时间
   - 禁止开新仓
   - 继续管理已有持仓
   - 到达恢复时间后自动恢复

4. Safe_Mode：
   - 禁止开新仓
   - 继续管理已有持仓（止损、止盈）
   - 定期检查参数是否恢复有效
   - 参数恢复有效后自动退出 Safe_Mode
```

### 日志记录

所有错误都应记录到日志，包含：
- 时间戳（UTC）
- 错误类型
- 错误消息
- 上下文信息（参数版本、市场状态等）
- 处理结果（重试/放弃/进入 Safe_Mode）


## 测试策略

### 双重测试方法

本系统采用单元测试和属性测试相结合的方法：

- **单元测试**：验证特定示例、边缘情况和错误条件
- **属性测试**：验证通用属性在所有输入下都成立
- 两者互补，共同提供全面的测试覆盖

### 单元测试

单元测试专注于：

1. **特定示例**：
   - 加载有效的参数包示例
   - 识别特定的看跌吞没形态
   - 计算特定场景下的止损

2. **边缘情况**：
   - 空参数文件
   - 极小/极大的手数
   - 边界价格（刚好在区间边缘）
   - 时间边界（刚好在窗口开始/结束）

3. **错误条件**：
   - 缺失必需字段
   - 无效的固定值
   - 网络错误
   - 服务器错误

4. **集成点**：
   - 参数加载器与策略引擎的集成
   - 策略引擎与风险管理器的集成
   - 风险管理器与订单执行器的集成

### 属性测试

属性测试使用 MQL4 的随机数生成器或外部属性测试库（如果可用）来验证通用属性。

**测试配置**：
- 每个属性测试至少运行 100 次迭代
- 使用随机种子确保可重现性
- 每个测试标记对应的设计属性

**属性测试示例**：

```mql4
// 属性 6：趋势过滤一致性
// Feature: mt4-forex-strategy-executor, Property 6: 趋势过滤一致性
void TestProperty_TrendFilterConsistency() {
    for (int i = 0; i < 100; i++) {
        // 生成随机价格和 EMA 值
        double price = RandomDouble(1.1000, 1.2000);
        double ema200 = RandomDouble(1.1000, 1.2000);
        
        // 测试属性
        bool should_allow = (price < ema200);
        bool actual_allow = CheckTrendFilter(ema200);
        
        Assert(should_allow == actual_allow, 
               "Trend filter inconsistency at price=" + DoubleToString(price) + 
               ", ema200=" + DoubleToString(ema200));
    }
}

// 属性 12：拆单手数精度
// Feature: mt4-forex-strategy-executor, Property 12: 拆单手数精度
void TestProperty_LotSplitPrecision() {
    double lot_step = MarketInfo(Symbol(), MODE_LOTSTEP);
    
    for (int i = 0; i < 100; i++) {
        // 生成随机总手数和比例
        double total_lots = RandomDouble(0.1, 10.0);
        double ratios[3] = {0.3, 0.4, 0.3};
        
        // 执行拆单
        LotSplit splits[];
        SplitLots(total_lots, ratios, splits);
        
        // 计算总和
        double sum = 0;
        for (int j = 0; j < ArraySize(splits); j++) {
            sum += splits[j].lots;
        }
        
        // 验证精度
        double error = MathAbs(sum - total_lots);
        Assert(error <= lot_step, 
               "Lot split precision error: " + DoubleToString(error) + 
               " > " + DoubleToString(lot_step));
    }
}
```

### 测试覆盖目标

- **参数加载与校验**：100% 覆盖所有校验规则
- **策略执行**：100% 覆盖所有入场条件
- **风险管理**：100% 覆盖所有熔断条件
- **时间过滤**：100% 覆盖所有时间窗口逻辑
- **错误处理**：覆盖所有错误类型和恢复路径

### 回测测试

除了单元测试和属性测试，还需要在 MT4 Strategy Tester 中进行回测：

1. **历史数据回测**：
   - 使用至少 6-12 个月的历史数据
   - 验证策略在不同市场条件下的表现
   - 检查是否有异常下单或崩溃

2. **参数敏感性测试**：
   - 测试不同的 entry_zone 范围
   - 测试不同的 lookback_period 值
   - 测试不同的风险百分比

3. **压力测试**：
   - 测试极端市场条件（大幅波动、跳空）
   - 测试参数频繁更新的情况
   - 测试长时间运行的稳定性

### 测试工具

- **MQL4 内置测试框架**：用于单元测试
- **MT4 Strategy Tester**：用于回测
- **自定义属性测试框架**：用于属性测试（如果 MQL4 没有现成的库）
- **日志分析工具**：用于分析测试日志和交易决策

### 持续测试

- 每次代码修改后运行所有单元测试和属性测试
- 每周运行一次完整的回测
- 每月审查测试覆盖率和测试结果
- 发现新的边缘情况时添加新的测试用例


## 部署与运维

### 部署架构

```
┌─────────────────────────────────────────────────────────┐
│                    开发机器                              │
│  ┌──────────────┐                                       │
│  │  Blockcell   │                                       │
│  │   + Skills   │                                       │
│  └──────┬───────┘                                       │
│         │                                               │
│         ▼                                               │
│  workspace/ea/signal_pack.json                          │
└─────────────────┬───────────────────────────────────────┘
                  │ (文件共享/同步)
                  ▼
┌─────────────────────────────────────────────────────────┐
│                   交易机器                               │
│  ┌──────────────────────────────────────────────────┐  │
│  │              MT4 Terminal                        │  │
│  │  ┌────────────────────────────────────────────┐ │  │
│  │  │           EA (Expert Advisor)              │ │  │
│  │  │  - 读取 signal_pack.json                   │ │  │
│  │  │  - 执行策略逻辑                             │ │  │
│  │  │  - 管理订单                                 │ │  │
│  │  └────────────────────────────────────────────┘ │  │
│  └──────────────────────────────────────────────────┘  │
│                      │                                  │
│                      ▼                                  │
│              MT4 Broker Server                          │
└─────────────────────────────────────────────────────────┘
```

### 部署步骤

1. **Blockcell 侧**：
   ```bash
   # 1. 安装 Blockcell 和相关技能
   # 2. 配置 forex_strategy_generator Skill
   # 3. 配置 Cron 任务（每天 UTC 06:00）
   # 4. 设置参数包输出路径：workspace/ea/signal_pack.json
   ```

2. **MT4 EA 侧**：
   ```
   # 1. 编译 EA 源码（.mq4 → .ex4）
   # 2. 复制 .ex4 文件到 MT4/MQL4/Experts/ 目录
   # 3. 配置 EA 输入参数：
   #    - ParamFilePath: 参数包文件路径
   #    - DryRun: false（实盘）或 true（模拟）
   #    - LogLevel: INFO
   #    - ServerUTCOffset: 服务器时区偏移（例如：+2 表示 UTC+2）
   # 4. 在 MT4 图表上加载 EA（EUR/USD H4）
   # 5. 启用自动交易
   ```

3. **文件同步**（如果 Blockcell 和 MT4 在不同机器）：
   ```bash
   # 选项 1：使用共享文件夹（Windows 网络共享、NFS）
   # 选项 2：使用文件同步工具（rsync、Dropbox、OneDrive）
   # 选项 3：使用 FTP/SFTP 自动上传
   ```

### 配置管理

**EA 输入参数**：
```mql4
input string ParamFilePath = "C:\\Users\\Trader\\workspace\\ea\\signal_pack.json";
input bool DryRun = false;
input string LogLevel = "INFO";  // DEBUG, INFO, WARN, ERROR
input int ParamCheckInterval = 300;  // 秒，参数检查间隔
input int ServerUTCOffset = 2;  // 服务器时区偏移（小时），例如：+2 表示 UTC+2
```

**Blockcell Cron 配置**：
```json
{
  "id": "forex_param_generator",
  "schedule": "0 6 * * *",  // 每天 UTC 06:00
  "command": "run_skill",
  "args": {
    "skill": "forex_strategy_generator",
    "params": {
      "symbol": "EURUSD",
      "timeframe": "H4"
    }
  }
}
```

### 监控与告警

1. **参数包监控**：
   - 检查参数包是否按时生成
   - 检查参数包是否有效
   - 检查参数包版本号是否递增

2. **EA 状态监控**：
   - 检查 EA 是否在运行
   - 检查 EA 是否在 Safe_Mode
   - 检查熔断状态

3. **交易监控**：
   - 监控开仓频率
   - 监控盈亏情况
   - 监控滑点和点差

4. **告警规则**：
   - 参数包超过 2 小时未更新 → 发送告警
   - EA 进入 Safe_Mode → 发送告警
   - 触发熔断 → 发送告警
   - 单日亏损超过阈值 → 发送告警
   - 连续 3 笔亏损 → 发送告警

### 日志管理

**日志位置**：
- MT4 日志：MT4/MQL4/Logs/YYYYMMDD.log
- EA 自定义日志：MT4/MQL4/Files/EA_YYYYMMDD.log

**日志轮转**：
- 每天生成新的日志文件
- 保留最近 30 天的日志
- 压缩归档超过 30 天的日志

**日志分析**：
- 定期审查拒单原因
- 分析熔断触发频率
- 统计信号评估结果
- 追踪参数版本使用情况

### 备份与恢复

1. **参数包备份**：
   - 每次生成新参数包时备份旧版本
   - 保留最近 30 天的参数包历史
   - 格式：signal_pack_YYYYMMDD-HHMM.json

2. **EA 状态备份**：
   - 定期保存 EA 状态（风险状态、熔断状态）
   - 使用 GlobalVariable 或文件存储
   - EA 重启时恢复状态

3. **灾难恢复**：
   - 如果参数包丢失：使用最近的备份
   - 如果 EA 崩溃：重启 MT4，EA 自动恢复
   - 如果 Blockcell 故障：手动生成参数包或使用备份

### 性能优化

1. **参数加载优化**：
   - 缓存已加载的参数包
   - 只在文件修改时重新加载
   - 使用文件修改时间戳检测变化

2. **计算优化**：
   - 缓存 EMA 计算结果
   - 只在新 K 线时重新计算
   - 避免重复的形态识别

3. **内存优化**：
   - 限制历史数据缓存大小
   - 及时清理已关闭的订单记录
   - 避免内存泄漏

### 安全考虑

1. **参数包安全**：
   - 使用文件权限限制访问
   - 考虑加密敏感参数（如果需要）
   - 验证参数包来源（签名）

2. **EA 安全**：
   - 限制 EA 的文件访问权限
   - 不在日志中记录敏感信息（账户密码）
   - 使用 MT4 的 DLL 导入限制

3. **网络安全**：
   - 使用加密连接（MT4 支持 SSL/TLS）
   - 限制 MT4 的网络访问
   - 定期更新 MT4 客户端

### 版本管理

1. **EA 版本**：
   - 使用语义化版本号（v1.0.0）
   - 在 EA 注释中记录版本号
   - 每次发布时更新版本号

2. **参数包版本**：
   - 使用时间戳作为版本号（YYYYMMDD-HHMM）
   - 确保版本号单调递增
   - 在日志中记录使用的参数版本

3. **兼容性**：
   - 保持参数包格式向后兼容
   - 如果需要破坏性变更，更新 EA 主版本号
   - 提供迁移工具或文档


## 时间处理最佳实践

### 时间处理原则

为确保时间逻辑的正确性和一致性，EA 必须遵循以下原则：

1. **统一时钟源**：
   - 所有交易和风控逻辑统一使用 `TimeCurrent()`（MT4 服务器时间）作为基准
   - 不使用本机时间（`TimeLocal()`）或 GMT 时间（`TimeGMT()`）作为决策依据

2. **UTC 转换方式**：
   - 使用 `ServerUTCOffset` 输入参数将服务器时间转换为 UTC
   - 转换公式：`utc_now = TimeCurrent() - ServerUTCOffset * 3600`
   - 所有需要 UTC 时间的地方都使用 `ConvertToUTC(TimeCurrent())`

3. **禁止使用快照函数**：
   - 禁止使用 `Hour()`, `Minute()`, `Seconds()`, `Day()`, `Month()`, `Year()`
   - 这些函数返回的是程序启动时的快照值，在循环中不会更新
   - 必须使用 `TimeHour(t)`, `TimeMinute(t)`, `TimeSeconds(t)`, `TimeDay(t)`, `TimeMonth(t)`, `TimeYear(t)`

4. **TimeGMT/TimeLocal 仅用于诊断**：
   - `TimeGMT()` 和 `TimeLocal()` 依赖本机时钟和夏令时设置
   - 仅用于日志诊断和调试，不用于交易决策主路径

5. **ISO 8601 解析**：
   - 参数包中的时间字符串格式为 `YYYY-MM-DDTHH:MM:SSZ`
   - 手工解析到 `MqlDateTime` 结构体，然后使用 `StructToTime()` 转换
   - 不直接使用 `StrToTime()` 解析带 T/Z 的字符串（可能不支持）

### ISO 8601 解析实现

```mql4
// 解析 ISO 8601 时间字符串（YYYY-MM-DDTHH:MM:SSZ）
datetime ParseISO8601(string iso_str) {
    // 移除 T 和 Z 字符
    StringReplace(iso_str, "T", " ");
    StringReplace(iso_str, "Z", "");
    
    // 解析为 MqlDateTime
    MqlDateTime dt;
    string parts[];
    StringSplit(iso_str, ' ', parts);
    
    if (ArraySize(parts) != 2) return 0;
    
    // 解析日期部分 YYYY-MM-DD
    string date_parts[];
    StringSplit(parts[0], '-', date_parts);
    if (ArraySize(date_parts) != 3) return 0;
    
    dt.year = (int)StringToInteger(date_parts[0]);
    dt.mon = (int)StringToInteger(date_parts[1]);
    dt.day = (int)StringToInteger(date_parts[2]);
    
    // 解析时间部分 HH:MM:SS
    string time_parts[];
    StringSplit(parts[1], ':', time_parts);
    if (ArraySize(time_parts) != 3) return 0;
    
    dt.hour = (int)StringToInteger(time_parts[0]);
    dt.min = (int)StringToInteger(time_parts[1]);
    dt.sec = (int)StringToInteger(time_parts[2]);
    
    // 转换为 datetime（UTC）
    return StructToTime(dt);
}
```

### 时间比较示例

```mql4
// 正确的方式：检查是否在新闻窗口内
bool IsInNewsBlackout(NewsBlackout blackouts[]) {
    datetime current_utc = ConvertToUTC(TimeCurrent());
    
    for (int i = 0; i < ArraySize(blackouts); i++) {
        if (blackouts[i].start <= current_utc && current_utc <= blackouts[i].end) {
            return true;
        }
    }
    return false;
}

// 正确的方式：检查是否在交易时段
bool IsInTradingSession(SessionFilter filter) {
    if (!filter.enabled) return true;
    
    datetime current_utc = ConvertToUTC(TimeCurrent());
    int current_hour = TimeHour(current_utc);  // 使用 TimeHour，不是 Hour()
    
    for (int i = 0; i < ArraySize(filter.allowed_hours_utc); i++) {
        if (current_hour == filter.allowed_hours_utc[i]) {
            return true;
        }
    }
    return false;
}

// 正确的方式：日切判断
bool ShouldResetDaily(int &last_reset_date) {
    datetime current_utc = ConvertToUTC(TimeCurrent());
    int current_date = TimeYear(current_utc) * 10000 + 
                      TimeMonth(current_utc) * 100 + 
                      TimeDay(current_utc);
    
    if (current_date != last_reset_date) {
        last_reset_date = current_date;
        return true;
    }
    return false;
}
```

### 常见错误示例

```mql4
// ❌ 错误：使用快照函数
int current_hour = Hour();  // 这是程序启动时的小时，不会更新

// ✅ 正确：使用时间函数
datetime current_utc = ConvertToUTC(TimeCurrent());
int current_hour = TimeHour(current_utc);

// ❌ 错误：直接使用 StrToTime 解析 ISO 8601
datetime dt = StrToTime("2025-03-09T08:00:00Z");  // 可能失败

// ✅ 正确：手工解析
datetime dt = ParseISO8601("2025-03-09T08:00:00Z");

// ❌ 错误：使用本机时间
datetime local_time = TimeLocal();  // 依赖本机时钟

// ✅ 正确：使用服务器时间
datetime server_time = TimeCurrent();
datetime utc_time = ConvertToUTC(server_time);
```

