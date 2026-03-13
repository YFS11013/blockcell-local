# TimeFilter.mqh - 时间过滤器模块

## 概述

时间过滤器模块负责管理交易时间限制，包括新闻事件禁开仓窗口和交易时段过滤。所有时间判断都基于 UTC 时区。

## 功能

### 1. 新闻窗口过滤

检查当前时间是否在新闻禁开仓窗口内。

**函数签名：**
```mql4
bool IsInNewsBlackout(NewsBlackout &blackouts[], int blackout_count)
```

**参数：**
- `blackouts` - 新闻禁开仓窗口数组
- `blackout_count` - 窗口数量

**返回值：**
- `true` - 当前时间在禁开仓窗口内
- `false` - 当前时间不在窗口内

**特性：**
- 使用 UTC 时间判断
- 支持配置多个时间窗口
- 正确处理窗口重叠情况
- 只要在任一窗口内，就返回 true
- 如果没有配置窗口（count = 0），返回 false

**示例：**
```mql4
NewsBlackout blackouts[2];

// 配置窗口 1：美国 CPI 数据发布
blackouts[0].start = ParseISO8601("2025-03-09T13:30:00Z");
blackouts[0].end = ParseISO8601("2025-03-09T14:30:00Z");
blackouts[0].reason = "US CPI Data Release";

// 配置窗口 2：欧洲央行利率决议
blackouts[1].start = ParseISO8601("2025-03-10T12:45:00Z");
blackouts[1].end = ParseISO8601("2025-03-10T14:00:00Z");
blackouts[1].reason = "ECB Interest Rate Decision";

// 检查当前时间
if(IsInNewsBlackout(blackouts, 2)) {
    Print("当前时间在新闻禁开仓窗口内，禁止开仓");
}
```

### 2. 交易时段过滤

检查当前时间是否在允许的交易时段内。

**函数签名：**
```mql4
bool IsInTradingSession(SessionFilter &filter)
```

**参数：**
- `filter` - 交易时段过滤配置

**返回值：**
- `true` - 当前时间在允许的交易时段内
- `false` - 当前时间不在允许的时段内

**特性：**
- 使用 UTC 时间判断
- 如果 `filter.enabled = false`，直接返回 true
- 检查当前小时是否在 `allowed_hours_utc` 数组中
- 如果未配置允许的小时（count = 0），返回 false（保守策略）

**示例：**
```mql4
SessionFilter filter;
filter.enabled = true;
filter.allowed_count = 9;

// 配置允许的小时（8:00-16:59 UTC）
for(int i = 0; i < 9; i++) {
    filter.allowed_hours_utc[i] = 8 + i;  // 8, 9, 10, ..., 16
}

// 检查当前时间
if(!IsInTradingSession(filter)) {
    Print("当前时间不在允许的交易时段内，禁止开仓");
}
```

### 3. 综合时间过滤

综合检查新闻窗口和交易时段，判断是否允许开仓。

**函数签名：**
```mql4
bool CanOpenByTimeFilter(ParameterPack &params)
```

**参数：**
- `params` - 参数包（包含新闻窗口和交易时段配置）

**返回值：**
- `true` - 允许开仓
- `false` - 禁止开仓

**逻辑：**
1. 检查新闻窗口：如果在窗口内，返回 false
2. 检查交易时段：如果不在允许的时段内，返回 false
3. 所有条件都满足，返回 true

**示例：**
```mql4
ParameterPack params = GetCurrentParameters();

if(!CanOpenByTimeFilter(params)) {
    Print("时间过滤条件不满足，禁止开仓");
    return;
}

// 继续评估其他入场条件...
```

## 数据结构

### NewsBlackout

新闻禁开仓窗口结构。

```mql4
struct NewsBlackout {
    datetime start;      // 窗口开始时间（UTC）
    datetime end;        // 窗口结束时间（UTC）
    string reason;       // 事件原因说明
};
```

### SessionFilter

交易时段过滤配置。

```mql4
struct SessionFilter {
    bool enabled;                // 是否启用时段过滤
    int allowed_hours_utc[24];   // 允许交易的 UTC 小时数组
    int allowed_count;           // 允许小时的数量
};
```

## 时间处理

### UTC 时间转换

所有时间判断都基于 UTC 时区。模块使用 `TimeUtils.mqh` 中的 `GetCurrentUTC()` 函数获取当前 UTC 时间。

```mql4
datetime current_utc = GetCurrentUTC();
```

该函数内部优先使用自动探测的服务器 UTC 偏移，探测失败时回退全局输入参数 `ServerUTCOffset`：

```mql4
datetime ConvertToUTC(datetime server_time) {
    return server_time - GetEffectiveUTCOffsetSeconds();
}
```

### 时间窗口判断

判断当前时间是否在窗口内：

```mql4
if(current_utc >= window.start && current_utc <= window.end) {
    // 在窗口内
}
```

### 小时判断

判断当前小时是否在允许的小时数组中：

```mql4
int current_hour = TimeHour(current_utc);
for(int i = 0; i < allowed_count; i++) {
    if(current_hour == allowed_hours_utc[i]) {
        // 在允许的时段内
    }
}
```

## 日志记录

模块会记录以下日志：

### 新闻窗口日志

当检测到在新闻窗口内时：

```
INFO: [TimeFilter] 当前时间在新闻禁开仓窗口内
  当前 UTC 时间: 2025-03-09 13:45:00
  窗口开始: 2025-03-09 13:30:00
  窗口结束: 2025-03-09 14:30:00
  原因: US CPI Data Release
```

### 交易时段日志

当检测到不在允许的时段内时：

```
INFO: [TimeFilter] 当前时间不在允许的交易时段内
  当前 UTC 时间: 2025-03-09 18:30:00
  当前 UTC 小时: 18
```

### 综合过滤日志

当时间过滤条件不满足时：

```
WARN: [TimeFilter] 拒绝开仓 - 在新闻禁开仓窗口内
```

或

```
WARN: [TimeFilter] 拒绝开仓 - 不在允许的交易时段内
```

## 测试

模块提供了测试函数 `TestTimeFilter()`，可以在 EA 初始化时调用：

```mql4
int OnInit() {
    // 测试时间过滤器
    TestTimeFilter();
    
    // 其他初始化代码...
    return INIT_SUCCEEDED;
}
```

测试内容包括：
1. 新闻窗口过滤（包括重叠窗口和空数组）
2. 交易时段过滤（包括启用/禁用状态）
3. 综合时间过滤

## 使用场景

### 场景 1：重大新闻事件期间禁止开仓

```mql4
// 在参数包中配置新闻窗口
params.blackout_count = 1;
params.news_blackouts[0].start = ParseISO8601("2025-03-09T13:30:00Z");
params.news_blackouts[0].end = ParseISO8601("2025-03-09T14:30:00Z");
params.news_blackouts[0].reason = "US CPI Data Release";

// 在评估入场信号前检查
if(IsInNewsBlackout(params.news_blackouts, params.blackout_count)) {
    Print("拒绝开仓 - 在新闻禁开仓窗口内");
    return;
}
```

### 场景 2：只在活跃时段交易

```mql4
// 配置交易时段（欧洲和美国重叠时段）
params.session_filter.enabled = true;
params.session_filter.allowed_count = 9;
for(int i = 0; i < 9; i++) {
    params.session_filter.allowed_hours_utc[i] = 8 + i;  // 8:00-16:59 UTC
}

// 在评估入场信号前检查
if(!IsInTradingSession(params.session_filter)) {
    Print("拒绝开仓 - 不在允许的交易时段内");
    return;
}
```

### 场景 3：综合时间过滤

```mql4
// 在 OnTick 中评估入场信号前
if(!CanOpenByTimeFilter(params)) {
    // 时间过滤条件不满足，跳过本次评估
    return;
}

// 继续评估其他入场条件
SignalResult signal = EvaluateEntrySignal(params);
// ...
```

## 注意事项

1. **UTC 时区**：所有时间判断都基于 UTC，建议启用 `AutoDetectUTCOffset=true`，并把 `ServerUTCOffset` 作为回退值维护正确
2. **窗口重叠**：模块正确处理多个窗口重叠的情况，只要在任一窗口内就禁止开仓
3. **保守策略**：如果配置异常（如启用时段过滤但未配置允许的小时），采用保守策略（禁止开仓）
4. **小时粒度**：交易时段过滤的粒度是小时，例如配置小时 8 表示 8:00:00 - 8:59:59
5. **边界条件**：窗口判断使用 `>=` 和 `<=`，包含边界时间点

## 依赖

- `TimeUtils.mqh` - 时间工具模块（UTC 转换、ISO 8601 解析）
- `ParameterLoader.mqh` - 参数加载器模块（数据结构定义）

## 验证需求

该模块实现了以下需求：

- **需求 4.1**：新闻窗口过滤
- **需求 4.2**：交易时段过滤
- **需求 4.3**：多窗口重叠处理
- **需求 4.4**：窗口结束后自动恢复
- **需求 4.5**：支持配置多个新闻窗口

## 设计属性

该模块验证了以下设计属性：

- **属性 18**：新闻窗口过滤 - 对于任意当前时间和 news_blackout 窗口数组，如果当前时间在任一窗口内，则系统应禁止开新仓
- **属性 19**：交易时段过滤 - 对于任意当前时间和 session_filter，如果 session_filter.enabled = true 且当前小时不在 allowed_hours_utc 中，则系统应禁止开新仓
- **属性 20**：多窗口重叠处理 - 对于任意多个重叠的 news_blackout 窗口，系统应识别所有窗口并在任一窗口内禁止开仓

## 版本历史

- **v1.0** (2025-03-09)
  - 初始版本
  - 实现新闻窗口过滤
  - 实现交易时段过滤
  - 实现综合时间过滤
  - 添加测试函数
