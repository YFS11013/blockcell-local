# MT4 Forex Strategy Executor

## 概述

MT4 外汇策略执行系统 V1.0 - 实现"AI 决策建议 + EA 确定性执行"的外汇交易自动化方案。

## 文件结构

```
domain_experts/forex/ea/
├── ForexStrategyExecutor.mq4    # EA 主文件
├── include/                      # 模块头文件目录
│   ├── ParameterLoader.mqh      # 参数加载器
│   ├── TimeUtils.mqh            # 时间处理工具
│   ├── StrategyEngine.mqh       # 策略引擎
│   ├── RiskManager.mqh          # 风险管理器
│   ├── OrderExecutor.mqh        # 订单执行器
│   ├── PositionManager.mqh      # 持仓管理器
│   ├── Logger.mqh               # 日志记录器
│   └── TimeFilter.mqh           # 时间过滤器
└── README.md                     # 本文件
```

## 功能特性

### V1.0 版本特性

- **策略类型**：EUR/USD H4 空头策略
- **技术指标**：EMA50（快速）、EMA200（趋势）
- **入场条件**：
  - 趋势过滤：价格低于 EMA200
  - 区间过滤：价格在指定入场区间内
  - 回踩确认：最近 N 根 K 线触及 EMA50
  - 形态触发：看跌吞没或看跌 Pin Bar
- **风险管理**：
  - 单笔风险控制（基于账户净值百分比）
  - 日亏损熔断
  - 连续亏损熔断
  - 点差和滑点限制
- **时间过滤**：
  - 新闻事件禁开仓窗口
  - 交易时段过滤
- **参数管理**：
  - 从 JSON 文件读取策略参数
  - 支持参数热更新
  - 参数版本管理和优先级选择
- **日志追踪**：
  - 完整的决策日志
  - 参数版本追踪
  - 审计追踪

## 安装步骤

### 1. 编译 EA

1. 打开 MT4 MetaEditor
2. 打开 `ForexStrategyExecutor.mq4` 文件
3. 点击"编译"按钮（或按 F7）
4. 确认编译成功，生成 `ForexStrategyExecutor.ex4` 文件

### 2. 安装 EA

1. 将 `ForexStrategyExecutor.ex4` 复制到 MT4 安装目录：
   ```
   MT4/MQL4/Experts/ForexStrategyExecutor.ex4
   ```
2. 重启 MT4 或刷新导航器窗口

### 3. 配置参数包路径

确保参数包文件路径正确配置：
- 默认路径：`<终端数据目录>\MQL4\Files\signal_pack.json`
- 可在 EA 输入参数中修改

## 使用方法

### 1. 准备参数包

参数包由 Blockcell 生成，格式为 JSON。示例：

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
  "max_slippage_points": 10
}
```

### 2. 加载 EA

1. 在 MT4 中打开 EUR/USD H4 图表
2. 从导航器窗口拖拽 `ForexStrategyExecutor` 到图表
3. 配置输入参数：
   - **ParamFilePath**：参数包文件路径
   - **DryRun**：是否启用 Dry Run 模式（测试用）
   - **LogLevel**：日志级别（DEBUG/INFO/WARN/ERROR）
   - **ParamCheckInterval**：参数检查间隔（秒）
   - **ServerUTCOffset**：服务器时区偏移（小时）
4. 点击"确定"启动 EA

### 3. 启用自动交易

确保 MT4 工具栏上的"自动交易"按钮已启用（绿色）。

## 输入参数说明

| 参数名 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| ParamFilePath | string | `<终端数据目录>\MQL4\Files\signal_pack.json` | 参数包文件路径 |
| DryRun | bool | false | Dry Run 模式（不下真实订单） |
| LogLevel | string | INFO | 日志级别：DEBUG, INFO, WARN, ERROR |
| ParamCheckInterval | int | 300 | 参数检查间隔（秒） |
| ServerUTCOffset | int | 2 | 服务器时区偏移（小时） |
| BacktestParamJSON | string | 空 | 回测模式下的内嵌参数 JSON；非空时优先于文件参数 |
| BacktestStartDate | datetime | 0 | 回测信号评估起始时间（0=不限制） |
| BacktestEndDate | datetime | 0 | 回测信号评估结束时间（0=不限制） |

说明：
- 回测模式且 `BacktestParamJSON` 非空时，EA 会跳过文件参数热更新，避免覆盖内嵌参数。
- `BacktestStartDate` / `BacktestEndDate` 仅影响开仓信号评估，不影响持仓管理逻辑。

## EA 状态

EA 有以下几种状态：

1. **INITIALIZING**：初始化中
2. **LOADING_PARAMS**：加载参数中
3. **RUNNING**：正常运行（可以开新仓和管理持仓）
4. **SAFE_MODE**：安全模式（只管理持仓，不开新仓）

### Safe Mode 触发条件

- 参数包加载失败
- 参数包无效或过期
- 触发风控熔断

### Safe Mode 恢复条件

- 参数包恢复有效
- 熔断期结束

## 日志说明

### 日志位置

- MT4 日志窗口：实时查看
- MT4 日志文件：`MT4/MQL4/Logs/YYYYMMDD.log`
- EA 自定义日志：`MT4/MQL4/Files/EA_YYYYMMDD.log`（待实现）

### 日志级别

- **DEBUG**：详细的调试信息
- **INFO**：一般信息（参数加载、信号评估、订单执行）
- **WARN**：警告信息（滑点超限、点差过大）
- **ERROR**：错误信息（参数加载失败、订单失败）

## 故障排查

### 问题：EA 进入 Safe Mode

**可能原因**：
1. 参数包文件不存在或路径错误
2. 参数包格式错误
3. 参数包已过期
4. 触发风控熔断

**解决方法**：
1. 检查参数包文件路径是否正确
2. 检查参数包 JSON 格式是否正确
3. 检查参数包的 valid_from 和 valid_to 时间
4. 等待熔断期结束或重置风控状态

### 问题：EA 不开仓

**可能原因**：
1. 入场条件不满足
2. 在新闻禁开仓窗口内
3. 不在允许的交易时段
4. 点差过大
5. 处于 Safe Mode

**解决方法**：
1. 查看日志，确认拒单原因
2. 检查参数包的 news_blackout 配置
3. 检查参数包的 session_filter 配置
4. 等待点差降低
5. 检查 EA 状态，确认不在 Safe Mode

### 问题：订单执行失败

**可能原因**：
1. 网络连接问题
2. 服务器繁忙
3. 资金不足
4. 止损/止盈设置无效

**解决方法**：
1. 检查网络连接
2. 等待服务器恢复
3. 检查账户余额
4. 检查参数包的止损/止盈设置

## 开发状态

### 已完成

- [x] Task 1: MT4 EA 基础架构
  - EA 主文件框架
  - OnInit、OnDeinit、OnTick 实现
  - 输入参数定义
  - 状态机框架
  - 基础日志功能

### 待实现

- [ ] Task 2: 时间处理模块
- [ ] Task 3: 参数加载器模块
- [ ] Task 4: 策略引擎模块
- [ ] Task 5: 风险管理器模块
- [ ] Task 6: 订单执行器模块
- [ ] Task 7: 时间过滤器模块
- [ ] Task 8: 日志记录器模块
- [ ] Task 9: 持仓管理器模块
- [ ] Task 10: EA 主循环集成
- [ ] Task 11: Checkpoint - EA 核心功能完成

## 版本历史

### V1.0.0 (2025-03-09)

- 初始版本
- 实现基础架构
- 支持 EUR/USD H4 空头策略

## 许可证

本项目为内部使用，未开源。

## 联系方式

如有问题，请联系开发团队。
