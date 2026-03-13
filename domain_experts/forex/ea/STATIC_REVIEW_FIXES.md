# MT4 EA 静态复审缺陷修复报告

## 文档状态

- 用途：保留 Task 11.5~11.7 多轮复审过程记录
- 维护状态：历史归档（含部分已替代设计说明，用于审计追溯）
- 当前结论：相关修复已在 Task 15 最终验收中收口

## 修复日期
2026-03-10

## 修复概述
本次修复解决了函数调用参数顺序错误和返回值类型误用问题，这两个问题都会导致实盘行为失真和日志误报。

## 修复详情（第四轮）

### 1. OpenMultiplePositions 调用参数顺序修复（High 优先级）

**问题描述：**
- 调用 OpenMultiplePositions 时参数顺序完全错乱
- 导致拆单数量异常（常变成 1 单）且止损价格错误（例如 10.0）

**根本原因：**
- 函数签名：`OpenMultiplePositions(splits[], split_count, entry, stop_loss, slippage, tickets[])`
- 错误调用：`OpenMultiplePositions(splits, entry_price, stop_loss, slippage, tp_count, tickets)`
- 参数映射错误：
  - entry_price (1.1680) → split_count (期望 int) → 拆单数量变成 1
  - stop_loss (1.1720) → entry (期望 double) → 入场价变成止损价
  - slippage (10) → stop_loss (期望 double) → 止损价变成 10.0
  - tp_count (3) → slippage (期望 int) → 滑点变成 3

**解决方案：**
```mql4
// 修正参数顺序
int success_count = OpenMultiplePositions(
    splits,                              // LotSplit[] - 拆单数组
    tp_count,                            // int - 拆单数量
    signal.entry_price,                  // double - 入场价
    signal.stop_loss,                    // double - 止损价
    (int)params.max_slippage_points,     // int - 最大滑点
    tickets                              // int[] - 订单号数组（输出）
);
```

**修改文件：**
- `domain_experts/forex/ea/ForexStrategyExecutor.mq4` (行 399)

**验证需求：**
- 需求 2.9：拆单逻辑正确
- 需求 2.12：止盈价格对应正确

---

### 2. 返回值类型误用修复（Medium 优先级）

**问题描述：**
- OpenMultiplePositions 返回 int（成功订单数量）
- 调用方用 bool all_success 接收
- 导致日志误报：只要有一个订单成功就报告"全部成功"

**根本原因：**
- 返回值定义：`int OpenMultiplePositions(...)` 返回成功订单数
- 误用：`bool all_success = OpenMultiplePositions(...)`
- 隐式转换：int → bool，任何非零值都是 true

**解决方案：**
```mql4
int success_count = OpenMultiplePositions(...);

if(success_count == tp_count) {
    LogInfo("EA", "成功开仓 N 个订单（全部成功）");
    // 记录所有订单详情
} else if(success_count > 0) {
    LogWarn("EA", "部分开仓成功: M/N 订单");
    // 区分成功和失败的订单
} else {
    LogError("EA", "所有订单开仓失败");
}
```

**修改文件：**
- `domain_experts/forex/ea/ForexStrategyExecutor.mq4` (行 399-413)

**验证需求：**
- 需求 5.2：日志记录准确性

---

## 已确认修复通过（前三轮）

- ✅ Signal_K 时序：采用立即执行模式
- ✅ news_blackout 校验：添加 start < end 验证
- ✅ OnDeinit 日志顺序：先写后关
- ✅ 定时参数更新：加载失败时切换 Safe_Mode

---

**问题描述：**
- 第二轮修复后，执行时机问题仍未完全解决
- 缓存-延迟执行模式导致信号延迟一根 K 线
- K 线 N 的信号在 K 线 N+1 收盘时执行，而不是 K 线 N+1 开盘时

**根本原因：**
- 采用了"评估-缓存-延迟执行"的模式
- 在 K 线 N 收盘时评估并缓存信号
- 在 K 线 N+1 收盘时（下一个 isNewBar）执行缓存的信号
- MT4 的 isNewBar 在新 K 线首 tick 触发，此时应该立即执行，而不是等待下一个 isNewBar

**解决方案：**
- 废弃缓存-延迟执行模式：
  - 删除 `g_PendingSignal` 和 `g_CachedSignal` 全局变量
  - 删除 `EvaluateEntrySignal()` 和 `ExecutePendingSignal()` 函数
- 创建 `EvaluateAndExecuteSignal()` 函数：
  - 在 isNewBar 时调用
  - 评估 Time[1]（刚收盘的 K 线）
  - 如果满足条件，立即执行开仓
- 确保"Signal_K 收盘后下一根 K 线首 tick 执行"的正确时序

**修改文件：**
- `domain_experts/forex/ea/ForexStrategyExecutor.mq4` (行 55-56, 186-192, 300-410)

**验证需求：**
- 需求 2.7：信号评估与执行时机正确

---

### 2. 定时参数更新时的 Safe_Mode 切换（Medium 优先级）

**问题描述：**
- `CheckParameterUpdate()` 加载失败时不会切换状态
- 违反需求 4.10：可选字段解析失败应进入 Safe_Mode

**根本原因：**
- `CheckParameterUpdate()` 只记录日志，未检查参数有效性
- 未在参数无效时切换到 Safe_Mode

**解决方案：**
- 在 `CheckParameterUpdate()` 中：
  - 加载成功后检查参数有效性
  - 加载失败时检查当前参数是否仍有效
  - 无效时切换到 Safe_Mode

**修改文件：**
- `domain_experts/forex/ea/ForexStrategyExecutor.mq4` (行 285-302)

**验证需求：**
- 需求 1.5：参数无效时进入 Safe_Mode
- 需求 4.10：可选字段解析失败应进入 Safe_Mode

---

### 3. news_blackout 时间窗口校验（Medium 优先级）

**状态：** ✅ 已在第二轮修复中完成

**问题描述：**
- 解析时未验证 `start < end`
- 可能导致配置错误的时间窗口被接受，但过滤永远不触发（静默失效）

**解决方案：**
- 在 `ParseNewsBlackout()` 中添加校验：
  ```mql4
  if(params.news_blackouts[obj_count].start >= params.news_blackouts[obj_count].end) {
      params.error_message = "news_blackout 时间窗口无效: start >= end";
      return false;
  }
  ```

**修改文件：**
- `domain_experts/forex/ea/include/ParameterLoader.mqh` (行 539-545)

---

## 设计变更

### 从缓存-延迟执行到立即执行

**旧设计（已废弃）：**
```
K 线 N 收盘 (isNewBar):
  1. 评估 Time[1] (K 线 N)
  2. 缓存信号到 g_CachedSignal
  3. 设置 g_PendingSignal = true

K 线 N+1 收盘 (isNewBar):
  1. 执行 g_CachedSignal
  2. 评估 Time[1] (K 线 N+1)
  
问题：K 线 N 的信号在 K 线 N+1 收盘时执行（延迟一根 K 线）
```

**新设计（当前）：**
```
K 线 N 收盘 (isNewBar):
  1. 评估 Time[1] (K 线 N)
  2. 如果满足条件，立即执行开仓
  
结果：K 线 N 的信号在 K 线 N+1 首 tick 执行（正确）
```

### MT4 K 线机制理解

- `isNewBar` 在新 K 线的首个 tick 时触发
- 此时 Time[0] = 新 K 线，Time[1] = 刚收盘的 K 线
- 这正是"下一根 K 线首 tick"的时机
- 不需要额外的延迟或缓存机制

---

## 测试建议

### 1. Signal_K 执行时机测试
- 准备测试参数包
- 在 MT4 Strategy Tester 中运行
- 验证日志中的时间戳：
  - "检测到有效信号" 的时间应该是 K 线 N 收盘时
  - "执行待开仓信号" 的时间应该是 K 线 N+1 开盘时
  - 两者相差应该是一根 K 线的时间间隔（H4 = 4 小时）

### 2. 缓存信号数据一致性测试
- 准备两个参数包，TP 配置不同
- 在信号评估后、执行前更新参数包
- 验证执行时使用的是旧参数包的 TP 配置

### 3. news_blackout 校验测试
- 准备一个 `start >= end` 的参数包
- 验证 EA 拒绝加载并记录错误日志

---

## 文档更新

已更新以下文档：
- ✅ `.kiro/specs/mt4-forex-strategy-executor/tasks.md` - 添加任务 11.6
- ✅ `Docs/lessons.md` - 记录经验教训
- ✅ `domain_experts/forex/ea/STATIC_REVIEW_FIXES.md` - 本文档

---

## 经验教训

1. **执行顺序的重要性**：在事件驱动系统中，操作顺序直接影响业务逻辑的正确性
2. **数据一致性**：缓存数据必须完整，执行阶段不得混用缓存数据和当前数据
3. **配置校验的完整性**：不仅要校验格式，还要校验业务逻辑
4. **多轮审查的必要性**：第一轮修复可能引入新问题或遗漏细节

---

## 复审状态

- ✅ 第一轮静态审查（2026-03-10）：3 个缺陷已修复
- ✅ 第二轮静态复审（2026-03-10）：3 个新缺陷已修复
- ✅ 第三轮静态复审（2026-03-10）：执行时机问题彻底解决，采用新设计
- ✅ 第四轮静态复审（2026-03-10）：函数调用参数顺序和返回值类型问题已修复
- ✅ 已完成最终验收收口（Task 15，2026-03-11）

---

## 关键修复总结

### 第四轮修复（最新）
1. **参数顺序错误**：修正 OpenMultiplePositions 调用参数顺序，避免实盘行为失真
2. **返回值误用**：正确处理 int 返回值，避免日志误报

### 第三轮修复
1. **执行时机**：废弃缓存-延迟模式，采用立即执行模式
2. **Safe_Mode 切换**：定时参数更新时检查有效性

### 第二轮修复
1. **TP 数据一致性**：执行时使用缓存信号中的 TP 数据
2. **时间窗口校验**：添加 start < end 验证

### 第一轮修复
1. **信号缓存**：添加信号快照缓存机制
2. **可选字段解析**：实现 news_blackout/session_filter 解析
3. **日志顺序**：修正 OnDeinit 日志关闭顺序

---

## 签名

修复完成时间：2026-03-10（第四轮）
修复人：Kiro AI Assistant
复审结论：已在 Task 15 归档收口
