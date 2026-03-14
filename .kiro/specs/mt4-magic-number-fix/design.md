# MT4 Magic Number Fix — Bugfix Design

## Overview

`OrderExecutor.mqh` 中 `OpenPosition` 函数将 `magic` 硬编码为 `0`，导致 MT4 无法通过 magic number 区分不同 EA 的订单。本次修复将 `magic` 提升为函数参数，由 `ForexStrategyExecutor.mq4` 通过 EA 输入参数 `MagicNumber` 控制，并在 `PositionManager.mqh` 中新增按 magic 过滤持仓的逻辑。

修复范围：
- `OrderExecutor.mqh` — `OpenPosition` / `OpenMultiplePositions` 函数签名增加 `magic` 参数，入口处校验 magic <= 0 时记录警告并直接返回失败（不进重试）
- `PositionManager.mqh` — `GetOpenPositions` 增加按 MagicNumber 过滤（新增行为）
- `ForexStrategyExecutor.mq4` — 增加 EA 输入参数 `MagicNumber`（默认值 12345），所有调用点传入该参数

---

## Glossary

- **Bug_Condition (C)**: 触发 bug 的条件 — `OpenPosition` / `OpenMultiplePositions` 被调用时 magic 参数为硬编码的 `0`，调用方无法指定有效 magic number
- **Property (P)**: 修复后的期望行为 — 函数使用调用方传入的 magic 参数，且 magic <= 0 时拒绝开仓
- **Preservation**: 现有的重试逻辑、拆单逻辑、DryRun 逻辑、成功返回 ticket 等行为不受本次修改影响
- **OpenPosition**: `OrderExecutor.mqh` 中执行单笔开仓的函数，当前 magic 硬编码为 0
- **OpenMultiplePositions**: `OrderExecutor.mqh` 中执行批量拆单开仓的函数，内部调用 `OpenPosition`
- **MagicNumber**: `ForexStrategyExecutor.mq4` 新增的 EA 输入参数，用于标识本 EA 的所有订单
- **GetOpenPositions**: `PositionManager.mqh` 中扫描当前持仓的函数，当前未按 magic 过滤

---

## Bug Details

### Bug Condition

bug 在以下情况下触发：`OpenPosition` 被调用时，函数内部将 `int magic = 0` 硬编码传入 `OrderSend`，忽略调用方的意图。`OpenMultiplePositions` 通过内部调用 `OpenPosition` 同样受影响。`PositionManager` 的 `GetOpenPositions` 未按 magic 过滤，会扫描到其他 EA 或手动订单。

**Formal Specification:**
```
FUNCTION isBugCondition(call_context)
  INPUT: call_context — 包含调用方期望的 magic 值和实际传入 OrderSend 的 magic 值
  OUTPUT: boolean

  RETURN call_context.caller_intended_magic != 0
         AND call_context.actual_magic_sent_to_OrderSend == 0
         // 即：调用方有意图指定 magic，但函数忽略了，强制使用 0
END FUNCTION
```

### Examples

- `OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3)` 调用时，`OrderSend` 收到 `magic=0`，而非调用方期望的 `12345` — **bug**
- `OpenMultiplePositions(splits, 2, 1.1000, 1.0950, 3, tickets)` 调用时，两笔订单均以 `magic=0` 开出 — **bug**
- 两个 EA 同时运行，`PositionManager` 扫描到另一个 EA 的订单并尝试管理 — **bug（新增行为缺失）**
- `OpenPosition` 传入 `magic=0` 时应直接返回 -1，不进重试 — **修复后期望行为**

---

## Expected Behavior

### Preservation Requirements

**不得改变的行为：**
- `OpenPosition` 成功开仓时仍返回有效 ticket（> 0）
- 可重试错误（如 ERR_SERVER_BUSY）仍触发最多 3 次重试，间隔 1 秒
- `OpenMultiplePositions` 仍遍历全部拆单，单笔失败不中止其余订单
- DryRun 模式下仍仅记录日志，不调用 `OrderSend`
- `GetOpenPositions` 对当前品种（`Symbol()`）的过滤逻辑不变

**范围：**
所有不涉及 magic number 传递的调用路径（如错误处理、重试、拆单遍历、DryRun 日志）均不受本次修改影响。

---

## Hypothesized Root Cause

1. **硬编码局部变量**: `OpenPosition` 函数体内 `int magic = 0;` 是局部变量，从未作为参数暴露给调用方，调用方无法覆盖
2. **函数签名未设计 magic 参数**: `OpenMultiplePositions` 同样未在签名中包含 magic，导致整条调用链均无法传递 magic
3. **EA 层缺少输入参数**: `ForexStrategyExecutor.mq4` 没有 `MagicNumber` 输入参数，即使修改了函数签名，调用方也没有值可传
4. **PositionManager 未过滤 magic**: `GetOpenPositions` 只按品种过滤（L94 `OrderSymbol() != Symbol()`），未检查 `OrderMagicNumber()`，导致跨 EA 订单污染

---

## Correctness Properties

Property 1: Bug Condition — Magic Number 参数传递

_For any_ 调用 `OpenPosition(lots, entry, sl, tp, slippage, magic)` 且 `magic > 0` 的情况，修复后的函数 SHALL 将该 `magic` 值原样传入 `OrderSend`，使开出的订单携带正确的 magic number。

**Validates: Requirements 2.1, 2.2, 2.3**

Property 2: Bug Condition — Magic <= 0 拒绝开仓

_For any_ 调用 `OpenPosition` 时传入 `magic <= 0` 的情况，修复后的函数 SHALL 记录警告日志并直接返回 `-1`，不调用 `OrderSend`，不进入重试循环。

**Validates: Requirements 2.4, 3.2**

Property 3: Preservation — 重试与拆单行为不变

_For any_ `magic > 0` 且开仓因可重试错误失败的情况，修复后的函数 SHALL 保持与原函数相同的重试行为（最多 3 次，间隔 1 秒），成功时返回 ticket > 0，失败时返回 -1。

**Validates: Requirements 3.1, 3.2, 3.3, 3.4**

Property 4: New Behavior — PositionManager 按 Magic 过滤

_For any_ 账户中存在多个不同 magic number 订单的情况，修复后的 `GetOpenPositions(positions, magic_number)` SHALL 仅返回 `OrderMagicNumber() == magic_number` 且 `OrderSymbol() == Symbol()` 的持仓，不返回其他 magic 的订单。

**Validates: Requirements 4.1**

---

## Fix Implementation

### Changes Required

**File 1**: `domain_experts/forex/ea/include/OrderExecutor.mqh`

**Function**: `OpenPosition`

**Specific Changes**:
1. **函数签名增加 magic 参数**: `int OpenPosition(double lots, double entry, double stop_loss, double take_profit, int slippage, int magic)`
2. **入口校验**: 在函数开头，`magic <= 0` 时调用 `Print("WARN: ...")` 并 `return -1`，不进入重试循环
3. **移除硬编码局部变量**: 删除 `int magic = 0;` 这行
4. **OrderSend 使用参数 magic**: `OrderSend(..., magic, ...)` 使用传入的参数值

**Function**: `OpenMultiplePositions`

**Specific Changes**:
1. **函数签名增加 magic 参数**: `int OpenMultiplePositions(LotSplit &splits[], int split_count, double entry, double stop_loss, int slippage, int &tickets[], int magic)`
2. **透传 magic**: 内部调用 `OpenPosition` 时传入 `magic` 参数

---

**File 2**: `domain_experts/forex/ea/include/PositionManager.mqh`

**Function**: `GetOpenPositions`

**Specific Changes**:
1. **函数签名增加 magic_number 参数**: `int GetOpenPositions(int &positions[], int magic_number)`
2. **新增 magic 过滤条件**: 在现有 `OrderSymbol() != Symbol()` 过滤之后，增加 `OrderMagicNumber() != magic_number` 时 `continue`
3. **更新所有内部调用点**: `InitPositionManager`、`CheckPositions`、`GetPositionStats` 中调用 `GetOpenPositions` 的地方均需传入 magic_number

由于 `PositionManager` 的函数需要知道 magic_number，需要引入一个模块级全局变量 `g_MagicNumber`，在 `InitPositionManager(int magic_number)` 时设置。

---

**File 3**: `domain_experts/forex/ea/ForexStrategyExecutor.mq4`

**Specific Changes**:
1. **新增输入参数**: 在输入参数区块增加 `input int MagicNumber = 12345; // EA 魔术号（必须 > 0，用于区分本 EA 订单）`
2. **ValidateInputParameters 增加校验**: `MagicNumber <= 0` 时 `Print("ERROR: ...")` 并 `return false`
3. **InitPositionManager 传入 magic**: `InitPositionManager(MagicNumber)`
4. **OpenMultiplePositions 调用点传入 magic**: `ExecutePendingSignal` 中调用 `OpenMultiplePositions` 时增加 `MagicNumber` 参数
5. **DryRun 日志记录 magic**: DryRun 分支的日志中增加 `MagicNumber` 信息，便于调试

---

## Testing Strategy

### Validation Approach

两阶段策略：先在未修复代码上运行探索性测试，确认 bug 表现并验证根因分析；再在修复后代码上运行 Fix Checking 和 Preservation Checking。

### Exploratory Bug Condition Checking

**Goal**: 在未修复代码上暴露反例，确认根因。

**Test Plan**: 构造调用当前（未修复）`OpenPosition` 的测试，通过 `g_LastOrderSendMagic` 全局变量（由 `OrderSend` wrapper 写入）捕获实际传入的 magic 参数，断言其等于调用方期望值（会失败，因为当前硬编码为 0）。

**Mock 机制 A — `OrderSend` wrapper（用于 OrderExecutor 测试）**:

MQL4 不支持函数指针 mock。采用宏重定向方案：`OrderExecutor.mqh` 中**不直接调用内建 `OrderSend`**，而是调用宏 `ORDER_SEND(...)`。生产代码中 `ORDER_SEND` 展开为内建 `OrderSend`；测试代码中 `#define UNIT_TEST` 后 `ORDER_SEND` 展开为 `MockOrderSend`，避免与内建函数同名冲突：

```mql4
// OrderExecutor.mqh 顶部
#ifdef UNIT_TEST
  // 测试桩：通过宏重定向，不重定义内建 OrderSend / GetLastError
  #define ORDER_SEND      MockOrderSend
  #define GET_LAST_ERROR  MockGetLastError
#else
  #define ORDER_SEND      OrderSend
  #define GET_LAST_ERROR  GetLastError
#endif

// 测试文件（TestOrderExecutor.mq4）中定义桩实现
#ifdef UNIT_TEST
  int g_LastOrderSendMagic = -1;
  int g_OrderSendCallCount = 0;
  int g_OrderSendReturnSequence[];
  int g_OrderSendSeqIndex = 0;
  int g_LastErrorSequence[];   // 预设 GetLastError 返回序列
  int g_LastErrorSeqIndex = 0;

  int MockOrderSend(string symbol, int cmd, double volume, double price,
                    int slippage, double stoploss, double takeprofit,
                    string comment, int magic, datetime expiration, color arrow_color) {
    g_LastOrderSendMagic = magic;
    g_OrderSendCallCount++;
    if(g_OrderSendSeqIndex < ArraySize(g_OrderSendReturnSequence))
      return g_OrderSendReturnSequence[g_OrderSendSeqIndex++];
    return 10001; // 默认返回有效 ticket
  }

  int MockGetLastError() {
    if(g_LastErrorSeqIndex < ArraySize(g_LastErrorSequence))
      return g_LastErrorSequence[g_LastErrorSeqIndex++];
    return 0;
  }
#endif
```

**Mock 机制 B — 订单查询 wrapper（用于 PositionManager 测试）**:

`PositionManager.mqh` 中同样采用宏重定向，将 `OrdersTotal`、`OrderSelect`、`OrderType`、`OrderSymbol`、`OrderMagicNumber` 替换为可注入的 wrapper。`MockOrderSelect` 负责保存当前选中索引到 `g_MockCurrentIndex`，其余 getter 均从该索引读取 `g_MockOrders[]`：

```mql4
// PositionManager.mqh 顶部
#ifdef UNIT_TEST
  #define ORDERS_TOTAL    MockOrdersTotal
  #define ORDER_SELECT    MockOrderSelect
  #define ORDER_TYPE      MockOrderType
  #define ORDER_SYMBOL    MockOrderSymbol
  #define ORDER_MAGIC     MockOrderMagicNumber
#else
  #define ORDERS_TOTAL    OrdersTotal
  #define ORDER_SELECT    OrderSelect
  #define ORDER_TYPE      OrderType
  #define ORDER_SYMBOL    OrderSymbol
  #define ORDER_MAGIC     OrderMagicNumber
#endif

// 测试文件中定义模拟订单数据结构和桩实现
#ifdef UNIT_TEST
  struct MockOrder { int type; string symbol; int magic; };
  MockOrder g_MockOrders[];
  int g_MockOrderCount  = 0;
  int g_MockCurrentIndex = -1;  // MockOrderSelect 写入，getter 读取

  int    MockOrdersTotal()                         { return g_MockOrderCount; }
  bool   MockOrderSelect(int i, int mode, int pool) {
           if(i < 0 || i >= g_MockOrderCount) return false;
           g_MockCurrentIndex = i;
           return true;
         }
  int    MockOrderType()        { return g_MockOrders[g_MockCurrentIndex].type; }
  string MockOrderSymbol()      { return g_MockOrders[g_MockCurrentIndex].symbol; }
  int    MockOrderMagicNumber() { return g_MockOrders[g_MockCurrentIndex].magic; }
#endif
```

**Test Cases**:
1. **Magic 硬编码探索**: 使用当前旧签名 `OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3)` 调用，断言 `g_LastOrderSendMagic == 12345`（在未修复代码上将失败，实际为 0）— 确认 bug 存在
2. **批量开仓 Magic 探索**: 调用当前旧签名 `OpenMultiplePositions(splits, 2, 1.1000, 1.0950, 3, tickets)`，期望 magic 来源为测试上下文常量 `TEST_MAGIC_NUMBER = 12345`（即调用方本应传入但当前无法传入的值），断言每笔 `g_LastOrderSendMagic == TEST_MAGIC_NUMBER`（未修复时失败，实际为 0）
3. **PositionManager 过滤探索**: 通过 `g_MockOrders[]` 注入两笔订单（magic=12345 和 magic=99999，symbol 均为当前品种），调用旧签名 `GetOpenPositions(positions)`（当前无 magic_number 参数），断言返回数量 == 1（未修复时返回 2，证明未按 magic 过滤）

**Expected Counterexamples**:
- `g_LastOrderSendMagic == 0`（而非调用方期望值），证明 magic 被硬编码忽略
- `GetOpenPositions` 返回数量 > 本 EA 订单数，证明未按 magic 过滤

### Fix Checking

**Goal**: 验证 bug condition 成立时，修复后函数（新签名）产生期望行为。

**注意**: 以下伪代码使用修复后的新签名 `OpenPosition(lots, entry, sl, tp, slippage, magic)`，与探索阶段的旧签名不同。

**Pseudocode:**
```
// 新签名：OpenPosition(double lots, double entry, double sl, double tp, int slippage, int magic)

FOR ALL magic IN [12345, 1, 99999, INT_MAX] DO
  g_OrderSendCallCount = 0
  g_LastOrderSendMagic = -1
  result := OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3, magic)  // 新签名，magic 为第 6 参数
  ASSERT g_LastOrderSendMagic == magic   // OrderSend wrapper 捕获的值
  ASSERT g_OrderSendCallCount >= 1
END FOR

FOR ALL magic IN [0, -1, -99999] DO
  g_OrderSendCallCount = 0
  result := OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3, magic)  // 新签名
  ASSERT result == -1
  ASSERT g_OrderSendCallCount == 0       // OrderSend wrapper 未被调用
END FOR
```

### Preservation Checking

**Goal**: 验证 magic > 0 时，修复后函数与原函数行为一致（除 magic 参数外）。

**注意**: `result_original` 使用旧签名（无 magic 参数），`result_fixed` 使用新签名（magic 作为第 6 参数），两者在相同 `OrderSend` 返回序列下结果应一致。

**Pseudocode:**
```
// 旧签名（未修复）：OpenPosition(double lots, double entry, double sl, double tp, int slippage)
// 新签名（修复后）：OpenPosition(double lots, double entry, double sl, double tp, int slippage, int magic)

FOR ALL (lots, entry, sl, tp, slippage, magic, error_sequence) WHERE magic > 0 DO
  // 注入相同的 OrderSend 返回序列
  SetOrderSendSequence(error_sequence)
  result_original := OpenPosition_original(lots, entry, sl, tp, slippage)

  SetOrderSendSequence(error_sequence)
  result_fixed := OpenPosition(lots, entry, sl, tp, slippage, magic)  // 新签名，magic > 0

  ASSERT result_original == result_fixed  // ticket 或 -1
  ASSERT retry_count_original == retry_count_fixed
END FOR
```

**Testing Approach**: 属性测试适合 Preservation Checking，因为可以生成大量随机 (lots, slippage, error_code) 组合，验证重试次数和返回值在修复前后一致。

**Test Cases**:
1. **重试行为保留**: mock `ORDER_SEND` 前两次返回 -1 且 `GET_LAST_ERROR` 返回 4（`IsRetryableError(4)` 为 true），第三次 `ORDER_SEND` 返回有效 ticket，验证修复后仍重试 3 次并返回 ticket
2. **不可重试错误保留**: mock `ORDER_SEND` 返回 -1 且 `GET_LAST_ERROR` 返回 130（`ERR_INVALID_STOPS`，`IsRetryableError(130)` 为 false），验证修复后仍立即返回 -1 不重试
3. **拆单遍历保留**: `split_count=3` 时，mock 第 2 笔失败，验证第 1、3 笔仍被尝试
4. **PositionManager 品种过滤保留**: 验证 `OrderSymbol() != Symbol()` 的订单仍被过滤掉

### Unit Tests

- `OpenPosition` 传入 `magic=0` 时返回 -1，不调用 `OrderSend`
- `OpenPosition` 传入 `magic=12345` 时，`OrderSend` 收到 `magic=12345`
- `OpenMultiplePositions` 将 magic 透传给每次 `OpenPosition` 调用
- `GetOpenPositions` 只返回 `OrderMagicNumber() == magic_number` 的订单
- `ValidateInputParameters` 在 `MagicNumber <= 0` 时返回 false

### Property-Based Tests

- 生成随机 `magic > 0` 值，验证 `OpenPosition` 传入 `OrderSend` 的 magic 始终等于输入值（Property 1）
- 生成随机 `magic <= 0` 值，验证 `OpenPosition` 始终返回 -1 且不调用 `OrderSend`（Property 2）
- 生成随机错误码序列，验证重试行为在修复前后一致（Property 3）
- 生成随机 magic 组合的订单列表，验证 `GetOpenPositions` 过滤结果的正确性（Property 4）

### Integration Tests

- EA 初始化时 `MagicNumber=0` 导致 `INIT_PARAMETERS_INCORRECT`
- EA 正常运行时，开出的所有订单 `OrderMagicNumber()` 均等于 `MagicNumber` 输入参数
- 两个 EA 实例使用不同 `MagicNumber` 并行运行，各自的 `PositionManager` 只管理自己的订单
- DryRun 模式下日志包含 `MagicNumber` 信息
