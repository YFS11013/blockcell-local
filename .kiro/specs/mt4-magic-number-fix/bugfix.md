# Bugfix Requirements Document

## Introduction

`OrderExecutor.mqh` 中的 `OpenPosition` 函数将 magic number 硬编码为 `int magic = 0`。
在 MT4 中，magic number 是区分不同 EA 订单来源的唯一标识符。
硬编码为 0 会导致：无法区分本 EA 开出的订单与其他 EA 或手动订单，持仓管理器可能误操作不属于本 EA 的订单，多 EA 并行运行时订单管理混乱。

修复目标：将 `magic` 作为参数传入 `OpenPosition`（及 `OpenMultiplePositions`），由调用方 `ForexStrategyExecutor.mq4` 通过 EA 输入参数控制。

## Bug Analysis

### Current Behavior (Defect)

1.1 WHEN `OpenPosition` 被调用时 THEN 系统使用硬编码的 `magic = 0` 作为 `OrderSend` 的魔术号参数，忽略调用方的意图

1.2 WHEN 多个 EA 同时运行时 THEN 系统无法通过 magic number 区分各 EA 的订单，因为所有订单的 magic number 均为 0

1.3 WHEN `OpenMultiplePositions` 被调用时 THEN 系统通过内部调用 `OpenPosition` 传递 `magic = 0`，调用方无法指定 magic number

### Expected Behavior (Correct)

2.1 WHEN `OpenPosition` 被调用时 THEN 系统 SHALL 使用调用方传入的 `magic` 参数作为 `OrderSend` 的魔术号

2.2 WHEN `OpenMultiplePositions` 被调用时 THEN 系统 SHALL 接受 `magic` 参数并将其传递给每次 `OpenPosition` 调用

2.3 WHEN `ForexStrategyExecutor.mq4` 调用开仓函数时 THEN 系统 SHALL 使用 EA 输入参数 `MagicNumber` 的值作为 magic number

2.4 WHEN `MagicNumber` 输入参数被传入时 THEN 系统 SHALL 要求其值必须 > 0；若传入值为 0，系统 SHALL 记录警告日志并拒绝开仓

2.5 WHEN 所有调用 `OpenPosition` 或 `OpenMultiplePositions` 的调用点被修改时 THEN 系统 SHALL 同步更新函数签名和传参，确保所有调用方均显式传入有效的 `magic` 参数

### Unchanged Behavior (Regression Prevention)

3.1 WHEN 非 DryRun 模式下 `OpenPosition` 成功开仓时 THEN 系统 SHALL CONTINUE TO 返回有效的订单号（ticket > 0）

3.2 WHEN `OpenPosition` 因网络或报价等运行时错误开仓失败时 THEN 系统 SHALL CONTINUE TO 执行重试逻辑（最多 3 次，间隔 1 秒）；WHEN 失败原因为参数非法（如 magic <= 0）时 THEN 系统 SHALL NOT 进入重试，直接返回失败

3.3 WHEN `OpenMultiplePositions` 被调用时 THEN 系统 SHALL CONTINUE TO 遍历拆单数组并为每笔订单调用 `OpenPosition`

3.4 WHEN 部分订单开仓失败时 THEN 系统 SHALL CONTINUE TO 继续尝试剩余订单，不因单笔失败而全部放弃

3.5 WHEN `DryRun` 模式启用时 THEN 系统 SHALL CONTINUE TO 仅记录日志，不执行真实 `OrderSend`

### New Behavior (Required by Fix)

4.1 WHEN 两个 EA 使用不同 `MagicNumber` 同时运行时 THEN `PositionManager` SHALL 仅管理与本 EA `MagicNumber` 匹配的订单，不干预其他 EA 的订单（当前 `PositionManager.mqh` 未按 magic 过滤，此为本次修复新增行为）
