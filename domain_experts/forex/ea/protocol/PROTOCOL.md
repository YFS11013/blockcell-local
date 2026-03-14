# MT4 Worker 文件协议规范

版本：1.0 | 更新：2026-03-14

blockcell agent 与 MT4 EA 之间通过本地文件交换数据。  
本协议定义四种文件的 schema、语义和读写职责。

---

## 文件概览

| 文件 | 写入方 | 读取方 | 触发时机 |
|------|--------|--------|---------|
| `job.json` | blockcell | EA | blockcell 派发任务时 |
| `result.json` | EA | blockcell | EA 任务完成时 |
| `heartbeat.json` | EA | blockcell | EA 运行中每 10s 覆盖写 |
| `error.json` | EA | blockcell | EA 遇到无法恢复的错误时 |

---

## 目录约定

```
MQL4/Files/
  jobs/
    {job_id}/
      job.json          ← blockcell 写入
      result.json       ← EA 写入（完成后）
      heartbeat.json    ← EA 覆盖写（运行中）
      error.json        ← EA 写入（出错时）
```

EA 启动时扫描 `jobs/` 目录，找到 `job.json` 存在但 `result.json` 不存在的目录即为待执行任务。

---

## job.json — 任务输入

blockcell 写入，EA 读取。

**必填字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `job_id` | string | 全局唯一 ID，格式：`{type}_{YYYYMMDD_HHMMSS}_{random4}` |
| `job_type` | enum | `replay` / `feature` / `collect` / `test` |
| `created_at` | ISO 8601 | 任务创建时间（UTC） |

**常用可选字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `symbol` | string | 品种，如 `EURUSD` |
| `timeframe` | integer | 时间框架（分钟）：1/5/15/30/60/240/1440/10080 |
| `date_from` / `date_to` | YYYY-MM-DD | 回放/采集日期范围 |
| `ea_name` | string | EA 文件名（不含 .ex4） |
| `ea_params` | object | EA 输入参数，值统一为字符串 |
| `output_path` | string | 相对于 MQL4/Files/ 的输出路径 |
| `timeout_seconds` | integer | 超时秒数，默认 300 |
| `meta` | object | 调用方自定义元数据，原样透传到 result.json |

**示例**：见 `examples/job_replay.json`、`examples/job_feature.json`

---

## result.json — 任务输出

EA 写入，blockcell 读取。任务完成（成功或失败）后写入。

**必填字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `job_id` | string | 对应 job.json 的 job_id |
| `job_type` | enum | 同 job.json |
| `status` | enum | `success` / `failed` / `timeout` / `partial` |
| `finished_at` | ISO 8601 | 完成时间（UTC） |

**data 字段结构（按 job_type）**：

`replay` 类型：
```json
{
  "total_bars": 1320,
  "signals_generated": 47,
  "signals_hit": 31,
  "hit_rate": 0.659
}
```

`feature` 类型：
```json
{
  "symbols_processed": 3,
  "features": {
    "EURUSD": { "RSI_H4": 32.17, "ATR_H4": 0.00362, "market_state": "trending_down" }
  }
}
```

`status=failed` 时必须包含 `error_message` 字段。

**示例**：见 `examples/result_success.json`、`examples/result_failed.json`

---

## heartbeat.json — 存活心跳

EA 每 10 秒覆盖写，blockcell 据此判断 EA 是否存活。

若 blockcell 超过 `timeout_seconds * 1.5` 秒未收到心跳更新，视为 EA 异常，写入 error.json。

**必填字段**：`job_id`、`status`（`running`/`idle`）、`timestamp`

**可选字段**：`progress_pct`、`current_bar`、`total_bars`、`ea_version`

**示例**：见 `examples/heartbeat.json`

---

## error.json — 错误报告

EA 遇到无法恢复的错误时写入（不写 result.json）。

**必填字段**：`job_id`、`error_code`、`error_message`、`timestamp`

**error_code 枚举**：

| 错误码 | 含义 |
|--------|------|
| `JOB_NOT_FOUND` | job.json 不存在或路径错误 |
| `JOB_PARSE_ERROR` | job.json 解析失败 |
| `EA_INIT_FAILED` | EA OnInit 失败 |
| `SYMBOL_NOT_AVAILABLE` | 品种数据不可用 |
| `DATA_COPY_FAILED` | CopyRates 失败 |
| `TIMEOUT` | 超过 timeout_seconds |
| `OUTPUT_WRITE_FAILED` | 无法写出 result.json |
| `UNKNOWN` | 其他未分类错误 |

**示例**：见 `examples/error.json`

---

## blockcell 侧处理逻辑

```
写 job.json
  ↓ 等待（轮询 result.json 或 error.json）
  ├── result.json 出现 → 读取结果，处理 data
  ├── error.json 出现 → 告警/重试
  └── 超时（heartbeat 停止更新）→ 写 error.json，告警
```

---

## 验证工具

```powershell
# 安装依赖
pip install jsonschema

# 验证单个文件
python domain_experts/forex/ea/protocol/validate.py path/to/job.json

# 批量验证示例目录
python domain_experts/forex/ea/protocol/validate.py domain_experts/forex/ea/protocol/examples/

# 强制指定类型
python domain_experts/forex/ea/protocol/validate.py myfile.json --type result
```

---

## Schema 文件

| 文件 | 说明 |
|------|------|
| `job.schema.json` | job.json schema |
| `result.schema.json` | result.json schema |
| `heartbeat.schema.json` | heartbeat.json schema |
| `error.schema.json` | error.json schema |
