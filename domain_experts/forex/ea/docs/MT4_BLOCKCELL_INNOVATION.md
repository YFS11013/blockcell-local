# MT4 + EA 作为 blockcell 工具/技能的创新用法（非交易）

版本：V2 | 更新：2026-03-14

---

## 核心定位

MT4 = **边缘时序计算节点 + 实时数据 RPC 服务器**，不是交易系统。

```
blockcell agent（决策/通知/编排）
    ↕ ZMQ REQ/REP          ↕ 文件协议 (job/result JSON)
DataService_EA（实时查询）   MT4 Strategy Tester（历史回放）
    ↕ MT4 内部 API               ↕ 数据源
实盘/模拟盘行情              Tickstory 历史 tick 库
```

## 已确认的技术约束

- MT4 无可编程经济日历 API（MT5 才有），事件源需外部落盘
- `OnTimer` 不适合关键任务调度，只适合 EA 内部轻量轮询
- Strategy Tester 确定性依赖相同数据+模型+参数（Tickstory 满足此条件）
- 历史数据内部自用，不对外分发

---

## 方向一：实时数据 RPC（P1 — 已完成）

**组件**：`DataService_EA.mq4` + `zmq_client.py` + `mt4_query` skill

**链路**：
```
blockcell skill: mt4_query
  → exec: python zmq_client.py "GET_INDICATOR:RSI,EURUSD,240,14"
  ← {"Value": 32.17}
```

**支持的查询**：

| 命令 | 说明 |
|------|------|
| `PING` | 连通性检查 |
| `GET_ACCOUNT_INFO` | 账户余额/净值/保证金 |
| `GET_POSITIONS` | 当前持仓列表 |
| `GET_INDICATOR:RSI/MACD/BB/Stoch/MA/ATR,...` | 实时技术指标 |
| `GET_HISTORICAL_DATA:symbol,tf,count` | 最近 N 根 K 线 OHLCV |
| `IS_MARKET_OPEN` | 市场状态检测 |
| `GET_SYMBOL_INFO:symbol` | bid/ask/spread（新版 EA） |

**blockcell 用途**：
- agent 实时问答："现在 EURUSD RSI 是多少？"
- 定时任务：每小时检查市场状态，写入 `market_state.json`
- 多品种指标扫描：批量查 ATR，找波动率异常品种

---

## 方向二：历史数据回放验证（P2 — 已完成）

**依赖**：Tickstory 高质量 tick 库 + 现有 `run_mt4_task14_backtest.ps1` 基础设施

**链路**：
```
blockcell 写 job.json（品种/时间范围/EA参数）
  → run_replay.ps1（泛化版 backtest 脚本）
  → Tickstory 导出 .hst → MT4 Strategy Tester（Every Tick）
  → ReplayWorker.mq4 执行算法 → 写 result_{job_id}.json
  → run_replay.ps1 读取结果，写到 job 目录 result.json
  → blockcell 读取结果，汇总/通知
```

**组件**：
- `run_replay.ps1`：接受 `job.json`，支持任意 EA + 品种 + 日期范围，写 `result.json`
- `ReplayWorker.mq4`：通用回放 EA，读 `job.json`，写 `result.json` + `heartbeat.json`

**blockcell 用途**：
- 验证 blockcell 生成的信号在历史数据上的命中率
- 参数网格扫描：blockcell 生成参数组合 → 批量回放 → 找最优
- 算法对比：同一时间段跑两个不同策略，比较结果
- 用 Tickstory 99.9% tick 质量做确定性验证

**与现有基础设施的关系**：
- `run_mt4_task14_backtest.ps1` 已是此模式，`run_replay.ps1` 是其泛化版
- `job.json` 替代现有 `.ini` 硬编码，`ea_params` 替代 `.set` 硬编码

---

## 方向三：特征工程流水线（P3 — 已完成）

**链路**：
```
blockcell 写 feature_job.json（品种列表 + 特征列表 + as_of_date）
  → run_feature.ps1
  → MT4 Strategy Tester（Tickstory 数据）
  → FeatureWorker.mq4 计算特征 → 写 features.json + result.json
  → blockcell agent 消费特征做决策
```

**组件**：
- `FeatureWorker.mq4`：读 `job.json`，计算多品种特征，写 `features.json` + `result.json`
- `run_feature.ps1`：接受 `job.json`，驱动 FeatureWorker，写产物到 job 目录
- `mt4_features` skill：Rhai + SKILL.md，blockcell 调用入口

---

## 方向四：headless 测试基础设施（P4 — 已完成）

**已有基础**：`run_mt4_magic_number_tests.ps1` 模式（保留，向后兼容）

**泛化产物**：
- `run_ea_test.ps1`：通用 EA 测试 runner，接受任意 EA 名 + 测试参数，解析 `AUTO_TEST_SUMMARY` 输出 PASS/FAIL
- `EaTestBase.mqh`：测试基础库，新测试 EA 只需 `#include "EaTestBase.mqh"` + 实现 `RunTests()`

**使用方式**：
```powershell
# 运行任意测试 EA
.\run_ea_test.ps1 -EaName MyTestEA

# 等价替代旧脚本（校验期望数量）
.\run_ea_test.ps1 -EaName TestMagicNumberBugEA -ExpectedExplorePasses 3 -ExpectedPreservePasses 5
```

---

## 优先级路线图

```
P0（地基）✅ 已完成
  └── 统一文件协议：job.json / result.json / heartbeat.json / error.json schema
      产物：`ea/protocol/` — 4 个 schema + 6 个示例 + validate.py + PROTOCOL.md

P1（实时数据 RPC）✅ 已完成
  ├── DataService_EA.mq4（新版，100ms timer，含 GET_SYMBOL_INFO/EMA）
  ├── zmq_client.py（Python ZMQ client）
  └── mt4_query skill（Rhai + SKILL.md）
      当前：使用旧版 EA（1.2_IntegerTypeFix），ZMQ 链路已验证通

P2（历史回放泛化）✅ 已完成
  ├── run_replay.ps1（接受 job.json，支持任意 EA + 品种 + 日期范围）
  └── ReplayWorker.mq4（通用回放 EA，写 result.json + heartbeat.json）
      依赖：P0 文件协议

P3（特征工程）✅ 已完成
  ├── FeatureWorker.mq4（读 job.json，计算多品种特征，写 features.json + result.json）
  ├── run_feature.ps1（接受 job.json，驱动 FeatureWorker，写产物到 job 目录）
  └── mt4_features skill（Rhai + SKILL.md）
      依赖：P0 + P2

P4（CI 测试框架）✅ 已完成
  ├── run_ea_test.ps1（通用 EA 测试 runner，接受任意 EA 名，解析 AUTO_TEST_SUMMARY）
  └── EaTestBase.mqh（测试基础库，AssertExplore/AssertPreserve/RunAllTests）
      已有基础：run_mt4_magic_number_tests.ps1（保留，向后兼容）
```

---

## 当前已交付产物

| 产物 | 路径 | 状态 |
|------|------|------|
| DataService_EA（新版） | `ea/DataService_EA.mq4` | 已写，待替换旧版 |
| ZMQ Python client | `ea/scripts/zmq_client.py` | 已验证 |
| mt4_query skill | `domain_experts/forex/skills/mt4_query/` | 已写 |
| 旧版 EA 现状记录 | `ea/docs/DataService_EA_status.md` | 已完成 |
| headless 测试框架（旧，向后兼容） | `ea/scripts/run_mt4_magic_number_tests.ps1` | 已完成 |
| ForexStrategyExecutor | `ea/ForexStrategyExecutor.mq4` | 已完成（含 magic number 修复）|
| run_replay.ps1 | `ea/scripts/run_replay.ps1` | 已完成（P2）|
| ReplayWorker.mq4 | `ea/ReplayWorker.mq4` | 已完成（P2）|
| FeatureWorker.mq4 | `ea/FeatureWorker.mq4` | 已完成（P3）|
| run_feature.ps1 | `ea/scripts/run_feature.ps1` | 已完成（P3）|
| mt4_features skill | `domain_experts/forex/skills/mt4_features/` | 已完成（P3）|
| run_ea_test.ps1 | `ea/scripts/run_ea_test.ps1` | 已完成（P4，通用 EA 测试 runner）|
| EaTestBase.mqh | `ea/include/EaTestBase.mqh` | 已完成（P4，测试基础库）|

---

## 关键约束（始终有效）

- `OnTimer` 只做轻量轮询，不做关键调度
- Strategy Tester 确定性依赖 Tickstory 相同数据（已满足）
- 历史数据内部自用，不对外分发
- `EXECUTE_TRADE` / `CLOSE_ORDER` 命令不暴露给 blockcell skill（只读接口原则）
- 同一 runner 实例测试任务必须串行执行；检测到 `terminal.exe` 占用时阻断新任务
