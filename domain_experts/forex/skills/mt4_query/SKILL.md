# mt4_query Skill

## 概述

通过 ZMQ REQ/REP 协议查询 MT4 DataService EA，为 blockcell agent 提供实时市场数据接口。

**定位**：只读数据查询，不执行任何交易操作。

## 触发场景

当用户询问以下类型的问题时，agent **应优先调用此 skill**，而不是生成策略或使用缓存数据：

### 实时指标查询
- "现在 EURUSD RSI 是多少"
- "EURUSD 当前 RSI 值"
- "查一下 EURUSD H4 的 RSI"
- "GBPUSD MACD 信号怎么样"
- "EURUSD 布林带上下轨在哪"
- "当前 ATR 是多少"
- "EMA 200 在哪里"

### 实时报价
- "EURUSD 现在多少"
- "EURUSD 当前价格"
- "查询 GBPUSD 报价"
- "现在点差多少"

### 账户与持仓
- "我现在有哪些持仓"
- "当前账户余额"
- "账户净值是多少"
- "现在有几个单子"

### 市场状态
- "市场现在开着吗"
- "现在能交易吗"
- "MT4 连接正常吗"

### K 线数据
- "给我最近 100 根 H4 K 线"
- "EURUSD 历史数据"

**关键判断**：只要用户问的是"现在/当前/实时"的市场数据，就应该调用此 skill 从 MT4 获取，而不是依赖模型内部知识或缓存。

## 架构

```
blockcell agent
    ↓ ctx.user_input = "GET_INDICATOR:RSI,EURUSD,240,14"
SKILL.rhai
    ↓ exec: python zmq_client.py "GET_INDICATOR:RSI,EURUSD,240,14"
zmq_client.py (ZMQ REQ)
    ↕ tcp://localhost:5556
DataService_EA.mq4 (ZMQ REP，挂载在 MT4 图表)
    ↓ iRSI(EURUSD, H4, 14, PRICE_CLOSE, 1)
{"value": 58.3}
```

## 前置条件

1. MT4 已运行并登录（实盘或模拟盘均可）
2. `DataService_EA.mq4` 已编译并挂载在任意图表上
3. MT4 自动交易已启用（工具栏绿色按钮）
4. `pyzmq` 已安装：`pip install pyzmq`
5. `libzmq.dll` 在 MT4 的 `Libraries` 目录
6. `Zmq/Zmq.mqh` 和 `JAson.mqh` 在 MT4 的 `Include` 目录

## 支持的命令

### PING — 连通性检查

```
PING
```

返回：`{"pong": true}`

### GET_ACCOUNT_INFO — 账户信息

```
GET_ACCOUNT_INFO
```

返回：
```json
{
  "balance": 10000.0,
  "equity": 10050.5,
  "margin": 200.0,
  "free_margin": 9850.5,
  "currency": "USD"
}
```

### GET_SYMBOL_INFO — 品种报价

```
GET_SYMBOL_INFO:EURUSD
```

返回：
```json
{
  "symbol": "EURUSD",
  "bid": 1.08520,
  "ask": 1.08522,
  "spread": 2,
  "digits": 5,
  "point": 0.00001
}
```

### GET_INDICATOR — 技术指标

#### RSI
```
GET_INDICATOR:RSI,EURUSD,240,14
```
参数：`指标名,品种,时间框架(分钟),周期`

#### MACD
```
GET_INDICATOR:MACD,EURUSD,240,12,26,9
```
参数：`MACD,品种,时间框架,快线,慢线,信号线`

#### Bollinger Bands
```
GET_INDICATOR:BB,EURUSD,240,20,2.0
```
参数：`BB,品种,时间框架,周期,偏差`

#### ATR
```
GET_INDICATOR:ATR,EURUSD,240,14
```

#### MA / SMA / EMA
```
GET_INDICATOR:EMA,EURUSD,240,200
GET_INDICATOR:SMA,EURUSD,240,50
```

#### Stochastic
```
GET_INDICATOR:Stoch,EURUSD,240,5,3,3
```
参数：`Stoch,品种,时间框架,K周期,D周期,减速`

### GET_HISTORICAL_DATA — K线数据

```
GET_HISTORICAL_DATA:EURUSD,240,100
```
参数：`品种,时间框架(分钟),数量`

返回最近 N 根 K 线的 OHLCV 数据。

### IS_MARKET_OPEN — 市场状态

```
IS_MARKET_OPEN
```

返回：
```json
{
  "is_open": true,
  "trade_allowed": true,
  "server_time": 1741234567.0
}
```

### GET_POSITIONS — 当前持仓

```
GET_POSITIONS
```

## 时间框架对照表

| 常用名 | 分钟数 |
|--------|--------|
| M1     | 1      |
| M5     | 5      |
| M15    | 15     |
| M30    | 30     |
| H1     | 60     |
| H4     | 240    |
| D1     | 1440   |
| W1     | 10080  |

## 使用示例

### blockcell CLI

```bash
blockcell run msg "GET_INDICATOR:RSI,EURUSD,240,14"
blockcell run msg "GET_SYMBOL_INFO:EURUSD"
blockcell run msg "IS_MARKET_OPEN"
```

### 命令行直接测试

```powershell
# 连通性测试
python domain_experts/forex/ea/scripts/zmq_client.py PING

# 查询 RSI
python domain_experts/forex/ea/scripts/zmq_client.py "GET_INDICATOR:RSI,EURUSD,240,14" --pretty

# 查询最近 50 根 H4 K线
python domain_experts/forex/ea/scripts/zmq_client.py "GET_HISTORICAL_DATA:EURUSD,240,50" --pretty

# 自定义端口
python domain_experts/forex/ea/scripts/zmq_client.py PING --endpoint tcp://localhost:5557
```

## 故障排查

### timeout — EA 未响应

1. 确认 MT4 已运行
2. 确认 DataService_EA 已挂载在图表上（图表右上角有 EA 名称）
3. 确认 MT4 自动交易已启用（工具栏绿色按钮）
4. 检查 MT4 日志：`[DataService] Ready on tcp://*:5556`

### pyzmq not installed

```powershell
pip install pyzmq
```

### 端口冲突

修改 DataService_EA 的 `ZmqPort` 输入参数，同时在调用时传入 `--endpoint tcp://localhost:<新端口>`。

### libzmq.dll 缺失

将 `libzmq.dll`（或 `libzmq-mt-4_2_1_10.dll`）复制到 MT4 安装目录的 `Libraries` 文件夹。

## 注意事项

- 此 skill 仅提供只读查询，不执行任何交易操作
- `EXECUTE_TRADE` / `CLOSE_ORDER` 命令未在 skill 中暴露
- DataService_EA 挂载在哪个图表上，`Symbol()` 就返回那个品种；建议挂在 EURUSD H1 图表
- ZMQ REP socket 是单线程的，并发请求会排队处理
