# mt4_query Skill

通过 ZMQ 实时查询 MT4 DataService EA，为 blockcell agent 提供市场数据接口。

详细文档见 [SKILL.md](SKILL.md)。

## 快速开始

### 1. 安装依赖

```powershell
pip install pyzmq
```

### 2. 在 MT4 中挂载 EA

将 `domain_experts/forex/ea/DataService_EA.mq4` 编译后挂载到任意图表，确认日志出现：

```
[DataService] Ready on tcp://*:5556 (poll interval=100ms)
```

### 3. 测试连通性

```powershell
python domain_experts/forex/ea/scripts/zmq_client.py PING
# 输出: {"pong": true}
```

### 4. 查询示例

```powershell
# RSI
python domain_experts/forex/ea/scripts/zmq_client.py "GET_INDICATOR:RSI,EURUSD,240,14" --pretty

# 账户信息
python domain_experts/forex/ea/scripts/zmq_client.py "GET_ACCOUNT_INFO" --pretty

# 最近 50 根 H4 K线
python domain_experts/forex/ea/scripts/zmq_client.py "GET_HISTORICAL_DATA:EURUSD,240,50" --pretty
```

### 5. 通过 blockcell 触发

```bash
blockcell run msg "GET_INDICATOR:RSI,EURUSD,240,14"
blockcell run msg "IS_MARKET_OPEN"
```
