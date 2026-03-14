# mt4_features Skill

## 概述

通过 P0 文件协议 + `FeatureWorker.mq4` 计算多品种技术特征，为 blockcell agent 提供离线特征包。

**定位**：批量特征计算，不依赖实时 ZMQ 连接，使用 MT4 Strategy Tester 离线运行。

## 架构

```
blockcell agent
    ↓ ctx.user_input = "EURUSD,USDJPY RSI_H4,ATR_H4,MARKET_STATE"
SKILL.rhai
    ↓ 写 job.json（job_type=feature）
    ↓ exec: run_feature.ps1 -JobFile job.json
run_feature.ps1
    ↓ 编译 FeatureWorker.mq4
    ↓ 启动 MT4 Strategy Tester
FeatureWorker.mq4
    ↓ 读 job.json，计算各品种特征
    ↓ 写 features_{job_id}.json + result_{job_id}.json
run_feature.ps1
    ↓ 读取产物，写 result.json + features.json 到 job 目录
blockcell agent ← features.json
```

## 前置条件

1. MT4 portable runner 已配置（`ea/.mt4_portable_runner/terminal.exe` 存在）
2. runner 内有 EURUSD H4 历史数据（`.hst` 文件）
3. `FeatureWorker.mq4` 在 `ea/` 目录（首次运行自动编译）

## 输入格式

### 简写格式（推荐）

```
# 品种列表（逗号分隔）+ 空格 + 特征列表（逗号分隔）
EURUSD,USDJPY,GBPUSD RSI_H4,ATR_H4,MARKET_STATE

# 只传品种，使用默认特征集（全套）
EURUSD,USDJPY

# 单品种
EURUSD
```

### JSON 格式（完整控制）

```json
{
  "job_id": "feature_20260314_120000_ab12",
  "job_type": "feature",
  "created_at": "2026-03-14T12:00:00Z",
  "symbols": ["EURUSD", "USDJPY", "GBPUSD"],
  "features": ["RSI_H4", "ATR_H4", "MA_TREND", "BB_POS", "STOCH_H4", "MARKET_STATE"],
  "as_of_date": "2026-03-14",
  "timeout_seconds": 120
}
```

## 支持的特征

| 特征名 | 说明 | 计算方式 |
|--------|------|---------|
| `RSI_H4` | H4 RSI(14) | iRSI，shift=1 |
| `ATR_H4` | H4 ATR(14) | iATR，shift=1 |
| `RSI_D1` | D1 RSI(14) | iRSI，shift=1 |
| `ATR_D1` | D1 ATR(14) | iATR，shift=1 |
| `MA_TREND` | H4 MA 趋势 | EMA10/50/200 排列 → bullish/bearish/neutral |
| `MA_H1` | H1 MA 趋势 | EMA20/60 排列 → bullish/bearish/neutral |
| `BB_POS` | H4 布林带位置 | (close-lower)/(upper-lower)，0~1 |
| `STOCH_H4` | H4 随机指标 %K | iStochastic(5,3,3) |
| `MARKET_STATE` | 综合市场状态 | trending_up/trending_down/ranging/breakout |

## 输出

### features.json

```json
{
  "job_id": "feature_20260314_120000_ab12",
  "as_of_date": "2026-03-14",
  "computed_at": "2026-03-14 12:05:33",
  "features": {
    "EURUSD": {
      "RSI_H4": 58.32,
      "ATR_H4": 0.000820,
      "MA_TREND": "bullish",
      "BB_POS": 0.7241,
      "STOCH_H4": 67.40,
      "MARKET_STATE": "trending_up"
    },
    "USDJPY": {
      "RSI_H4": 44.17,
      "ATR_H4": 0.412000,
      "MA_TREND": "bearish",
      "BB_POS": 0.3102,
      "STOCH_H4": 28.90,
      "MARKET_STATE": "trending_down"
    }
  }
}
```

### result.json（P0 协议标准格式）

```json
{
  "job_id": "feature_20260314_120000_ab12",
  "job_type": "feature",
  "status": "success",
  "finished_at": "2026-03-14T12:05:33Z",
  "duration_seconds": 45.2,
  "data": {
    "symbols_processed": 2,
    "features_file": "domain_experts/forex/ea/jobs/feature_.../features.json"
  }
}
```

## 使用示例

### blockcell CLI

```bash
# 计算 3 个品种的全套特征
blockcell run msg "EURUSD,USDJPY,GBPUSD"

# 只计算 RSI 和市场状态
blockcell run msg "EURUSD,USDJPY RSI_H4,MARKET_STATE"

# 完整 JSON 控制
blockcell run msg '{"job_type":"feature","symbols":["EURUSD"],"features":["RSI_H4","ATR_H4"]}'
```

### 直接调用脚本

```powershell
# 先创建 job.json
$job = @{
    job_id = "feature_test_001"
    job_type = "feature"
    created_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    symbols = @("EURUSD","USDJPY")
    features = @("RSI_H4","ATR_H4","MARKET_STATE")
    as_of_date = (Get-Date -Format "yyyy-MM-dd")
    timeout_seconds = 120
} | ConvertTo-Json
$job | Set-Content ".\jobs\feature_test_001\job.json" -Encoding UTF8

# 运行
.\run_feature.ps1 -JobFile ".\jobs\feature_test_001\job.json"

# 查看结果
Get-Content ".\jobs\feature_test_001\features.json" | ConvertFrom-Json | ConvertTo-Json -Depth 5
```

## blockcell 典型用途

- **每日特征包**：定时任务每天 00:00 UTC 计算全品种特征，写入 `features_daily.json`
- **市场扫描**：agent 问"哪些品种处于趋势状态" → 读 `MARKET_STATE` 字段
- **波动率监控**：比较各品种 `ATR_H4`，找异常波动品种
- **信号过滤**：结合 `RSI_H4` + `MA_TREND` 过滤低质量信号

## 注意事项

- FeatureWorker 使用 Strategy Tester 离线运行，不需要 MT4 实时连接
- 特征值基于 Strategy Tester 的历史数据，与实盘 MT4 的实时值可能有细微差异（数据源相同时一致）
- 同一 runner 实例同一时刻只能运行一个任务（并发冲突检查）
- `as_of_date` 仅用于标记，实际计算使用 Strategy Tester 的最后一根 bar 数据
