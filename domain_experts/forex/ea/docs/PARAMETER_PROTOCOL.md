# 参数协议文档

## 概述

本文档描述 MT4 外汇策略执行系统（ForexStrategyExecutor）的参数包 JSON 格式定义。参数包由 Blockcell 参数生成器生成，EA 在启动时加载并执行。

## JSON 结构

```json
{
  "version": "string (必需)",
  "symbol": "string (必需)",
  "timeframe": "string (必需)",
  "bias": "string (必需)",
  "valid_from": "string (必需)",
  "valid_to": "string (必需)",
  "entry_zone": "object (必需)",
  "invalid_above": "number (必需)",
  "tp_levels": "array<number> (必需)",
  "tp_ratios": "array<number> (必需)",
  "ema_fast": "number (必需)",
  "ema_trend": "number (必需)",
  "lookback_period": "number (必需)",
  "touch_tolerance": "number (必需)",
  "pattern": "array<string> (必需)",
  "risk": "object (必需)",
  "max_spread_points": "number (必需)",
  "max_slippage_points": "number (必需)",
  "news_blackout": "array<object> (可选)",
  "session_filter": "object (可选)",
  "comment": "string (可选)"
}
```

## 字段说明

### 基本信息字段

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `version` | string | 是 | 参数包版本号，格式：`YYYYMMDD-HHMM` |
| `symbol` | string | 是 | 交易品种，V1 固定为 `"EURUSD"` |
| `timeframe` | string | 是 | 时间周期，V1 固定为 `"H4"` |
| `bias` | string | 是 | 交易方向，V1 固定为 `"short_only"` |

### 时间字段

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `valid_from` | string | 是 | 参数生效时间，ISO 8601 格式：`YYYY-MM-DDTHH:MM:SSZ` |
| `valid_to` | string | 是 | 参数过期时间，ISO 8601 格式：`YYYY-MM-DDTHH:MM:SSZ` |

### 入场参数

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `entry_zone.min` | number | 是 | 入场价格区间下限 |
| `entry_zone.max` | number | 是 | 入场价格区间上限 |
| `invalid_above` | number | 是 | 失效价格（做空时为止损参考） |

### 止盈参数

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `tp_levels` | array | 是 | 止盈价格数组，如 `[1.1550, 1.1500, 1.1350]` |
| `tp_ratios` | array | 是 | 止盈手数比例数组，总和必须为 1.0 |

### 技术指标参数

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `ema_fast` | number | 是 | 快速 EMA 周期，默认 50 |
| `ema_trend` | number | 是 | 趋势 EMA 周期，默认 200 |
| `lookback_period` | number | 是 | 回看周期（K 线数量），用于 EMA 回踩检测 |
| `touch_tolerance` | number | 是 | 回踩容差（点数），价格在 EMA ± N 点范围内视为回踩 |

### 形态参数

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `pattern` | array | 是 | 允许的形态类型数组，支持：`"bearish_engulfing"`、`"bearish_pin_bar"` |

### 风险参数

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `risk.per_trade` | number | 是 | 单笔风险百分比，如 0.01 表示 1% |
| `risk.daily_max_loss` | number | 是 | 单日最大亏损百分比，如 0.02 表示 2% |
| `risk.consecutive_loss_limit` | number | 是 | 连续亏损笔数限制，如 3 |

### 执行参数

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `max_spread_points` | number | 是 | 最大允许点差（点数） |
| `max_slippage_points` | number | 是 | 最大允许滑点（点数） |

### 可选字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `news_blackout` | array | 新闻禁开仓时间窗口数组 |
| `news_blackout[].start` | string | 窗口开始时间，ISO 8601 格式 |
| `news_blackout[].end` | string | 窗口结束时间，ISO 8601 格式 |
| `news_blackout[].reason` | string | 事件原因说明 |
| `session_filter` | object | 交易时段过滤配置 |
| `session_filter.enabled` | boolean | 是否启用时段过滤 |
| `session_filter.allowed_hours_utc` | array | 允许交易的 UTC 小时数组 |
| `comment` | string | 备注信息 |

## 校验规则

### 必需字段
- `version`、`symbol`、`timeframe`、`bias` 不能为空
- `valid_from` 和 `valid_to` 必须有效且 `valid_from < valid_to`
- `entry_zone.min < entry_zone.max`
- `tp_levels` 和 `tp_ratios` 长度必须相同
- `tp_ratios` 总和必须为 1.0（允许 ±0.000001 误差）

### V1 固定值
- `symbol` 必须为 `"EURUSD"`
- `timeframe` 必须为 `"H4"`
- `bias` 必须为 `"short_only"`

### 数值范围
- `risk.per_trade` 必须在 (0, 0.1] 范围内
- `risk.daily_max_loss` 必须在 (0, 0.2] 范围内
- 所有正数字段必须大于 0

## 示例参数包

### 完整示例

```json
{
  "version": "20250309-0800",
  "symbol": "EURUSD",
  "timeframe": "H4",
  "bias": "short_only",
  "valid_from": "2025-03-09T08:00:00Z",
  "valid_to": "2025-03-10T08:00:00Z",
  "entry_zone": {
    "min": 1.1650,
    "max": 1.1700
  },
  "invalid_above": 1.1720,
  "tp_levels": [1.1550, 1.1500, 1.1350],
  "tp_ratios": [0.3, 0.4, 0.3],
  "ema_fast": 50,
  "ema_trend": 200,
  "lookback_period": 10,
  "touch_tolerance": 10,
  "pattern": ["bearish_engulfing", "bearish_pin_bar"],
  "risk": {
    "per_trade": 0.01,
    "daily_max_loss": 0.02,
    "consecutive_loss_limit": 3
  },
  "max_spread_points": 20,
  "max_slippage_points": 10,
  "news_blackout": [
    {
      "start": "2025-03-09T13:30:00Z",
      "end": "2025-03-09T14:30:00Z",
      "reason": "US CPI Data Release"
    }
  ],
  "session_filter": {
    "enabled": true,
    "allowed_hours_utc": [8, 9, 10, 11, 12, 13, 14, 15, 16]
  },
  "comment": "EUR/USD bearish setup with EMA200 trend filter"
}
```

### 最小示例（无可选字段）

```json
{
  "version": "20250309-0800",
  "symbol": "EURUSD",
  "timeframe": "H4",
  "bias": "short_only",
  "valid_from": "2025-03-09T08:00:00Z",
  "valid_to": "2025-03-10T08:00:00Z",
  "entry_zone": {
    "min": 1.1650,
    "max": 1.1700
  },
  "invalid_above": 1.1720,
  "tp_levels": [1.1550, 1.1500],
  "tp_ratios": [0.5, 0.5],
  "ema_fast": 50,
  "ema_trend": 200,
  "lookback_period": 10,
  "touch_tolerance": 10,
  "pattern": ["bearish_engulfing"],
  "risk": {
    "per_trade": 0.01,
    "daily_max_loss": 0.02,
    "consecutive_loss_limit": 3
  },
  "max_spread_points": 20,
  "max_slippage_points": 10
}
```

## 回测内嵌参数示例

在 MT4 Strategy Tester 中使用内嵌参数时，需要将 JSON 压缩为单行：

```json
{"version":"20250309-0800","symbol":"EURUSD","timeframe":"H4","bias":"short_only","valid_from":"2025-03-09T08:00:00Z","valid_to":"2025-03-10T08:00:00Z","entry_zone":{"min":1.1650,"max":1.1700},"invalid_above":1.1720,"tp_levels":[1.1550,1.1500,1.1350],"tp_ratios":[0.3,0.4,0.3],"ema_fast":50,"ema_trend":200,"lookback_period":10,"touch_tolerance":10,"pattern":["bearish_engulfing","bearish_pin_bar"],"risk":{"per_trade":0.01,"daily_max_loss":0.02,"consecutive_loss_limit":3},"max_spread_points":20,"max_slippage_points":10}
```

## 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| 1.0.0 | 2025-03-09 | 初始版本 |