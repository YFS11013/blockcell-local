# PositionManager 模块实现说明

## 概述

PositionManager（持仓管理器）模块负责跟踪所有持仓订单、监控订单状态、检测平仓事件，并触发交易结果记录。

## 实现的功能

### 1. 持仓扫描（任务 9.1）

#### `GetOpenPositions(int &positions[])`
- **功能**：扫描所有当前持仓订单
- **返回**：持仓订单数量
- **参数**：
  - `positions[]` - 输出数组，存储所有持仓订单的订单号
- **实现细节**：
  - 遍历所有订单（`OrdersTotal()`）
  - 过滤出当前品种的订单（`OrderSymbol() == Symbol()`）
  - 只处理市价单（`OP_BUY` 或 `OP_SELL`）
  - 排除挂单（`OP_BUYLIMIT`, `OP_SELLLIMIT` 等）

#### `GetOrderInfo(int ticket, OrderInfo &info)`
- **功能**：获取指定订单的详细信息
- **返回**：是否成功获取
- **参数**：
  - `ticket` - 订单号
  - `info` - 输出结构体，存储订单详细信息
- **信息包含**：
  - 订单号、开仓价格、止损、止盈
  - 手数、开仓时间、订单备注
  - 订单类型、当前盈亏

#### `GetPositionStats()`
- **功能**：获取持仓统计信息
- **返回**：`PositionStats` 结构体
- **统计内容**：
  - 总持仓数量
  - 总手数
  - 总盈利金额
  - 总亏损金额

### 2. 持仓状态检查（任务 9.2）

#### `CheckPositions()`
- **功能**：检查持仓状态，检测平仓事件
- **实现逻辑**：
  1. 获取当前所有持仓订单
  2. 遍历跟踪列表中的订单
  3. 检查每个订单是否仍然存在
  4. 如果订单已平仓：
     - 从历史订单中获取平仓信息
     - 记录交易结果到风险管理器（`RecordTradeResult`）
     - 记录平仓日志（`LogOrderClose`）
     - 从跟踪列表中移除订单
  5. 检查是否有新持仓需要加入跟踪列表
  6. 定期输出持仓统计报告（每小时一次）

#### `IsOrderExists(int ticket)`
- **功能**：检查订单是否仍然存在
- **返回**：订单是否存在
- **检查条件**：
  - 能否选中订单（`OrderSelect`）
  - 订单是否已关闭（`OrderCloseTime() == 0`）

#### `LogOrderClose(int ticket, double profit, double close_price, datetime close_time)`
- **功能**：记录订单平仓到日志
- **日志内容**：
  - 订单号
  - 平仓价格
  - 盈亏金额
  - 平仓时间
  - 决策标记（PROFIT 或 LOSS）

### 3. 订单跟踪管理

#### `InitPositionManager()`
- **功能**：初始化持仓管理器
- **实现**：
  - 初始化跟踪列表
  - 扫描现有持仓并加入跟踪列表
  - 记录初始化日志

#### `AddToTrackedOrders(int ticket)`
- **功能**：添加订单到跟踪列表
- **检查**：避免重复添加

#### `RemoveFromTrackedOrders(int ticket)`
- **功能**：从跟踪列表中移除订单
- **实现**：重建数组，排除指定订单

#### `CleanupPositionManager()`
- **功能**：清理持仓管理器资源
- **实现**：清空跟踪列表

## 数据结构

### `PositionStats`
```mql4
struct PositionStats {
    int total_positions;      // 总持仓数
    double total_lots;        // 总手数
    double total_profit;      // 总盈利
    double total_loss;        // 总亏损
};
```

### `OrderInfo`
```mql4
struct OrderInfo {
    int ticket;               // 订单号
    double open_price;        // 开仓价格
    double stop_loss;         // 止损价格
    double take_profit;       // 止盈价格
    double lots;              // 手数
    datetime open_time;       // 开仓时间
    double actual_slippage;   // 实际滑点
    string comment;           // 订单备注
    int cmd;                  // 订单类型
    double current_profit;    // 当前盈亏
};
```

## 全局变量

### `g_TrackedOrders[]`
- **类型**：`int[]`
- **用途**：存储所有正在跟踪的订单号
- **维护**：
  - 初始化时加载现有持仓
  - 检测到新持仓时添加
  - 检测到平仓时移除

## 与其他模块的集成

### 与 RiskManager 的集成
- 调用 `RecordTradeResult(ticket, profit)` 记录交易结果
- 用于更新日亏损和连续亏损计数器

### 与 Logger 的集成
- 使用 `LogInfo`, `LogWarn`, `LogDebug` 记录各种事件
- 记录持仓扫描、平仓事件、统计报告

### 与主 EA 的集成
- 在 `OnInit()` 中调用 `InitPositionManager()`
- 在 `OnTick()` 中调用 `CheckPositions()`（通过包装函数）
- 在 `OnDeinit()` 中调用 `CleanupPositionManager()`

## 使用示例

### 初始化
```mql4
int OnInit() {
    InitPositionManager();
    return INIT_SUCCEEDED;
}
```

### 检查持仓
```mql4
void OnTick() {
    CheckPositions();
}
```

### 获取持仓统计
```mql4
PositionStats stats = GetPositionStats();
Print("当前持仓数: ", stats.total_positions);
Print("总手数: ", stats.total_lots);
Print("净盈亏: ", stats.total_profit + stats.total_loss);
```

### 清理资源
```mql4
void OnDeinit(const int reason) {
    CleanupPositionManager();
}
```

## 设计考虑

### 1. 平仓检测机制
- 使用跟踪列表记录所有持仓订单
- 每个 Tick 检查跟踪列表中的订单是否仍然存在
- 通过 `OrderCloseTime()` 判断订单是否已平仓

### 2. 新持仓检测
- 每次检查时扫描当前所有持仓
- 与跟踪列表对比，发现新持仓时自动加入跟踪

### 3. 性能优化
- 持仓统计报告每小时输出一次，避免频繁日志
- 使用静态变量 `last_stats_time` 记录上次输出时间

### 4. 错误处理
- `OrderSelect` 失败时记录警告日志
- 无法获取历史订单信息时记录警告

### 5. 日志记录
- 盈利订单使用 `LogInfo`
- 亏损订单使用 `LogWarn`
- 调试信息使用 `LogDebug`

## 注意事项

1. **函数命名冲突**：
   - 主 EA 文件中使用 `CheckPositionsWrapper()` 包装函数
   - 避免与 PositionManager.mqh 中的 `CheckPositions()` 冲突

2. **订单类型过滤**：
   - 只处理市价单（`OP_BUY`, `OP_SELL`）
   - 不处理挂单（`OP_BUYLIMIT`, `OP_SELLLIMIT` 等）

3. **品种过滤**：
   - 只处理当前图表品种的订单
   - 避免处理其他品种的订单

4. **历史订单访问**：
   - 平仓后需要从历史订单中获取信息
   - 使用 `OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY)`

5. **数组操作**：
   - 修改跟踪列表时需要重建数组
   - 删除元素后需要调整循环索引

## 测试建议

1. **单元测试**：
   - 测试 `GetOpenPositions()` 能否正确扫描持仓
   - 测试 `IsOrderExists()` 能否正确判断订单状态
   - 测试 `AddToTrackedOrders()` 和 `RemoveFromTrackedOrders()` 的正确性

2. **集成测试**：
   - 测试开仓后订单是否自动加入跟踪列表
   - 测试平仓后是否正确触发交易结果记录
   - 测试持仓统计是否准确

3. **边缘情况**：
   - 测试无持仓时的行为
   - 测试多个订单同时平仓的情况
   - 测试 EA 重启后能否正确恢复跟踪列表

## 未来改进

1. **持久化跟踪列表**：
   - 将跟踪列表保存到文件
   - EA 重启后恢复跟踪列表

2. **部分平仓支持**：
   - 检测部分平仓事件
   - 记录部分平仓的盈亏

3. **订单分组**：
   - 按参数版本分组订单
   - 统计每个参数版本的表现

4. **实时盈亏监控**：
   - 监控浮动盈亏
   - 触发预警（如浮亏超过阈值）

## 相关文档

- 设计文档：`.kiro/specs/mt4-forex-strategy-executor/design.md` - Position Manager 章节
- 需求文档：`.kiro/specs/mt4-forex-strategy-executor/requirements.md`
- 任务文档：`.kiro/specs/mt4-forex-strategy-executor/tasks.md` - 任务 9

## 版本历史

- V1.0.0 (2025-03-09)：初始实现
  - 实现持仓扫描功能
  - 实现持仓状态检查功能
  - 实现订单跟踪管理
