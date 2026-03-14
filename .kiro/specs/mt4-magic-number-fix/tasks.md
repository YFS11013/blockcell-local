# Implementation Plan

- [x] 1. 编写 Bug Condition 探索性测试（在未修复代码上运行）
  - **Property 1: Bug Condition** - Magic Number 硬编码为 0
  - **CRITICAL**: 此测试 MUST 在未修复代码上 FAIL — 失败即证明 bug 存在
  - **DO NOT** 在测试失败时修改代码或测试本身
  - **GOAL**: 暴露反例，确认根因分析正确
  - **Scoped PBT 方案**: 针对确定性 bug，将属性范围限定在具体失败场景以确保可复现
  - 在 `OrderExecutor.mqh` 顶部添加 `#ifdef UNIT_TEST` 宏重定向：`#define ORDER_SEND MockOrderSend`（生产代码中展开为内建 `OrderSend`）
  - 在 `PositionManager.mqh` 顶部添加宏重定向：`ORDERS_TOTAL`/`ORDER_SELECT`/`ORDER_TYPE`/`ORDER_SYMBOL`/`ORDER_MAGIC`
  - 创建测试文件 `domain_experts/forex/ea/tests/TestMagicNumberBug.mq4`，定义 `MockOrderSend`（捕获 `g_LastOrderSendMagic`）和 `MockOrder` 结构体
  - 测试用例 1：调用旧签名 `OpenPosition(0.1, 1.1000, 1.0950, 1.1100, 3)`，断言 `g_LastOrderSendMagic == 12345`（未修复时实际为 0，测试 FAIL）
  - 测试用例 2：调用旧签名 `OpenMultiplePositions(splits, 2, 1.1000, 1.0950, 3, tickets)`，断言每笔 `g_LastOrderSendMagic == 12345`（未修复时实际为 0，测试 FAIL）
  - 测试用例 3：注入两笔订单（magic=12345 和 magic=99999，symbol 均为当前品种），调用旧签名 `GetOpenPositions(positions)`，断言返回数量 == 1（未修复时返回 2，测试 FAIL）
  - 在未修复代码上运行测试，**预期结果：FAIL**（这是正确的，证明 bug 存在）
  - 记录反例：`g_LastOrderSendMagic == 0`（而非 12345），`GetOpenPositions` 返回 2（而非 1）
  - 任务完成条件：测试已编写、已运行、失败已记录
  - _Requirements: 1.1, 1.2, 1.3_

- [x] 2. 编写 Preservation 属性测试（在未修复代码上运行，BEFORE 实现修复）
  - **Property 2: Preservation** - 重试逻辑、拆单遍历、DryRun 行为不变
  - **IMPORTANT**: 遵循 observation-first 方法论
  - 观察：在未修复代码上，`magic > 0` 路径不存在（旧签名无 magic 参数），因此观察重试/拆单/DryRun 行为
  - 观察：mock `ORDER_SEND` 前两次返回 -1，同时 `GET_LAST_ERROR` 返回 4（`IsRetryableError(4)` 为 true），第三次 `ORDER_SEND` 返回有效 ticket（> 0），验证重试 3 次后成功（注意：`OpenPosition` 以 `ticket > 0` 判成功，不能直接返回错误码作为 ticket）
  - 观察：`split_count=3` 时第 2 笔失败，第 1、3 笔仍被尝试（`g_OrderSendCallCount == 3`）
  - 观察：DryRun 模式下 `g_OrderSendCallCount == 0`
  - 观察：`OrderSymbol() != Symbol()` 的订单被 `GetOpenPositions` 过滤掉
  - 编写属性测试：对所有 `(lots, slippage, error_sequence)` 组合，验证重试次数和返回值与观察一致
  - 在未修复代码上运行测试，**预期结果：PASS**（确认基线行为）
  - 任务完成条件：测试已编写、已运行、在未修复代码上全部通过
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

- [x] 3. 修复 Magic Number 硬编码 bug

  - [x] 3.1 修复 `OrderExecutor.mqh`
    - 修改 `OpenPosition` 函数签名：增加 `int magic` 参数（第 6 个参数）
    - 在函数入口处增加校验：`if(magic <= 0) { Print("WARN: OpenPosition called with invalid magic=", magic, ", rejecting"); return -1; }`
    - 删除函数体内 `int magic = 0;` 硬编码局部变量
    - 将 `ORDER_SEND(..., magic, ...)` 中的 magic 改为使用传入参数
    - 修改 `OpenMultiplePositions` 函数签名：增加 `int magic` 参数（最后一个参数）
    - 在 `OpenMultiplePositions` 内部调用 `OpenPosition` 时透传 `magic` 参数
    - _Bug_Condition: isBugCondition(ctx) where ctx.actual_magic_sent_to_OrderSend == 0 AND ctx.caller_intended_magic != 0_
    - _Expected_Behavior: g_LastOrderSendMagic == caller_intended_magic; magic <= 0 时 return -1 且 g_OrderSendCallCount == 0_
    - _Preservation: 重试逻辑（最多 3 次，间隔 1 秒）、拆单遍历、DryRun 行为、成功返回 ticket > 0 均不变_
    - _Requirements: 2.1, 2.2, 2.4, 3.1, 3.2, 3.3, 3.4, 3.5_

  - [x] 3.2 修复 `PositionManager.mqh`
    - 在模块顶部声明全局变量 `int g_MagicNumber = 0;`
    - 修改 `InitPositionManager` 函数签名：增加 `int magic_number` 参数，函数体内设置 `g_MagicNumber = magic_number`
    - 修改 `GetOpenPositions` 函数签名：增加 `int magic_number` 参数
    - 在现有 `OrderSymbol() != Symbol()` 过滤之后，增加 `if(ORDER_MAGIC() != magic_number) continue;`
    - 更新所有内部调用 `GetOpenPositions` 的地方（`CheckPositions`、`GetPositionStats` 等）传入 `g_MagicNumber`
    - _Bug_Condition: GetOpenPositions 未按 magic 过滤，返回其他 EA 的订单_
    - _Expected_Behavior: GetOpenPositions 仅返回 OrderMagicNumber() == magic_number 的订单_
    - _Preservation: OrderSymbol() != Symbol() 的过滤逻辑不变_
    - _Requirements: 4.1_

  - [x] 3.3 修复 `ForexStrategyExecutor.mq4`
    - 在输入参数区块增加：`input int MagicNumber = 12345; // EA 魔术号（必须 > 0，用于区分本 EA 订单）`
    - 在 `ValidateInputParameters` 中增加：`if(MagicNumber <= 0) { Print("ERROR: MagicNumber must be > 0, got ", MagicNumber); return false; }`
    - 将 `InitPositionManager()` 调用改为 `InitPositionManager(MagicNumber)`
    - 在 `ExecutePendingSignal` 中，`OpenMultiplePositions` 调用点增加 `MagicNumber` 参数
    - DryRun 分支日志中增加 `MagicNumber` 信息（如 `"DryRun: MagicNumber=", MagicNumber`）
    - _Requirements: 2.3, 2.4, 2.5_

  - [x] 3.4 验证 Bug Condition 探索测试现在通过
    - **Property 1: Expected Behavior** - Magic Number 正确透传
    - **IMPORTANT**: 重新运行任务 1 中的 SAME 测试，不要编写新测试
    - 任务 1 的测试已编码了期望行为，通过即证明 bug 已修复
    - 运行 `TestMagicNumberBug.mq4` 中的 Bug Condition 测试用例
    - **预期结果：PASS**（确认 bug 已修复）
    - _Requirements: 2.1, 2.2, 2.3, 2.4_

  - [x] 3.5 验证 Preservation 测试仍然通过
    - **Property 2: Preservation** - 重试逻辑、拆单遍历、DryRun 行为不变
    - **IMPORTANT**: 重新运行任务 2 中的 SAME 测试，不要编写新测试
    - 运行 `TestMagicNumberBug.mq4` 中的 Preservation 测试用例
    - **预期结果：PASS**（确认无回归）
    - 确认所有 Preservation 测试在修复后仍通过

- [x] 4. Checkpoint — 确保所有测试通过
  - 运行全部测试（Bug Condition 探索测试 + Preservation 测试）
  - 确认 Bug Condition 测试（任务 1）在修复后 PASS
  - 确认 Preservation 测试（任务 2）在修复后仍 PASS
  - 检查 UNIT_TEST 宏严格隔离，不污染生产构建（生产代码中 `#ifdef UNIT_TEST` 块不被编译）
  - 集成验证：确认双 EA 不同 MagicNumber 并行场景下各自只管理自己的订单
  - 如有疑问，询问用户后再继续
