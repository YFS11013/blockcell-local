# Forex Strategy Generator Skill

## 文档状态

- 定位：当前使用说明主入口
- 适用版本：V1（默认参数回退 + Cron 触发）
- 详细实现：见 `SKILL.md` 与 `IMPLEMENTATION_SUMMARY.md`

## 📋 目录

- [概述](#概述)
- [快速开始](#快速开始)
- [文件结构](#文件结构)
- [功能特性](#功能特性)
- [使用指南](#使用指南)
- [配置说明](#配置说明)
- [故障排查](#故障排查)
- [开发路线图](#开发路线图)

## 概述

forex_strategy_generator 是一个 Blockcell Skill，用于自动生成 EUR/USD H4 空头策略的参数包。它通过 AI 分析市场并生成完整的策略参数 JSON 文件，供 MT4 EA 使用。

> 说明：当前 V1 版本未接入真实 AI 分析技能，运行时会回退为默认参数生成。

### 系统架构

```
┌─────────────────────────────────────────────────────────┐
│                  Blockcell 侧                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ forex_news   │  │forex_analysis│  │forex_strategy│  │
│  │   Skill      │  │    Skill     │  │    Skill     │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │
│         │                  │                  │          │
│         └──────────────────┼──────────────────┘          │
│                            ▼                             │
│              ┌──────────────────────────┐               │
│              │ forex_strategy_generator │               │
│              │         Skill            │               │
│              └────────────┬─────────────┘               │
│                           │                             │
│                           ▼                             │
│                  signal_pack.json                       │
│                           │                             │
│                  ┌────────┴────────┐                    │
│                  │   Cron 定时任务  │                    │
│                  │ (每天UTC 06:00) │                    │
│                  └─────────────────┘                    │
└─────────────────────────────────────────────────────────┘
                            │ (文件系统)
                            ▼
┌─────────────────────────────────────────────────────────┐
│                    MT4 EA 侧                             │
│              ┌──────────────────┐                       │
│              │ Parameter Loader │                       │
│              └────────┬─────────┘                       │
│                       │                                 │
│                       ▼                                 │
│              ┌──────────────────┐                       │
│              │  Strategy Engine │                       │
│              └──────────────────┘                       │
└─────────────────────────────────────────────────────────┘
```

## 快速开始

### 1. 手动执行一次

```bash
# 进入 Skill 目录
cd domain_experts/forex/skills/forex_strategy_generator

# 执行测试
./setup_cron.sh test

# 查看生成的参数包
cat ../../ea/signal_pack.json
```

### 2. 配置定时任务

```bash
# 配置每天 UTC 06:00 自动执行
./setup_cron.sh daily

# 验证配置
curl -H "Authorization: Bearer <token>" http://localhost:18790/v1/cron
```

### 3. 在 MT4 EA 中使用

1. 确保 MT4 EA 的 `ParamFilePath` 参数指向正确的路径
2. 启动 EA，EA 将自动读取参数包
3. 建议先在 Dry Run 模式下测试

## 文件结构

```
forex_strategy_generator/
├── README.md              # 本文件
├── SKILL.md              # Skill 详细文档
├── SKILL.rhai            # Skill 实现代码
├── meta.yaml             # Skill 元数据配置
├── CRON_SETUP.md         # Cron 配置详细指南
├── cron_example.yaml     # Cron 配置示例
└── setup_cron.sh         # Cron 快速配置脚本
```

## 功能特性

### ✅ 已实现

- [x] 生成符合 MT4 EA 要求的完整参数包
- [x] 自动生成唯一版本号（格式：YYYYMMDD-HHMM）
- [x] 使用 UTC 时间确保时区一致性
- [x] 输出 ISO 8601 格式的时间字符串
- [x] 保存到指定路径供 EA 读取
- [x] 支持手动触发和定时触发
- [x] AI 技能调用框架（forex_news、forex_analysis、forex_strategy）
- [x] 自动回退到默认参数（当 AI 技能不可用时）

### ⚠️ V1 限制

- 未集成真实的 AI 分析（forex_news/forex_analysis/forex_strategy 技能尚未实现）
- 不支持通过 `call_skill` 直接跨 Skill 调用
- 使用固定的默认参数值
- news_blackout 默认为空数组
- 时间计算仍为纯 Rhai 实现（已在 2026-03-10 修复闰年与月份天数问题）

### 🚀 计划中（V2）

- [ ] 集成 forex_news Skill 获取新闻事件
- [ ] 集成 forex_analysis Skill 进行技术分析
- [ ] 集成 forex_strategy Skill 生成策略建议
- [ ] 动态计算 entry_zone 和 tp_levels
- [ ] 自动识别重大新闻并配置 news_blackout
- [ ] 使用精确的时间计算库
- [ ] 支持多币对和多时间周期

## 使用指南

### 手动触发

**方法 1：使用配置脚本**
```bash
./setup_cron.sh test
```

**方法 2：通过 CLI**
```bash
blockcell run msg "生成外汇策略参数"
```

**方法 3：通过 Gateway API 触发已存在 Cron 任务**
```bash
# 如果 gateway 配置了 apiToken，先设置 token
API_TOKEN="<your_gateway_token>"

# 1) 获取任务 UUID（示例：daily 任务）
job_uuid=$(curl -s -H "Authorization: Bearer ${API_TOKEN}" http://localhost:18790/v1/cron | jq -r '.jobs[] | select(.name=="forex_param_generator_daily") | .id' | head -n1)

# 2) 手动触发任务
curl -X POST -H "Authorization: Bearer ${API_TOKEN}" "http://localhost:18790/v1/cron/${job_uuid}/run"

# 注意：Gateway 不提供直接调用 Skill 的 HTTP API
# 需要通过 CLI 或创建一次性 Cron 任务来手动触发
```

### 定时触发

**快速配置：**
```bash
./setup_cron.sh daily
```

**详细配置：**
参考 [CRON_SETUP.md](CRON_SETUP.md)

### 验证结果

```bash
# 检查文件是否生成
ls -la ../../ea/signal_pack.json

# 查看文件内容
cat ../../ea/signal_pack.json

# 验证 JSON 格式
jq . ../../ea/signal_pack.json
```

### 集成测试（Task 13）

Linux/macOS（原脚本）：

```bash
RUN_LIVE_TESTS=1 STRICT_MODE=1 bash domain_experts/forex/skills/forex_strategy_generator/integration_test.sh
```

Windows PowerShell（等价脚本）：

```powershell
$env:RUN_LIVE_TESTS='1'
$env:STRICT_MODE='1'
pwsh -NoProfile -File "domain_experts/forex/skills/forex_strategy_generator/integration_test.ps1"
```

## 配置说明

### 环境要求

1. **时区配置**：系统时区可以是 UTC+8（或其他），但 `cron_expr` 与参数包时间字段按 UTC 解释
   ```bash
   # 可选：仅在你希望命令行时间显示为 UTC 时设置
   export TZ=UTC
   ```
   - 例如 `0 0 6 * * *` 表示每天 `06:00Z`（北京时间 `14:00`）
   - 实测（2026-03-11）：`lastRunAtMs=1773208800755` 对应 `2026-03-11 06:00:00Z`

2. **文件权限**：确保有写入权限
   ```bash
   chmod 755 domain_experts/forex/ea/
   ```

3. **依赖工具**：
   - curl（用于 API 调用）
   - jq（用于 JSON 验证，可选）

### 参数包配置

生成的参数包包含以下字段：

| 字段 | 类型 | 说明 | V1 默认值 |
|------|------|------|-----------|
| version | string | 版本号 | YYYYMMDD-HHMM |
| symbol | string | 交易品种 | EURUSD |
| timeframe | string | 时间周期 | H4 |
| bias | string | 交易方向 | short_only |
| valid_from | string | 生效时间 | 当前 UTC 时间 |
| valid_to | string | 过期时间 | 24小时后 |
| entry_zone | object | 入场区间 | {min: 1.1650, max: 1.1700} |
| invalid_above | number | 失效价格 | 1.1720 |
| tp_levels | array | 止盈价格 | [1.1550, 1.1500, 1.1350] |
| tp_ratios | array | 止盈比例 | [0.3, 0.4, 0.3] |
| ema_fast | number | 快速EMA | 50 |
| ema_trend | number | 趋势EMA | 200 |
| lookback_period | number | 回看周期 | 10 |
| touch_tolerance | number | 回踩容差 | 10 |
| pattern | array | 形态类型 | ["bearish_engulfing", "bearish_pin_bar"] |
| risk.per_trade | number | 单笔风险 | 0.01 (1%) |
| risk.daily_max_loss | number | 日最大亏损 | 0.02 (2%) |
| risk.consecutive_loss_limit | number | 连续亏损限制 | 3 |
| max_spread_points | number | 最大点差 | 20 |
| max_slippage_points | number | 最大滑点 | 10 |
| news_blackout | array | 新闻窗口 | [] |
| session_filter | object | 时段过滤 | {enabled: true, allowed_hours_utc: [8-16]} |
| comment | string | 备注 | 自动生成 |

### Cron 配置

**推荐配置：**
- 调度时间：每天 UTC 06:00（亚洲早盘前）
- Cron 表达式：`0 0 6 * * *`（6 段格式：秒 分 时 日 月 周）
- 重试次数：3 次
- 重试间隔：5 分钟

**其他选项：**
- 每天两次：`0 0 6,18 * * *`（06:00 和 18:00）
- 工作日：`0 0 6 * * 1-5`（周一到周五）
- 每4小时：`0 0 */4 * * *`

详细配置参考 [CRON_SETUP.md](CRON_SETUP.md)

## 故障排查

### 问题 1：文件保存失败

**症状：**
```
ERROR: 无法保存参数包文件
```

**解决方案：**
1. 检查文件路径是否存在
2. 检查文件权限
3. 检查磁盘空间

```bash
# 创建目录
mkdir -p domain_experts/forex/ea

# 设置权限
chmod 755 domain_experts/forex/ea

# 检查磁盘空间
df -h
```

### 问题 2：时间格式错误

**症状：**
```
生成的时间格式不正确
```

**解决方案：**
1. 确认你使用 UTC 语义写 `cron_expr`（不是本地时间）
2. 用运行记录核对 `lastRunAtMs/nextRunAtMs` 与 `signal_pack.version`
3. 仅当你需要统一命令行显示时，再设置 `TZ=UTC`

```bash
# 检查时区
date +%Z

# 检查 Cron 任务时间（UTC 毫秒）
curl -H "Authorization: Bearer <token>" http://localhost:18790/v1/cron | jq '.jobs[] | {name, schedule, state}'

# 检查参数包版本与时间
cat ../../ea/signal_pack.json | jq '{version, valid_from}'
```

### 问题 3：Cron 任务未执行

**症状：**
```
参数包文件未更新
```

**解决方案：**
1. 检查 Cron 任务状态
2. 查看 Blockcell 日志
3. 手动触发测试

```bash
# 检查任务列表（注意：返回对象，不是数组）
curl -H "Authorization: Bearer <token>" http://localhost:18790/v1/cron | jq '.'

# 获取特定任务的 UUID（jq 必须使用 .jobs[]，不要使用 .[]）
job_uuid=$(curl -s -H "Authorization: Bearer <token>" http://localhost:18790/v1/cron | jq -r '.jobs[] | select(.name=="forex_param_generator_daily") | .id' | head -n1)
echo "$job_uuid"

# 使用 UUID 手动触发任务
curl -X POST -H "Authorization: Bearer <token>" "http://localhost:18790/v1/cron/${job_uuid}/run"

# 注意：Gateway 当前未实现以下接口
# - GET /v1/cron/<job_uuid>
# - GET /v1/cron/<job_uuid>/history

# 查看日志
tail -f /var/log/blockcell/blockcell.log
```

### 问题 4：AI 技能调用失败

**症状：**
```
⚠️ AI分析技能不可用，使用默认参数生成参数包
```

**说明：**
这是 V1 版本的预期行为。forex_news、forex_analysis、forex_strategy 技能尚未实现，系统会自动回退到默认参数。

**解决方案：**
- V1 版本：接受默认参数，手动调整参数包
- V2 版本：等待 AI 技能实现

### 问题 5：`/v1/cron` 返回 401（Unauthorized）

**症状：**
```text
Unauthorized: invalid or missing Bearer token
```

**解决方案：**
1. 优先检查当前运行实例读取的是哪份配置（常见是 `~/.blockcell/config.json5`，不是 `config.json`）
2. 使用 `Authorization: Bearer <token>`（`X-API-Key` 对 Gateway API 不生效）
3. 如需快速验证，也可用 `?token=<token>` 方式调用

更多故障排查信息，请参考：
- [SKILL.md - 故障排查](SKILL.md#故障排查)
- [CRON_SETUP.md - 故障排查](CRON_SETUP.md#故障排查)

## 开发路线图

### V1.0（当前版本）✅

- [x] 基础 Skill 框架
- [x] 参数包生成逻辑
- [x] UTC 时间处理
- [x] ISO 8601 格式化
- [x] 文件保存功能
- [x] Cron 配置支持
- [x] AI 技能调用框架
- [x] 默认参数回退

### V1.1（计划中）

- [ ] 添加参数验证逻辑
- [ ] 支持参数包历史版本管理
- [ ] 添加参数包备份功能
- [ ] 改进错误处理和日志

### V2.0（未来）

- [ ] 实现 forex_news Skill
- [ ] 实现 forex_analysis Skill
- [ ] 实现 forex_strategy Skill
- [ ] 动态参数计算
- [ ] 自动新闻窗口识别
- [ ] 支持多币对
- [ ] 支持多时间周期
- [ ] Web UI 配置界面

## 相关文档

- [SKILL.md](SKILL.md) - Skill 详细文档
- [CRON_SETUP.md](CRON_SETUP.md) - Cron 配置指南
- [MT4 EA 文档](../../ea/README.md) - MT4 EA 实现文档
- [需求文档](../../../../.kiro/specs/mt4-forex-strategy-executor/requirements.md)
- [设计文档](../../../../.kiro/specs/mt4-forex-strategy-executor/design.md)
- [任务列表](../../../../.kiro/specs/mt4-forex-strategy-executor/tasks.md)

## 贡献

欢迎贡献代码和建议！请参考：
- [仓库协作规则](../../../../AGENTS.md)

## 许可证

本 Skill 是 Blockcell MT4 外汇策略执行系统的一部分。

## 支持

如有问题，请：
1. 查看 [故障排查](#故障排查) 部分
2. 查看 [相关文档](#相关文档)
3. 提交 [GitHub Issue](https://github.com/blockcell-labs/blockcell/issues)

---

**最后更新：** 2026-03-12  
**版本：** V1.0  
**状态：** ✅ 已完成
