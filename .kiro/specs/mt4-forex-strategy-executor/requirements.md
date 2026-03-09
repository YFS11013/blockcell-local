# 需求文档：MT4 外汇策略执行系统

## 简介

本系统旨在实现"AI 决策建议 + EA 确定性执行"的外汇交易自动化方案。Blockcell 负责通过 AI 分析生成策略参数建议，MT4 EA 负责读取参数并按规则执行交易。系统确保所有交易决策可追溯、可回测、可风控。

V1 版本专注于 EUR/USD 空头策略，采用 H4 周期、EMA 趋势过滤、形态确认的交易框架。

## 术语表

- **System**: MT4 外汇策略执行系统
- **EA**: Expert Advisor，MT4 自动交易程序
- **Blockcell**: AI 决策建议生成器
- **Parameter_Pack**: 策略参数包（JSON 格式）
- **Signal_K**: 触发信号的 K 线
- **Entry_Zone**: 入场价格区间
- **Risk_Manager**: 风险管理模块
- **News_Blackout**: 新闻事件禁开仓时间窗口（UTC 时区）
- **Dry_Run_Mode**: 模拟运行模式（不下真实订单）
- **Safe_Mode**: 安全模式，EA 停止开新仓但保持持仓管理
- **Lookback_Period**: 回看周期，用于判断 EMA 回踩的 K 线数量
- **Touch_Tolerance**: 回踩容差，价格接近 EMA 的点数范围

## 需求

### 需求 1：参数文件读取与校验

**用户故事：** 作为 EA，我需要从本地文件读取策略参数，以便根据 AI 建议执行交易策略。

#### 验收标准

1. WHEN EA 启动或定时检查时，THE System SHALL 从指定路径读取 `signal_pack.json` 文件
2. WHEN 参数文件包含所有必需字段时，THE System SHALL 成功解析并加载参数
3. WHEN 参数文件缺失任一必需字段时，THE System SHALL 拒绝加载并记录错误日志
4. WHEN 参数文件解析失败且存在上一次有效参数时，THE System SHALL 保持上一次有效参数并记录警告
5. WHEN 参数文件解析失败且不存在上一次有效参数时，THE System SHALL 进入 Safe_Mode 并禁止开新仓
6. WHEN 选择使用哪个参数时，THE System SHALL 按以下优先级选择：首先选择当前时间在 valid_from 和 valid_to 之间的参数；若同时存在多个有效参数，则选择 version 字段值更大的参数；若新参数未到 valid_from 且旧参数仍在有效期内，则继续使用旧参数；若无任何有效参数，则进入 Safe_Mode
7. WHEN 参数文件的 `symbol` 不等于 "EURUSD" 时，THE System SHALL 拒绝加载并进入 Safe_Mode
8. WHEN 参数文件的 `timeframe` 不等于 "H4" 时，THE System SHALL 拒绝加载并进入 Safe_Mode
9. WHEN 参数文件的 `bias` 不等于 "short_only" 时，THE System SHALL 拒绝加载并进入 Safe_Mode
10. THE System SHALL 校验以下必需字段：`symbol`, `timeframe`, `valid_from`, `valid_to`, `bias`, `entry_zone`, `invalid_above`, `tp_levels`, `tp_ratios`, `ema_fast`, `ema_trend`, `pattern`, `lookback_period`, `touch_tolerance`, `risk.per_trade`, `risk.daily_max_loss`, `risk.consecutive_loss_limit`, `max_spread_points`, `max_slippage_points`, `version`
11. THE System SHALL 校验以下可选字段：`news_blackout`, `session_filter`, `comment`
12. THE System SHALL 使用 ISO 8601 格式（带 Z 后缀）解析所有时间字段

### 需求 2：EUR/USD H4 策略执行

**用户故事：** 作为交易员，我希望 EA 按照预定义的技术规则执行 EUR/USD 空头策略，以便实现人工交易框架的程序化。

#### 验收标准

1. WHEN 参数 `bias` 为 `short_only` 且当前收盘价低于 EMA200 时，THE System SHALL 允许观察做空机会
2. WHEN 当前价格在 `entry_zone` 范围内时，THE System SHALL 继续评估入场条件
3. WHEN 当前价格不在 `entry_zone` 范围内时，THE System SHALL 拒绝开仓
4. WHEN 最近 `lookback_period` 根 K 线中存在任一 K 线的最低价在 EMA50 上下 `touch_tolerance` 点范围内时，THE System SHALL 标记回踩条件满足
5. WHEN 出现看跌吞没形态（当前 K 线实体完全包含前一 K 线实体，且当前 K 线为阴线、前一 K 线为阳线）时，THE System SHALL 标记形态确认条件满足
6. WHEN 出现看跌 Pin Bar 形态（上影线长度 >= 实体长度的 2 倍，且下影线长度 <= 实体长度的 0.5 倍，且为阴线）时，THE System SHALL 标记形态确认条件满足
7. WHEN 所有入场条件满足且 Signal_K 收盘后，THE System SHALL 在下一根 K 线开盘时执行开仓
8. WHEN 开仓时，THE System SHALL 设置止损为 `max(invalid_above, Signal_K 高点 + buffer)`，其中 `buffer` 默认为 10 点
9. WHEN 开仓时，THE System SHALL 根据 `tp_levels` 和 `tp_ratios` 拆分为多个订单
10. WHEN 拆分订单时，THE System SHALL 确保所有订单的手数总和与计算出的总手数误差不超过一个 lot_step
11. WHEN 拆分订单时存在舍入余量时，THE System SHALL 将余量分配到最后一个订单
12. WHEN 拆分订单时，THE System SHALL 为每个订单设置对应的止盈价格
13. WHEN 任一入场条件不满足时，THE System SHALL 拒绝开仓并记录原因

### 需求 3：风险管理与熔断机制

**用户故事：** 作为风险管理者，我需要系统自动执行风控规则，以便保护账户资金安全。

#### 验收标准

1. WHEN 计算开仓手数时，THE System SHALL 确保单笔风险不超过账户净值的 `risk.per_trade` 百分比
2. WHEN 当日累计亏损达到账户净值的 `risk.daily_max_loss` 百分比时，THE System SHALL 禁止当天开新仓
3. WHEN 连续亏损笔数达到 `risk.consecutive_loss_limit` 时，THE System SHALL 暂停交易一天
4. WHEN 当前点差超过 `max_spread_points` 时，THE System SHALL 拒绝开仓
5. WHEN 下单时设置最大允许滑点为 `max_slippage_points` 时，THE System SHALL 在 OrderSend 函数中传递该参数
6. WHEN 订单成交后实际滑点超过 `max_slippage_points` 时，THE System SHALL 记录滑点事件到日志
7. WHEN 触发任何熔断条件时，THE System SHALL 记录熔断事件和原因
8. WHEN 熔断期结束时，THE System SHALL 自动恢复正常交易状态
9. WHEN 在 Safe_Mode 下时，THE System SHALL 继续管理已有持仓但不开新仓

### 需求 4：事件与时段过滤

**用户故事：** 作为交易员，我希望在重大新闻事件期间和非活跃时段避免交易，以便降低异常波动风险。

#### 验收标准

1. WHEN 当前时间（UTC）在 `news_blackout` 定义的任一时间窗口内时，THE System SHALL 禁止开新仓
2. WHEN `session_filter` 启用且当前时间（UTC）不在允许的交易时段内时，THE System SHALL 禁止开新仓
3. WHEN 多个时间窗口重叠时，THE System SHALL 正确识别并应用所有限制
4. WHEN 事件窗口结束时，THE System SHALL 自动恢复开仓权限
5. THE System SHALL 支持配置多个 `news_blackout` 时间窗口
6. THE System SHALL 使用 ISO 8601 格式（带 Z 后缀）解析所有时间字段

### 需求 5：日志与决策追踪

**用户故事：** 作为系统审计员，我需要完整的交易决策日志，以便事后复盘和责任追踪。

#### 验收标准

1. WHEN 加载参数文件时，THE System SHALL 记录参数版本号、加载时间和校验结果
2. WHEN 评估入场信号时，THE System SHALL 记录每个条件的判定结果
3. WHEN 执行开仓操作时，THE System SHALL 记录时间戳、品种、手数、价格、止损、止盈、参数版本号
4. WHEN 拒绝开仓时，THE System SHALL 记录拒绝原因和触发的规则
5. WHEN 触发风控熔断时，THE System SHALL 记录熔断类型、触发值和恢复时间
6. THE System SHALL 在每条日志中包含 `timestamp`, `symbol`, `rule_hit`, `param_version`, `decision` 字段
7. THE System SHALL 支持将日志输出到文件和 MT4 日志窗口

### 需求 6：Dry Run 模式

**用户故事：** 作为开发者，我需要在不下真实订单的情况下测试策略逻辑，以便验证系统行为。

#### 验收标准

1. WHEN `dry_run` 模式启用时，THE System SHALL 执行所有信号判定逻辑
2. WHEN `dry_run` 模式启用时，THE System SHALL 不执行真实的开仓、平仓操作
3. WHEN `dry_run` 模式启用时，THE System SHALL 输出模拟交易信号到日志
4. WHEN `dry_run` 模式启用时，THE System SHALL 在日志中明确标记为模拟模式
5. THE System SHALL 支持通过配置文件或输入参数切换 `dry_run` 模式

### 需求 7：Blockcell 参数包生成

**用户故事：** 作为 Blockcell 用户，我需要通过 AI 技能生成策略参数包，以便为 EA 提供交易建议。

#### 验收标准

1. WHEN 调用参数生成技能时，THE Blockcell SHALL 分析外汇新闻、技术面和基本面
2. WHEN 生成参数包时，THE Blockcell SHALL 输出包含所有必需字段的 JSON 文件
3. WHEN 生成参数包时，THE Blockcell SHALL 设置合理的 `valid_from` 和 `valid_to` 时间范围
4. WHEN 生成参数包时，THE Blockcell SHALL 分配唯一的版本号
5. THE Blockcell SHALL 将参数包保存到 EA 可访问的路径（如 `workspace/ea/signal_pack.json`）
6. THE Blockcell SHALL 支持手动触发和定时自动生成参数包

### 需求 8：参数刷新机制

**用户故事：** 作为系统管理员，我需要定期更新策略参数，以便适应市场变化。

#### 验收标准

1. WHEN 配置为日更模式时，THE Blockcell SHALL 每天在指定时间（UTC，如亚洲早盘前）触发参数生成
2. WHEN 检测到重大事件时，THE Blockcell SHALL 支持手动触发参数刷新
3. WHEN 新参数包生成后，THE EA SHALL 在下一次检查周期自动加载新参数
4. WHEN 选择使用哪个参数时，THE EA SHALL 按照需求 1 中定义的参数选择优先级规则执行
5. THE System SHALL 使用 ISO 8601 格式（带 Z 后缀）解析所有时间字段

### 需求 9：回测兼容性

**用户故事：** 作为策略开发者，我需要在 MT4 Strategy Tester 中回测策略，以便验证历史表现。

#### 验收标准

1. THE EA SHALL 支持在 MT4 Strategy Tester 中运行
2. WHEN 在回测模式下运行时，THE EA SHALL 使用历史数据执行策略逻辑
3. WHEN 在回测模式下运行时，THE EA SHALL 正确处理历史 K 线数据
4. WHEN 在回测模式下运行时，THE EA SHALL 生成完整的交易报告
5. WHEN 在回测模式下运行时，THE EA SHALL 支持通过外部参数或内嵌参数注入策略参数
6. WHEN 在回测模式下运行时，THE EA SHALL 使用与实盘一致的决策逻辑
7. THE EA SHALL 在回测中不出现崩溃或异常下单行为

### 需求 10：错误处理与稳定性

**用户故事：** 作为系统运维人员，我需要系统在异常情况下保持稳定，以便避免资金损失。

#### 验收标准

1. WHEN 参数文件缺失时，THE System SHALL 不崩溃并记录错误
2. WHEN 参数文件格式错误时，THE System SHALL 不崩溃并记录错误
3. WHEN 网络连接中断时，THE System SHALL 不崩溃并等待重连
4. WHEN MT4 服务器返回错误时，THE System SHALL 记录错误并重试或放弃
5. WHEN 遇到未预期的市场数据时，THE System SHALL 采用保守策略（如拒绝开仓）
6. THE System SHALL 在所有异常情况下优先保护账户安全

## 数据契约

### 参数包 JSON 结构

```json
{
  "version": "string (必需) - 参数包版本号，格式：YYYYMMDD-HHMM",
  "symbol": "string (必需) - 交易品种，V1 固定为 'EURUSD'",
  "timeframe": "string (必需) - 时间周期，V1 固定为 'H4'",
  "bias": "string (必需) - 交易方向，V1 固定为 'short_only'",
  "valid_from": "string (必需) - 参数生效时间，ISO 8601 格式：YYYY-MM-DDTHH:MM:SSZ",
  "valid_to": "string (必需) - 参数过期时间，ISO 8601 格式：YYYY-MM-DDTHH:MM:SSZ",
  "entry_zone": {
    "min": "number (必需) - 入场区间下限",
    "max": "number (必需) - 入场区间上限"
  },
  "invalid_above": "number (必需) - 失效价格（做空时为上方价格）",
  "tp_levels": "array<number> (必需) - 止盈价格数组，如 [1.1550, 1.1500, 1.1350]",
  "tp_ratios": "array<number> (必需) - 止盈手数比例数组，总和必须为 1.0，如 [0.3, 0.4, 0.3]",
  "ema_fast": "number (必需) - 快速 EMA 周期，默认 50",
  "ema_trend": "number (必需) - 趋势 EMA 周期，默认 200",
  "lookback_period": "number (必需) - 回看周期（K 线数量），用于判断 EMA 回踩",
  "touch_tolerance": "number (必需) - 回踩容差（点数），价格接近 EMA 的范围",
  "pattern": "array<string> (必需) - 允许的形态类型，如 ['bearish_engulfing', 'bearish_pin_bar']",
  "risk": {
    "per_trade": "number (必需) - 单笔风险百分比，如 0.01 表示 1%",
    "daily_max_loss": "number (必需) - 单日最大亏损百分比，如 0.02 表示 2%",
    "consecutive_loss_limit": "number (必需) - 连续亏损笔数限制，如 3"
  },
  "max_spread_points": "number (必需) - 最大允许点差（点数）",
  "max_slippage_points": "number (必需) - 最大允许滑点（点数）",
  "news_blackout": "array<object> (可选) - 新闻禁开仓时间窗口数组",
  "news_blackout[].start": "string (可选) - 窗口开始时间，ISO 8601 格式：YYYY-MM-DDTHH:MM:SSZ",
  "news_blackout[].end": "string (可选) - 窗口结束时间，ISO 8601 格式：YYYY-MM-DDTHH:MM:SSZ",
  "news_blackout[].reason": "string (可选) - 事件原因说明",
  "session_filter": "object (可选) - 交易时段过滤",
  "session_filter.enabled": "boolean (可选) - 是否启用时段过滤",
  "session_filter.allowed_hours_utc": "array<number> (可选) - 允许交易的 UTC 小时数组，如 [8,9,10,11,12,13,14,15,16]",
  "comment": "string (可选) - 备注信息"
}
```

### 字段说明

1. **时间格式**：所有时间字段使用 ISO 8601 格式（UTC 时区），格式为 `YYYY-MM-DDTHH:MM:SSZ`，Z 后缀表示 UTC
2. **tp_levels 与 tp_ratios**：必须长度相同，tp_ratios 总和必须满足 `abs(sum(tp_ratios) - 1.0) <= 1e-6`（允许浮点精度误差）
3. **拆单手数处理**：由于 MT4 的 lot_step 和 min_lot 限制，实际拆单手数总和与计算值误差不超过一个 lot_step，余量分配到最后一单
4. **pattern 支持的值**：`bearish_engulfing`（看跌吞没）、`bearish_pin_bar`（看跌 Pin Bar）
5. **lookback_period**：建议值 5-20，表示检查最近 N 根 K 线
6. **touch_tolerance**：建议值 5-20 点，表示价格在 EMA ± N 点范围内视为回踩
7. **V1 固定值校验**：EA 必须校验 symbol="EURUSD"、timeframe="H4"、bias="short_only"
8. **参数选择优先级**：首先选择当前时间在 valid_from 和 valid_to 之间的参数；若同时存在多个有效参数，则选择 version 字段值更大的参数；若新参数未到 valid_from 且旧参数仍在有效期内，则继续使用旧参数；若无任何有效参数，则进入 Safe_Mode

### 示例参数包

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
