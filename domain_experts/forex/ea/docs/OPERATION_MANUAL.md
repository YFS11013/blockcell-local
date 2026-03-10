# 运行手册

## 目录

1. [系统概述](#系统概述)
2. [部署步骤](#部署步骤)
3. [参数路径配置](#参数路径配置)
4. [EA 输入参数说明](#ea-输入参数说明)
5. [回测配置](#回测配置)
6. [故障处理指南](#故障处理指南)
7. [监控与维护](#监控与维护)

---

## 系统概述

ForexStrategyExecutor 是一个 MT4 自动交易程序（EA），用于执行 EUR/USD H4 空头策略。系统由两部分组成：

- **Blockcell 参数生成器**：通过 AI 分析生成策略参数包（JSON 格式）
- **MT4 EA**：读取参数包并按规则执行交易

### 核心功能

- 趋势过滤（EMA200）
- 价格区间过滤
- EMA 回踩检测
- 形态识别（看跌吞没、看跌 Pin Bar）
- 风险管理（单笔风险、日亏损熔断、连续亏损熔断）
- 时间过滤（新闻窗口、交易时段）
- 完整日志记录

---

## 部署步骤

### 步骤 1：编译 EA

1. 打开 MetaEditor
2. 打开 `ForexStrategyExecutor.mq4` 文件
3. 点击「编译」按钮（或按 F7）
4. 确保编译成功，无错误和警告

### 步骤 2：安装 EA 文件

将编译生成的 `.ex4` 文件复制到 MT4 目录：

```
MT4/MQL4/Experts/ForexStrategyExecutor.ex4
```

### 步骤 3：准备参数文件

1. 创建参数目录：`MT4/MQL4/Files/`
2. 确保 Blockcell 有权限写入该目录
3. 参数文件命名：`signal_pack.json`

### 步骤 4：配置 EA 输入参数

1. 在 MT4 导航器中找到「Expert Advisors」
2. 拖拽 `ForexStrategyExecutor` 到 EURUSD H4 图表
3. 在弹出的设置窗口中配置输入参数
4. 点击「OK」启用 EA

### 步骤 5：验证运行状态

1. 检查 EA 图标（右上角）
   - 笑脸 = 运行正常
   - 哭脸 = 错误
   - 灰色 = 已禁用

2. 查看「Experts」日志标签
3. 确认参数加载成功

---

## 参数路径配置

### 默认路径

如果 `ParamFilePath` 输入参数为空，EA 使用以下默认路径：

```
<终端数据目录>\MQL4\Files\signal_pack.json
```

### 自定义路径

在 EA 输入参数中设置 `ParamFilePath`：

| 操作系统 | 示例路径 |
|----------|----------|
| Windows | `C:\Trading\ea\signal_pack.json` |
| Windows | `C:\\Users\\Trader\\Documents\\ea\\signal_pack.json` |

### 路径配置建议

1. **绝对路径**：使用完整路径，避免相对路径问题
2. **权限验证**：确保 MT4 有权限读取该路径
3. **网络共享**：如使用网络路径，确保网络稳定

---

## EA 输入参数说明

### 基本参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `ParamFilePath` | string | 空 | 参数包文件路径，留空使用默认路径 |
| `DryRun` | bool | false | Dry Run 模式（不下真实订单） |
| `LogLevel` | string | "INFO" | 日志级别：DEBUG, INFO, WARN, ERROR |
| `ParamCheckInterval` | int | 300 | 参数检查间隔（秒） |
| `ServerUTCOffset` | int | 2 | 服务器时区偏移（小时） |

### 回测专用参数

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `BacktestParamJSON` | string | 空 | 回测模式：内嵌参数 JSON（非空时优先，且跳过文件热更新） |
| `BacktestStartDate` | datetime | 0 | 回测开仓评估起始时间（0=不限制） |
| `BacktestEndDate` | datetime | 0 | 回测开仓评估结束时间（0=不限制） |

### 日志级别说明

| 级别 | 说明 | 使用场景 |
|------|------|----------|
| DEBUG | 详细调试信息 | 开发测试 |
| INFO | 一般信息 | 正常运行 |
| WARN | 警告信息 | 监控异常 |
| ERROR | 错误信息 | 问题排查 |

---

## 回测配置

### 方式一：外部参数文件

1. 在 Strategy Tester 中选择 EA
2. 设置交易品种：EURUSD
3. 设置时间周期：H4
4. 设置日期范围
5. 勾选「Use date」
6. 设置开始和结束日期
7. EA 会从 `ParamFilePath`（或默认路径 `<终端数据目录>\MQL4\Files\signal_pack.json`）加载参数

### 方式二：内嵌参数（推荐）

1. 在 EA 输入参数中设置 `BacktestParamJSON`
2. 将参数包 JSON 压缩为单行
3. 在 Strategy Tester 中设置回测日期范围（Use date）
4. 可选：设置 `BacktestStartDate` / `BacktestEndDate` 进一步限制开仓评估窗口
5. 开始回测

> 注意：当 `BacktestParamJSON` 非空时，EA 在回测期间不会从文件热更新参数，以避免内嵌参数被覆盖。

**内嵌参数示例**：

```
{"version":"20250309-0800","symbol":"EURUSD","timeframe":"H4","bias":"short_only","valid_from":"2025-03-09T08:00:00Z","valid_to":"2025-03-10T08:00:00Z","entry_zone":{"min":1.1650,"max":1.1700},"invalid_above":1.1720,"tp_levels":[1.1550,1.1500,1.1350],"tp_ratios":[0.3,0.4,0.3],"ema_fast":50,"ema_trend":200,"lookback_period":10,"touch_tolerance":10,"pattern":["bearish_engulfing","bearish_pin_bar"],"risk":{"per_trade":0.01,"daily_max_loss":0.02,"consecutive_loss_limit":3},"max_spread_points":20,"max_slippage_points":10}
```

### 回测设置建议

| 设置项 | 推荐值 |
|--------|--------|
| 品种 | EURUSD |
| 时间周期 | H4 |
| 回测时长 | 6-12 个月 |
| 复利模式 | 关闭 |
| 交易延迟 | 0 |

### 批量生成历史参数包（按日期）

可使用脚本一次性生成最近 6-12 个月的历史参数包（按天）：

```powershell
python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --months 12 --write-index
```

指定起止日期：

```powershell
python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --start-date 2025-01-01 --end-date 2025-12-31 --write-index
```

默认输出目录：

`domain_experts/forex/ea/history/signal_packs/`

建议先使用 `--dry-run` 预览生成数量，再正式写文件。

---

## 故障处理指南

### 常见问题

#### 问题 1：EA 不执行交易

**可能原因**：
- EA 未启用（检查右上角图标）
- 参数包加载失败
- 进入 Safe Mode
- 熔断触发

**排查步骤**：
1. 检查 Experts 日志
2. 查看参数状态
3. 检查熔断状态

**解决方案**：
```
查看日志中的状态信息：
- "参数包加载成功" = 参数正常
- "进入 Safe Mode" = 参数问题
- "熔断触发" = 风控触发
```

#### 问题 2：参数包加载失败

**可能原因**：
- 文件路径错误
- JSON 格式错误
- 缺少必需字段
- 固定值不匹配

**排查步骤**：
1. 确认文件路径正确
2. 验证 JSON 格式
3. 检查必需字段
4. 验证固定值

**解决方案**：
```bash
# 使用 JSON 验证工具验证参数文件
# 确保包含所有必需字段
# 确保 symbol="EURUSD", timeframe="H4", bias="short_only"
```

#### 问题 3：日志中出现 "参数已过期"

**可能原因**：
- `valid_from` 晚于当前时间
- `valid_to` 早于当前时间

**解决方案**：
1. 更新参数包
2. 检查系统时间
3. 验证 UTC 时间转换

#### 问题 4：回测无交易

**可能原因**：
- 历史数据不足
- 参数条件未满足
- 回测日期范围错误

**解决方案**：
1. 确认历史数据完整
2. 检查参数值是否合理
3. 扩大回测日期范围

#### 问题 5：EA 崩溃或无响应

**可能原因**：
- 内存不足
- 循环引用
- MT4 客户端问题

**解决方案**：
1. 重启 MT4
2. 减少历史数据缓存
3. 检查系统资源

### 错误代码说明

| 错误码 | 说明 | 处理方式 |
|--------|------|----------|
| INIT_FAILED | 初始化失败 | 检查参数配置 |
| INIT_PARAMETERS_INCORRECT | 参数错误 | 检查输入参数 |
| REASON_INITFAILED | 初始化失败 | 查看日志 |

### Safe Mode 恢复

进入 Safe Mode 后，EA 会：

1. 停止开新仓
2. 继续管理已有持仓
3. 每根 K 线尝试恢复

**手动恢复**：
1. 更新有效的参数包
2. 重启 EA
3. 或等待自动恢复

---

## 监控与维护

### 日志位置

| 日志类型 | 位置 |
|----------|------|
| MT4 日志 | `MT4/MQL4/Logs/YYYYMMDD.log` |
| EA 日志 | `MT4/MQL4/Files/EA_YYYYMMDD.log` |

### 监控指标

| 指标 | 正常范围 | 告警阈值 |
|------|----------|----------|
| 参数更新 | 每 24 小时 | 超过 48 小时 |
| 开仓频率 | 视策略而定 | 连续 7 天无开仓 |
| 盈亏 | - | 单日亏损 > 2% |
| 熔断 | - | 连续触发 |

### 定期维护

1. **每日**：检查日志，确认 EA 运行正常
2. **每周**：审查交易记录，分析策略表现
3. **每月**：更新历史数据，评估策略调整

### 备份与恢复

**参数包备份**：
- 自动保留最近 30 天的参数包
- 备份位置：`MT4/MQL4/Files/signal_pack_backup.json`

**EA 状态恢复**：
- 使用 GlobalVariable 持久化状态
- EA 重启后自动恢复

---

## 联系与支持

如遇到本文档未涵盖的问题，请：

1. 查看详细日志
2. 检查参数配置
3. 收集错误信息
4. 联系技术支持
