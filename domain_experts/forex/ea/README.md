# MT4 Forex Strategy Executor

## 概述

MT4 外汇策略执行系统 V1.1 - 实现"AI 决策建议 + EA 确定性执行"的外汇交易自动化方案。

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

### V1.1 版本特性

- **策略类型**：EUR/USD H4 空头策略
- **技术指标**：EMA50（快速）、EMA200（趋势）
- **入场条件**：
  - 趋势过滤：价格低于 EMA200
  - 区间过滤：价格在指定入场区间内
  - 回踩确认：最近 N 根 K 线触及 EMA50
  - 形态触发：看跌吞没或看跌 Pin Bar
  - Signal_K 缓存执行：新 K 线首 tick 评估并缓存，执行阶段仅消费缓存，不重新评估
  - 缓存入场价：使用 Signal_K 收盘价（`Close[1]`）作为 `entry_price`
- **风险管理**：
  - 单笔风险控制（基于账户净值百分比）
  - 日亏损熔断
  - 连续亏损熔断
  - 点差和滑点限制
- **时间过滤**：
  - 新闻事件禁开仓窗口
  - 交易时段过滤
  - UTC 偏移自动探测（失败回退手工 `ServerUTCOffset`）
- **参数管理**：
  - 从 JSON 文件读取策略参数
  - 支持参数热更新
  - 参数版本管理和优先级选择
- **日志追踪**：
  - 完整的决策日志
  - 参数版本追踪
  - 审计追踪
- **图表状态面板**：
  - 显示 EA 版本号、运行状态、参数版本、UTC 偏移模式、Signal 缓存状态
  - 新增 `last_param_load_utc` 与 `source_path_mode(default/custom/embedded)` 可观测字段

## 安装步骤

### Runner-Only 规则（自动化脚本）

- Task14 自动化脚本仅使用 `domain_experts/forex/ea/.mt4_portable_runner`。
- 不再把 `AppData\Roaming\MetaQuotes\Terminal\...` 当作脚本输入源。
- 回测脚本会将仓库源码同步到 runner 并在 runner 内编译后执行。

### 1. 编译 EA

1. 打开 MT4 MetaEditor
2. 打开 `ForexStrategyExecutor.mq4` 文件
3. 点击"编译"按钮（或按 F7）
4. 确认编译成功，生成 `ForexStrategyExecutor.ex4` 文件

也可以使用 portable runner 命令行编译（Windows PowerShell）：

```powershell
$meta="domain_experts/forex/ea/.mt4_portable_runner/metaeditor.exe"
$src="domain_experts/forex/ea/.mt4_portable_runner/MQL4/Experts/ForexStrategyExecutor.mq4"
$log="domain_experts/forex/ea/backtest_artifacts/compile_forex_executor_local.log"
Start-Process -FilePath $meta -ArgumentList @("/portable","/compile:$src","/log:$log") -Wait
```

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
   - **AutoDetectUTCOffset**：是否启用 UTC 偏移自动探测
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
| AutoDetectUTCOffset | bool | true | 自动探测服务器 UTC 偏移，失败时回退到 `ServerUTCOffset` |
| ServerUTCOffset | int | 2 | 服务器时区偏移（小时） |
| BacktestParamJSON | string | 空 | 回测模式下的内嵌参数 JSON；非空时优先于文件参数 |
| BacktestStartDate | datetime | 0 | 回测信号评估起始时间（0=不限制） |
| BacktestEndDate | datetime | 0 | 回测信号评估结束时间（0=不限制） |

说明：
- 回测模式且 `BacktestParamJSON` 非空时，EA 会跳过文件参数热更新，避免覆盖内嵌参数。
- `BacktestStartDate` / `BacktestEndDate` 仅影响开仓信号评估，不影响持仓管理逻辑。
- `AutoDetectUTCOffset=true` 时优先使用自动探测偏移；探测失败时回退到 `ServerUTCOffset`。

## Signal_K 执行语义

1. 新 K 线首 tick 对刚收盘 K 线（`Time[1]`）评估信号。
2. 若信号有效，立即缓存快照（`entry_price/stop_loss/tp_levels/tp_ratios/signal_time`）。
3. 开仓执行阶段只使用该缓存快照，不再重新评估 Signal_K。
4. 参数更新、Safe Mode 切换或执行结束会清理缓存，避免旧信号误用。

## 图表状态面板

EA 在图表右上角显示：

- 版本号（例如 `ForexStrategyExecutor v1.1.1`）
- 当前状态（RUNNING/SAFE_MODE 等）
- 参数版本与状态
- `last_param_load_utc`
- `source_path_mode`
- 当前生效 UTC 偏移及模式（AUTO/MANUAL）
- Signal 缓存状态（pending/none）

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
- EA 自定义日志：`MT4/MQL4/Files/EA_YYYYMMDD.log`（按 Logger 配置输出）

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

### 当前状态（2026-03-13）

- ✅ Task 1-15 已完成（含最终验收）
- ✅ Task 11.5 / 11.6 / 11.7 静态复审缺陷修复已完成
- ✅ Task 13 在线严格验收通过（通过 3 / 失败 0 / 跳过 0）
- ✅ Task 14 回测、实盘一致性验证与文档交付已完成
- ✅ P0/P1 同步稳定化与可观测性增强已落地
- ✅ P2 编译与回归脚本已重跑，产物已更新

### 关键文档

- 参数协议：`docs/PARAMETER_PROTOCOL.md`
- 运行手册：`docs/OPERATION_MANUAL.md`
- 回测报告：`docs/BACKTEST_REPORT.md`
- 缺陷修复：`STATIC_REVIEW_FIXES.md`
- 主循环实现总结：`EA_MAIN_LOOP_IMPLEMENTATION_SUMMARY.md`

## 版本历史

### V1.1.1 (2026-03-13)

- 同步任务脚本 `Status` 明确区分“无权限读取”与“任务不存在”
- 同步服务增加单实例锁，重复实例会立即退出
- 同步任务新增 `Stop` 动作，可一键清理任务/启动器并停止运行中的同步进程
- 新增 `verify_signal_sync.ps1`，可对 source/live/tester 参数包做 hash/version/mtime/新鲜度校验并返回非 0 失败码
- EA 面板新增 `last_param_load_utc`、`source_path_mode`，并在 `SAFE_MODE -> RUNNING` 输出恢复原因日志

### V1.1.0 (2026-03-12)

- 严格实现 Signal_K 缓存执行语义：执行阶段不再重评估
- `entry_price` 改为 Signal_K 收盘价缓存
- UTC 偏移升级为自动探测 + 手工回退
- 图表状态面板新增版本号与缓存/UTC 状态显示

### V1.0.1 (2026-03-11)

- 完成 Task 15 Final Checkpoint 验收收口
- 回测与实盘一致性证据链完整
- 文档更新与链接清理

### V1.0.0 (2026-03-10)

- 完成 EA 核心功能与静态复审修复
- 支持 EUR/USD H4 空头策略全链路执行

## 许可证

本项目为内部使用，未开源。

## 联系方式

如有问题，请联系开发团队。
