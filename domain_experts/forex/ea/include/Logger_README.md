# Logger 模块使用说明

## 概述

Logger 模块提供统一的日志记录功能，支持多级别日志、字段强校验、文件输出和 MT4 日志窗口输出。

## 功能特性

### 1. 日志级别

- **DEBUG**: 调试信息，详细的执行过程
- **INFO**: 一般信息，正常的操作流程
- **WARN**: 警告信息，需要注意但不影响运行
- **ERROR**: 错误信息，影响功能的问题

### 2. 统一日志 Schema

所有日志都遵循统一的格式：

```
[timestamp] [level] [component] [symbol=XXX] [rule=XXX] [version=XXX] [decision=XXX] message
```

必需字段：
- `timestamp`: UTC 时间戳（ISO 8601 格式）
- `level`: 日志级别
- `component`: 组件名称
- `message`: 日志消息

可选字段：
- `symbol`: 交易品种
- `rule`: 触发的规则
- `version`: 参数版本号
- `decision`: 决策结果

### 3. 输出目标

- **MT4 日志窗口**: 所有日志都会输出到 MT4 的 Experts 日志窗口
- **日志文件**: 日志同时写入到 `MQL4/Files/EA_YYYYMMDD.log` 文件

## 使用方法

### 初始化日志系统

```mql4
// 在 OnInit() 中初始化
InitLogger("INFO");  // 设置日志级别为 INFO
```

### 基础日志函数

```mql4
// 调试日志
LogDebug("Component", "调试信息");

// 信息日志
LogInfo("Component", "一般信息");

// 警告日志
LogWarn("Component", "警告信息");

// 错误日志
LogError("Component", "错误信息");
```

### 专用日志函数

#### 1. 记录参数加载

```mql4
LogParameterLoad(
    "20250309-0800",  // param_version
    "SUCCESS",        // status: SUCCESS, FAILED, EXPIRED
    "参数加载成功"     // message (可选)
);
```

#### 2. 记录信号评估

```mql4
LogSignalEvaluation(
    "EURUSD",              // symbol (必需)
    "TREND_FILTER",        // rule_hit (必需)
    "20250309-0800",       // param_version (必需)
    "OPEN",                // decision (必需): OPEN, REJECTED
    "趋势过滤通过"          // message
);
```

#### 3. 记录开仓

```mql4
LogOrderOpen(
    12345,                 // ticket
    "EURUSD",              // symbol (必需)
    0.30,                  // lots
    1.1680,                // entry
    1.1720,                // stop_loss
    1.1550,                // take_profit
    "20250309-0800",       // param_version (必需)
    "OPENED",              // decision (必需)
    0.5                    // actual_slippage (可选)
);
```

#### 4. 记录拒单

```mql4
LogOrderReject(
    "EURUSD",              // symbol (必需)
    "SPREAD_CHECK",        // rule_hit (必需)
    "20250309-0800",       // param_version (必需)
    "REJECTED",            // decision (必需)
    "点差超限: 25 > 20"     // reason
);
```

#### 5. 记录熔断

```mql4
LogCircuitBreaker(
    "DAILY_LOSS",          // circuit_type (必需)
    -2.1,                  // trigger_value (必需)
    D'2025.03.09 23:59:59', // recover_at_utc (必需)
    "日亏损达到 -2.1%",     // reason (必需)
    "DAILY_LOSS_LIMIT",    // rule_hit (必需)
    "CIRCUIT_BREAKER"      // decision (必需)
);
```

#### 6. 记录平仓

```mql4
LogOrderClose(
    12345,                 // ticket
    "EURUSD",              // symbol (必需)
    15.50,                 // profit
    "CLOSED"               // decision (必需)
);
```

### 辅助日志函数

```mql4
// 记录订单错误
LogOrderError("EURUSD", 134, "资金不足", "20250309-0800", "ERROR");

// 记录滑点警告
LogSlippageWarning("EURUSD", 12.5, 10.0, "20250309-0800");

// 记录点差警告
LogSpreadWarning("EURUSD", 25.0, 20.0, "20250309-0800");

// 记录时间过滤
LogTimeFilter("NEWS_BLACKOUT", "US CPI 数据发布", "20250309-0800");

// 记录 Safe Mode 切换
LogSafeModeTransition("参数已过期", "20250309-0800");

// 记录状态恢复
LogStateRecovery("SAFE_MODE", "RUNNING", "参数已更新");
```

### 关闭日志系统

```mql4
// 在 OnDeinit() 中关闭
CloseLogger();
```

## 日志示例

### 参数加载成功

```
[2025-03-09T08:00:00Z] [INFO] [ParamLoader] [version=20250309-0800] [decision=LOADED] 参数加载成功
```

### 信号评估

```
[2025-03-09T12:00:00Z] [INFO] [Strategy] [symbol=EURUSD] [rule=ALL_CONDITIONS] [version=20250309-0800] [decision=OPEN] 信号评估: 所有条件满足
```

### 开仓成功

```
[2025-03-09T12:00:05Z] [INFO] [OrderExec] [symbol=EURUSD] [version=20250309-0800] [decision=OPENED] 开仓成功 #12345 lots=0.30 entry=1.16800 sl=1.17200 tp=1.15500 slippage=0.5pts
```

### 拒单

```
[2025-03-09T14:00:00Z] [WARN] [Strategy] [symbol=EURUSD] [rule=SPREAD_CHECK] [version=20250309-0800] [decision=REJECTED] 拒单: 点差超限: 25 > 20
```

### 熔断触发

```
[2025-03-09T16:00:00Z] [ERROR] [RiskMgr] [rule=DAILY_LOSS_LIMIT] [decision=CIRCUIT_BREAKER] 熔断触发 [DAILY_LOSS] trigger=-2.10 recover_at=2025-03-09T23:59:59Z reason=日亏损达到 -2.1%
```

## 字段强校验

专用日志函数会进行字段强校验，确保必需字段都已提供：

- `LogSignalEvaluation`: 必需 symbol, rule_hit, param_version, decision
- `LogOrderOpen`: 必需 symbol, param_version, decision
- `LogOrderReject`: 必需 symbol, rule_hit, param_version, decision
- `LogCircuitBreaker`: 必需 circuit_type, reason, rule_hit, decision
- `LogOrderClose`: 必需 symbol, decision

如果缺少必需字段，会记录错误日志并拒绝写入。

## 日志级别过滤

日志系统会根据设置的日志级别过滤输出：

- `DEBUG`: 输出所有日志
- `INFO`: 输出 INFO, WARN, ERROR
- `WARN`: 输出 WARN, ERROR
- `ERROR`: 只输出 ERROR

## 注意事项

1. **必须初始化**: 在使用日志功能前必须调用 `InitLogger()`
2. **必须关闭**: 在 EA 停止时必须调用 `CloseLogger()` 以确保日志正确写入
3. **字段完整性**: 使用专用日志函数时，必须提供所有必需字段
4. **UTC 时间**: 所有时间戳都使用 UTC 时区
5. **文件权限**: 确保 MT4 有权限写入 `MQL4/Files` 目录

## 需求映射

- **需求 5.1**: LogParameterLoad - 记录参数加载
- **需求 5.2**: LogSignalEvaluation - 记录信号评估
- **需求 5.3**: LogOrderOpen - 记录开仓
- **需求 5.4**: LogOrderReject - 记录拒单
- **需求 5.5**: LogCircuitBreaker - 记录熔断
- **需求 5.6**: LogOrderClose - 记录平仓
- **需求 5.7**: 统一 Schema 和字段强校验
- **需求 3.7**: 熔断事件记录
