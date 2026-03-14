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

## 方向二：历史数据回放验证（P2 — 规划中）

**依赖**：Tickstory 高质量 tick 库 + 现有 `run_mt4_task14_backtest.ps1` 基础设施

**链路**：
```
blockcell 写 job.json（品种/时间范围/EA参数）
  → run_replay.ps1（泛化版 backtest 脚本）
  → Tickstory 导出 .hst → MT4 Strategy Tester（Every Tick）
  → replay_worker EA 执行算法 → 写 result.json
  → blockcell 读取结果，汇总/通知
```

**blockcell 用途**：
- 验证 blockcell 生成的信号在历史数据上的命中率
- 参数网格扫描：blockcell 生成参数组合 → 批量回放 → 找最优
- 算法对比：同一时间段跑两个不同策略，比较结果
- 用 Tickstory 99.9% tick 质量做确定性验证

**与现有基础设施的关系**：
- `run_mt4_task14_backtest.ps1` 已是此模式，只需泛化参数（EA 名、品种、日期范围可配置）
- `job.json` 替代现有 `.ini` 硬编码

---

## 方向三：特征工程流水线（P3 — 规划中）

**链路**：
```
blockcell 写 feature_job.json（品种列表 + 特征列表 + as_of_date）
  → MT4 Strategy Tester（Tickstory 数据）
  → feature_worker EA 计算特征 → 写 features.json
  → blockcell agent 消费特征做决策
```

**EA 可计算的特征**（MT4 内置，比 Python 调 API 快）：
- 多周期 ATR（波动率特征）
- 多周期 MA 排列（趋势特征）
- Bollinger Band 位置（均值回归特征）
- Fractal/Pivot 支撑阻力位
- 市场状态分类（趋势/震荡/突破）

**blockcell 用途**：
- 每日定时生成特征包，供 agent 做市场分析
- 替代 Python 调 broker REST API（本地计算，无网络依赖）

---

## 方向四：headless 测试基础设施（P4 — 已有，持续完善）

**已有基础**：`run_mt4_magic_number_tests.ps1` 模式

**泛化方向**：任意 MQL4 算法 → 编译 → Strategy Tester → 解析日志 → 返回 PASS/FAIL

**blockcell 用途**：
- blockcell CI：每次修改 EA 代码自动触发测试
- 算法正确性验证：用 Tickstory 数据做确定性回归测试

---

## 优先级路线图

```
P0（地基）
  └── 统一文件协议：job.json / result.json / heartbeat.json / error.json schema
      状态：待实现

P1（实时数据 RPC）✅ 已完成
  ├── DataService_EA.mq4（新版，100ms timer，含 GET_SYMBOL_INFO/EMA）
  ├── zmq_client.py（Python ZMQ client）
  └── mt4_query skill（Rhai + SKILL.md）
      当前：使用旧版 EA（1.2_IntegerTypeFix），ZMQ 链路已验证通

P2（历史回放泛化）
  └── run_replay.ps1（接受 job.json，支持任意 EA + 品种 + 日期范围）
      依赖：P0 文件协议
      状态：待实现

P3（特征工程）
  └── feature_worker EA + mt4_features skill
      依赖：P0 + P2
      状态：待实现

P4（CI 测试框架）
  └── 泛化 run_mt4_magic_number_tests.ps1 → 通用 EA 测试 runner
      状态：已有基础，待泛化
```

---

## 当前已交付产物

| 产物 | 路径 | 状态 |
|------|------|------|
| DataService_EA（新版） | `ea/DataService_EA.mq4` | 已写，待替换旧版 |
| ZMQ Python client | `ea/scripts/zmq_client.py` | 已验证 |
| mt4_query skill | `skills/mt4_query/` | 已写 |
| 旧版 EA 现状记录 | `ea/docs/DataService_EA_status.md` | 已完成 |
| headless 测试框架 | `ea/scripts/run_mt4_magic_number_tests.ps1` | 已完成 |
| ForexStrategyExecutor | `ea/ForexStrategyExecutor.mq4` | 已完成（含 magic number 修复）|

---

## 关键约束（始终有效）

- `OnTimer` 只做轻量轮询，不做关键调度
- Strategy Tester 确定性依赖 Tickstory 相同数据（已满足）
- 历史数据内部自用，不对外分发
- `EXECUTE_TRADE` / `CLOSE_ORDER` 命令不暴露给 blockcell skill（只读接口原则）
