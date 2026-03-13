# Forex Strategy Generator - Cron 定时任务配置

## 概述

本文档说明如何配置 Blockcell Cron 定时任务，使 forex_strategy_generator Skill 每天 UTC 06:00 自动执行。
说明：`cron_expr` 按 UTC 语义解释，系统本地时区可以是 UTC+8（或其他）。

## 配置方法

### 方法 1：通过 CLI 创建（推荐）

```bash
# 创建定时任务
blockcell run msg "创建定时任务：每天UTC 06:00执行forex_strategy_generator技能"
```

### 方法 2：通过 Gateway API 创建

```bash
# 创建 Cron 任务
# 注意：Cron 表达式使用 6 段格式（秒 分 时 日 月 周）
# 如果 gateway 配置了 apiToken，先设置 token（通常来自 ~/.blockcell/config.json5）
API_TOKEN="<your_gateway_token>"

curl -X POST http://localhost:18790/v1/cron \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "forex_param_generator_daily",
    "message": "生成外汇策略参数包",
    "cron_expr": "0 0 6 * * *",
    "skill_name": "forex_strategy_generator",
    "deliver": false
  }'
```

### 方法 3：手动配置 Cron 配置文件

如果 Blockcell 支持配置文件方式，可以编辑 Cron 配置文件：

```yaml
# cron_config.yaml
jobs:
  - id: forex_param_generator_daily
    schedule: "0 0 6 * * *"  # 6段格式：秒 分 时 日 月 周
    action:
      type: skill
      skill_name: forex_strategy_generator
      params: {}
    enabled: true
    description: "每天UTC 06:00生成外汇策略参数包"
```

## Cron 表达式说明

Blockcell 使用 6 段 Cron 表达式格式：

```
0 0 6 * * *
│ │ │ │ │ │
│ │ │ │ │ └─── 星期几 (0-7, 0和7都表示周日)
│ │ │ │ └───── 月份 (1-12)
│ │ │ └─────── 日期 (1-31)
│ │ └───────── 小时 (0-23)
│ └─────────── 分钟 (0-59)
└───────────── 秒 (0-59)
```

**示例：**
- `0 0 6 * * *` - 每天 06:00:00
- `0 0 */4 * * *` - 每4小时执行一次
- `0 0 6,18 * * *` - 每天 06:00 和 18:00
- `0 0 6 * * 1-5` - 周一到周五的 06:00

## 手动触发

除了定时自动执行，也可以手动触发：

### 通过 CLI

```bash
blockcell run msg "生成外汇策略参数"
```

### 通过 Gateway API

```bash
# 如果 gateway 配置了 apiToken，先设置 token
API_TOKEN="<your_gateway_token>"

# 方法 1：获取任务 UUID 后手动触发
# 首先获取任务列表（返回格式：{ "jobs": [...], "count": n }）
job_uuid=$(curl -s -H "Authorization: Bearer ${API_TOKEN}" http://localhost:18790/v1/cron | jq -r '.jobs[] | select(.name=="forex_param_generator_daily") | .id' | head -n1)
echo "$job_uuid"

# 使用获取的 UUID 触发任务
curl -X POST -H "Authorization: Bearer ${API_TOKEN}" "http://localhost:18790/v1/cron/${job_uuid}/run"

# 方法 2：使用配置脚本（推荐）
cd domain_experts/forex/skills/forex_strategy_generator
./setup_cron.sh test

# 注意：Gateway 不提供直接调用 Skill 的 HTTP API
# 需要通过 Cron 任务或 CLI 来触发 Skill
```

### 通过 WebUI

1. 打开 Blockcell WebUI
2. 导航到侧边栏 → 定时任务
3. 找到 `forex_param_generator_daily` 任务
4. 点击"立即执行"按钮

## 验证配置

### 检查 Cron 任务是否创建成功

```bash
# 如果 gateway 配置了 apiToken，先设置 token
API_TOKEN="<your_gateway_token>"

# 列出所有 Cron 任务（返回格式：{ "jobs": [...], "count": n }）
curl -H "Authorization: Bearer ${API_TOKEN}" http://localhost:18790/v1/cron | jq '.'

# 从任务列表中提取特定任务 UUID（jq 必须使用 .jobs[]，不要使用 .[]）
job_uuid=$(curl -s -H "Authorization: Bearer ${API_TOKEN}" http://localhost:18790/v1/cron | jq -r '.jobs[] | select(.name=="forex_param_generator_daily") | .id' | head -n1)
echo "$job_uuid"

# 注意：Gateway 不提供单独查询任务详情的接口
# 不可用接口：GET /v1/cron/<job_uuid>、GET /v1/cron/<job_uuid>/history
# 可用接口：GET /v1/cron（列出所有任务）、POST /v1/cron/:id/run（触发任务）、DELETE /v1/cron/:id（删除任务）
```

### 检查任务执行历史

```bash
# 注意：Gateway 当前不提供任务执行历史查询接口
# 可以通过以下方式监控任务执行：
# 1. 查看 Blockcell 日志
tail -f /var/log/blockcell/blockcell.log

# 2. 检查生成的参数包文件修改时间
ls -la domain_experts/forex/ea/signal_pack.json
```

### 验证参数包生成

```bash
# 检查文件是否生成
ls -la domain_experts/forex/ea/signal_pack.json

# 查看文件内容
cat domain_experts/forex/ea/signal_pack.json

# 验证 JSON 格式
jq . domain_experts/forex/ea/signal_pack.json
```

## 时区注意事项

### 重要提醒

⚠️ **Cron 表达式按 UTC 解释，不是按系统本地时区解释。**

- 系统时区可以是 UTC、UTC+8 或其他
- `0 0 6 * * *` 始终表示每天 `06:00:00Z`（北京时间 `14:00:00`）
- 实测（2026-03-11）：`lastRunAtMs=1773208800755` 对应 `2026-03-11 06:00:00Z`

### 确保 UTC 时区

以下配置是可选项，仅用于统一命令行显示/日志观察，不是 Cron 正确运行的前提。

**Linux/Mac:**
```bash
# 设置环境变量
export TZ=UTC

# 启动 Blockcell
blockcell run
```

**Docker:**
```dockerfile
ENV TZ=UTC
```

**验证时区:**
```bash
# 在 Blockcell 运行的环境中执行
date +%Z  # 可为 UTC 或本地时区（不影响 cron_expr 的 UTC 语义）
```

## 监控与告警

### 监控任务执行状态

建议配置监控脚本，定期检查：

1. Cron 任务是否按时执行
2. 参数包文件是否成功生成
3. 参数包内容是否有效

```bash
#!/bin/bash
# monitor_forex_param_gen.sh

# 检查文件是否存在
if [ ! -f "domain_experts/forex/ea/signal_pack.json" ]; then
    echo "ERROR: signal_pack.json not found!"
    exit 1
fi

# 检查文件修改时间（应该在最近24小时内）
file_age=$(( $(date +%s) - $(stat -c %Y domain_experts/forex/ea/signal_pack.json) ))
if [ $file_age -gt 86400 ]; then
    echo "WARNING: signal_pack.json is older than 24 hours!"
    exit 1
fi

# 检查 JSON 格式
if ! jq . domain_experts/forex/ea/signal_pack.json > /dev/null 2>&1; then
    echo "ERROR: signal_pack.json is not valid JSON!"
    exit 1
fi

echo "OK: signal_pack.json is valid and up-to-date"
exit 0
```

### 配置告警

可以将监控脚本配置为 Cron 任务，定期检查并发送告警：

```bash
# 每小时检查一次（6段格式：秒 分 时 日 月 周）
0 0 * * * * /path/to/monitor_forex_param_gen.sh || mail -s "Forex Param Gen Alert" admin@example.com
```

## 故障排查

### Cron 任务未执行

**可能原因：**
1. Cron 服务未启动
2. 任务被禁用
3. 时区配置错误
4. Blockcell 进程崩溃

**解决方案：**
```bash
# 如果 gateway 配置了 apiToken，先设置 token
API_TOKEN="<your_gateway_token>"

# 检查 Cron 任务列表（返回格式：{ "jobs": [...], "count": n }）
curl -H "Authorization: Bearer ${API_TOKEN}" http://localhost:18790/v1/cron | jq '.'

# 获取特定任务的 UUID
job_uuid=$(curl -s -H "Authorization: Bearer ${API_TOKEN}" http://localhost:18790/v1/cron | jq -r '.jobs[] | select(.name=="forex_param_generator_daily") | .id' | head -n1)
echo "$job_uuid"

# 使用 UUID 手动触发任务
curl -X POST -H "Authorization: Bearer ${API_TOKEN}" "http://localhost:18790/v1/cron/${job_uuid}/run"

# 检查 Blockcell 进程
ps aux | grep blockcell

# 查看 Blockcell 日志
tail -f /var/log/blockcell/blockcell.log
```

### 参数包生成失败

**可能原因：**
1. 文件权限问题
2. 磁盘空间不足
3. Skill 执行错误

**解决方案：**
```bash
# 检查文件权限
ls -la domain_experts/forex/ea/

# 检查磁盘空间
df -h

# 手动触发 Skill 查看错误信息
blockcell run msg "生成外汇策略参数"
```

### AI 技能调用失败

**可能原因：**
1. forex_news/forex_analysis/forex_strategy 技能未实现
2. 网络连接问题
3. API 限流

**解决方案：**
- V1 版本会自动回退到默认参数
- 检查 Skill 日志确认是否使用了默认参数
- 等待 V2 版本实现完整的 AI 分析功能

### `/v1/cron` 返回 401（Unauthorized）

**症状：**
```text
Unauthorized: invalid or missing Bearer token
```

**解决方案：**
1. 优先确认当前运行实例读取的是哪份配置（常见是 `~/.blockcell/config.json5`，不是 `config.json`）
2. 使用 `Authorization: Bearer <token>`，不要用 `X-API-Key`
3. 如需快速验证，可改用 `http://localhost:18790/v1/cron?token=<token>`

## 最佳实践

1. **定期备份参数包**：建议保留历史参数包文件
   ```bash
   # 备份脚本
   cp domain_experts/forex/ea/signal_pack.json \
      domain_experts/forex/ea/backups/signal_pack_$(date +%Y%m%d_%H%M%S).json
   ```

2. **版本控制**：将参数包文件纳入版本控制
   ```bash
   git add domain_experts/forex/ea/signal_pack.json
   git commit -m "Update forex strategy parameters"
   ```

3. **测试环境验证**：先在测试环境验证新参数包
   ```bash
   # 在 Dry Run 模式下测试
   # 在 MT4 EA 中启用 DryRun=true
   ```

4. **监控 EA 行为**：观察 EA 是否正确加载新参数
   ```bash
   # 查看 EA 日志
   tail -f /path/to/mt4/Logs/EA_forex_strategy.log
   ```

## 相关文档

- [Forex Strategy Generator Skill 文档](SKILL.md)
- [MT4 EA 实现文档](../../ea/README.md)
- [Blockcell Cron 系统文档](../../../../docs/en/17_cli_reference.md)

## 支持

如有问题，请参考：
- [故障排查指南](SKILL.md#故障排查)
- [Blockcell 文档](../../../../docs/)
- [GitHub Issues](https://github.com/blockcell-labs/blockcell/issues)
