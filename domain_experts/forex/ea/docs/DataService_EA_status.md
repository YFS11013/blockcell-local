# DataService_EA 现状记录

测试时间：2026-03-14  
EA 版本：旧版（`"Version": "1.2_IntegerTypeFix"`）  
端口：`tcp://localhost:5556`  
测试工具：`domain_experts/forex/ea/scripts/zmq_client.py`

---

## 连通性

| 命令 | 结果 | 备注 |
|------|------|------|
| `PING` | `{"pong": true}` | 正常 |

---

## 账户 / 持仓

| 命令 | 结果摘要 | 备注 |
|------|---------|------|
| `GET_ACCOUNT_INFO` | Balance=102907.47, Equity=101984.52, Margin=31.32 | 字段名大写（旧版风格） |
| `GET_POSITIONS` | 35 条持仓，含 EURUSD/USDJPY/GBPUSD/GBPCHF/EURNZD/CHFJPY/CADJPY/AUDCHF | 正常，含挂单（Type 2/4/5） |
| `IS_MARKET_OPEN` | `{"IsOpen": false}` | 周末，市场关闭 |

---

## 技术指标（EURUSD H4，测试时间 2026-03-14 周末）

| 命令 | 返回值 | 备注 |
|------|--------|------|
| `GET_INDICATOR:RSI,EURUSD,240,14` | `{"Value": 32.17}` | 正常 |
| `GET_INDICATOR:MACD,EURUSD,240,12,26,9` | `{"Main": -0.003796, "Signal": -0.002660}` | 正常 |
| `GET_INDICATOR:Bollinger Bands,EURUSD,240,20,2.0` | `{"Middle": 1.1553, "Upper": 1.1673, "Lower": 1.1434}` | 命令名含空格，需加引号 |
| `GET_INDICATOR:Stochastic,EURUSD,240,5,3,3` | `{"Main": 21.13, "Signal": 18.31}` | 正常 |
| `GET_INDICATOR:MA,EURUSD,240,50` | `{"Value": 1.157995}` | 正常 |
| `GET_INDICATOR:ATR,EURUSD,240,14` | `{"Value": 0.003623}` | 正常 |

---

## K线数据

| 命令 | 结果摘要 | 备注 |
|------|---------|------|
| `GET_HISTORICAL_DATA:EURUSD,240,3` | 返回最近 3 根 H4 K线，含 time/open/high/low/close/tick_volume | 正常 |

---

## 旧版 EA 与新版 DataService_EA.mq4 的字段差异

| 字段 | 旧版（运行中） | 新版（待替换） |
|------|--------------|--------------|
| 账户余额 | `Balance` | `balance` |
| 净值 | `Equity` | `equity` |
| 保证金 | `Margin` | `margin` |
| 可用保证金 | 无 | `free_margin` |
| 账户货币 | 无 | `currency` |
| 市场状态 | `IsOpen` | `is_open` |
| 服务器时间 | 无 | `server_time` |
| 指标值 | `Value`/`Main`/`Signal` | `value`/`main`/`signal` |
| K线数组 | `History` | `bars` |
| 品种信息 | 无此命令 | `GET_SYMBOL_INFO` |
| BB 命令名 | `Bollinger Bands`（含空格） | `BB` |
| EMA | 无 | `GET_INDICATOR:EMA,...` |
| timer 间隔 | 1000ms（1秒） | 100ms（毫秒级） |

---

## 结论

旧版 EA 功能覆盖：**基本满足当前需求**

缺失项（需换新版才有）：
- `free_margin` / `currency`
- `GET_SYMBOL_INFO`（bid/ask/spread/digits）
- `EMA` 指标
- 毫秒级轮询（当前 1s timer，高频查询可能丢请求）

当前策略：**继续使用旧版，待需要缺失功能时再替换新版**

---

## zmq_client.py 兼容性说明

`zmq_client.py` 对旧版 EA 完全兼容，字段名差异由调用方处理。  
调用旧版时注意：
- BB 命令名含空格：`"GET_INDICATOR:Bollinger Bands,EURUSD,240,20,2.0"`（命令行需加引号）
- 字段名为大写：`Balance`/`Equity`/`IsOpen`/`Value`/`Main`/`Signal`/`History`
