# OrderExecutor 模块实现说明

## 概述

OrderExecutor 模块负责执行订单开仓操作，包括单笔开仓、批量拆单开仓、错误处理和滑点记录。

## 已实现功能

### 1. 单笔开仓 (Task 6.1)

**函数**: `int OpenPosition(double lots, double entry, double stop_loss, double take_profit, int slippage)`

**功能**:
- 执行单笔做空订单（V1 固定 OP_SELL）
- 设置止损和止盈价格
- 使用 Bid 价作为开仓价格
- 返回订单号（成功 >0，失败 -1）

**参数**:
- `lots`: 手数
- `entry`: 入场参考价格（实际使用 Bid）
- `stop_loss`: 止损价格
- `take_profit`: 止盈价格
- `slippage`: 最大允许滑点（点数）

### 2. 批量开仓（拆单）(Task 6.2)

**函数**: `int OpenMultiplePositions(LotSplit &splits[], int split_count, double entry, double stop_loss, int slippage, int &tickets[])`

**功能**:
- 遍历拆单数组，为每个拆分订单执行开仓
- 为每个订单设置对应的止盈价格
- 所有订单共享相同的止损价格
- 订单之间添加 100ms 延迟，避免请求过于频繁
- 返回成功开仓的订单数量

**参数**:
- `splits[]`: 拆单结果数组（包含手数和止盈价格）
- `split_count`: 拆单数量
- `entry`: 入场参考价格
- `stop_loss`: 止损价格（所有订单共享）
- `slippage`: 最大允许滑点（点数）
- `tickets[]`: 输出的订单号数组

**特性**:
- 部分失败不影响其他订单：即使某个订单失败，仍会继续尝试开启其他订单
- 失败的订单在 tickets 数组中标记为 -1

### 3. 订单错误处理和重试逻辑 (Task 6.3)

**功能**:
- 识别可重试和不可重试错误
- 可重试错误：最多重试 3 次，间隔 1 秒
- 不可重试错误：立即放弃，保护账户安全
- 每次重试都刷新价格

**可重试错误**:
- ERR_SERVER_BUSY (4) - 交易服务器繁忙
- ERR_NO_CONNECTION (6) - 无连接到交易服务器
- ERR_TOO_FREQUENT_REQUESTS (8) - 请求过于频繁
- ERR_TRADE_TIMEOUT (128) - 交易超时
- ERR_PRICE_CHANGED (135) - 价格改变
- ERR_OFF_QUOTES (136) - 无报价
- ERR_BROKER_BUSY (137) - 经纪商繁忙
- ERR_REQUOTE (138) - 重新报价
- ERR_TRADE_CONTEXT_BUSY (146) - 交易上下文繁忙

**不可重试错误**:
- ERR_INVALID_STOPS (130) - 无效止损
- ERR_INVALID_TRADE_VOLUME (131) - 无效交易量
- ERR_MARKET_CLOSED (132) - 市场关闭
- ERR_TRADE_DISABLED (133) - 交易被禁用
- ERR_NOT_ENOUGH_MONEY (134) - 资金不足
- ERR_ORDER_LOCKED (139) - 订单被锁定
- ERR_MODIFICATION_DENIED (145) - 修改被禁止
- ERR_TRADE_TOO_MANY_ORDERS (148) - 订单数量超过限制

### 4. 实际滑点记录 (Task 6.4)

**功能**:
- 开仓成功后，获取实际成交价格
- 计算实际滑点（点数）= |实际成交价 - 预期价格| / Point
- 记录到日志
- 如果实际滑点超过允许滑点，记录警告（订单已成交，不撤销）

**日志输出示例**:
```
INFO: 实际滑点记录 - 预期价格=1.16800, 实际成交价=1.16805, 滑点=0.5 点
WARN: 实际滑点 (1.2 点) 超过允许滑点 (1.0 点)
```

## 辅助函数

### IsRetryableError(int error_code)
判断错误码是否可重试。

### ErrorDescription(int error_code)
将 MT4 错误码转换为可读的错误描述。

### GetOrderInfo(int ticket, OrderInfo &info)
获取订单详细信息（订单号、开仓价、止损、止盈、手数、开仓时间、备注）。

## 数据结构

### OrderInfo
```mql4
struct OrderInfo {
    int ticket;              // 订单号
    double open_price;       // 开仓价格
    double stop_loss;        // 止损价格
    double take_profit;      // 止盈价格
    double lots;             // 手数
    datetime open_time;      // 开仓时间
    double actual_slippage;  // 实际滑点（点数）
    string comment;          // 订单备注
};
```

## 设计原则

1. **安全优先**: 所有异常情况优先保护账户安全
2. **错误分类**: 明确区分可重试和不可重试错误
3. **重试机制**: 可重试错误最多重试 3 次，间隔 1 秒
4. **价格刷新**: 每次重试都刷新价格，避免使用过期价格
5. **详细日志**: 记录所有开仓尝试、错误和滑点信息
6. **部分成功**: 批量开仓时，部分失败不影响其他订单

## 依赖

- `RiskManager.mqh`: 使用 LotSplit 结构体

## 使用示例

### 单笔开仓
```mql4
double lots = 0.1;
double entry = 1.1680;
double stop_loss = 1.1720;
double take_profit = 1.1550;
int slippage = 10;

int ticket = OpenPosition(lots, entry, stop_loss, take_profit, slippage);
if(ticket > 0) {
    Print("开仓成功, ticket=", ticket);
} else {
    Print("开仓失败");
}
```

### 批量开仓（拆单）
```mql4
// 准备拆单数组
LotSplit splits[3];
splits[0].lots = 0.03;
splits[0].tp_price = 1.1550;
splits[1].lots = 0.04;
splits[1].tp_price = 1.1500;
splits[2].lots = 0.03;
splits[2].tp_price = 1.1350;

int split_count = 3;
double entry = 1.1680;
double stop_loss = 1.1720;
int slippage = 10;
int tickets[];

int success_count = OpenMultiplePositions(splits, split_count, entry, stop_loss, slippage, tickets);
Print("成功开仓: ", success_count, "/", split_count);

// 检查每个订单
for(int i = 0; i < split_count; i++) {
    if(tickets[i] > 0) {
        Print("订单 ", i+1, " 成功, ticket=", tickets[i]);
    } else {
        Print("订单 ", i+1, " 失败");
    }
}
```

## 需求映射

- **需求 2.7**: 执行开仓操作 ✓
- **需求 2.9**: 拆分订单 ✓
- **需求 2.12**: 为每个订单设置对应的止盈价格 ✓
- **需求 3.5**: 设置最大允许滑点参数 ✓
- **需求 3.6**: 记录实际滑点 ✓
- **需求 10.3**: 识别可重试和不可重试错误 ✓
- **需求 10.4**: 实现重试逻辑 ✓
- **需求 10.5**: 实现网络中断等待重连逻辑 ✓
- **需求 10.6**: 实现异常市场数据保守拒单策略 ✓

## 后续集成

OrderExecutor 模块已完成，可以被以下模块调用：
- EA 主循环（OnTick）
- 信号执行逻辑（ExecutePendingSignal）
- 持仓管理器（Position Manager）

## 测试建议

1. **单元测试**:
   - 测试单笔开仓成功场景
   - 测试单笔开仓失败场景（可重试/不可重试错误）
   - 测试批量开仓成功场景
   - 测试批量开仓部分失败场景
   - 测试滑点记录功能

2. **集成测试**:
   - 在 MT4 Strategy Tester 中测试
   - 使用模拟账户测试
   - 验证错误处理和重试逻辑

3. **压力测试**:
   - 测试网络不稳定情况
   - 测试服务器繁忙情况
   - 测试大量订单同时开仓

## 注意事项

1. V1 版本固定做空（OP_SELL），后续版本可扩展支持做多
2. 订单备注（comment）目前为固定值，后续可添加参数版本号等信息
3. 魔术号（magic）目前为 0，后续可用于区分不同策略的订单
4. 实际滑点超过允许滑点时只记录警告，不撤销已成交订单
5. 批量开仓时，订单之间有 100ms 延迟，避免请求过于频繁
