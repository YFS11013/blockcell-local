# EA 主循环集成实现总结

## 文档状态

- 用途：保留 Task 10 阶段实现快照（过程文档）
- 维护状态：历史归档（非当前行为基准）
- 对齐状态：已按当前代码路径更新关键时序描述（2026-03-12）

## 概述

本文档总结了任务 10（EA 主循环集成）的实现情况。该任务将所有已实现的模块集成到主 EA 文件中，实现完整的交易执行流程。

## 实现的子任务

### 10.1 实现 OnInit 初始化 ✅

**实现内容：**
- 验证输入参数（日志级别、参数检查间隔、服务器 UTC 偏移）
- 确定参数文件路径（支持自定义路径或默认路径）
- 初始化日志系统
- 初始化持仓管理器
- 初始化风险管理器
- 记录配置信息
- 初始化 K 线跟踪
- V1 固定品种和周期校验（EURUSD H4）
- 加载参数包
- 根据参数加载结果设置 EA 状态（RUNNING 或 SAFE_MODE）

**关键代码：**
```mql4
int OnInit()
{
    // 验证输入参数
    if(!ValidateInputParameters()) {
        return INIT_PARAMETERS_INCORRECT;
    }
    
    // 初始化各模块
    InitLogger(LogLevel);
    InitPositionManager();
    InitRiskState();
    
    // V1 固定品种和周期校验
    if(Symbol() != "EURUSD" || Period() != PERIOD_H4) {
        return INIT_FAILED;
    }
    
    // 加载参数包
    if(!LoadParameterPack(param_file_path)) {
        g_CurrentState = STATE_SAFE_MODE;
    } else {
        g_CurrentState = STATE_RUNNING;
    }
    
    return INIT_SUCCEEDED;
}
```

### 10.2 实现 OnTick 主逻辑 ✅

**实现内容：**
- 检测 K 线变化（通过比较 Time[0] 和 g_LastBarTime）
- 定期检查参数更新（根据 ParamCheckInterval）
- 根据 EA 状态执行相应逻辑：
  - **RUNNING 状态**：
    - 在新 K 线首 tick 评估刚收盘 K 线（Time[1]）
    - 信号有效时在同一轮立即执行开仓（无待执行缓存队列）
    - 检查持仓状态
  - **SAFE_MODE 状态**：
    - 只管理持仓，不开新仓
    - 定期尝试恢复到 RUNNING 状态

**关键代码：**
```mql4
void OnTick()
{
    // 检测新 K 线
    bool isNewBar = false;
    if(Time[0] != g_LastBarTime) {
        isNewBar = true;
        g_LastBarTime = Time[0];
    }
    
    // 定期检查参数更新
    if(TimeCurrent() - g_LastParamCheck >= ParamCheckInterval) {
        CheckParameterUpdate();
        g_LastParamCheck = TimeCurrent();
    }
    
    // 根据状态执行相应逻辑
    switch(g_CurrentState) {
        case STATE_RUNNING:
            if(isNewBar) {
                // 新 K 线首 tick：评估 Time[1] 并立即执行
                EvaluateAndExecuteSignal();
            }
            CheckPositionsWrapper();
            break;
            
        case STATE_SAFE_MODE:
            CheckPositionsWrapper();
            if(isNewBar) {
                TryRecoverFromSafeMode();
            }
            break;
    }
}
```

**实现的辅助函数：**

1. **CheckParameterUpdate()**：定期检查并重新加载参数包
2. **EvaluateAndExecuteSignal()**：在新 K 线首 tick 评估 Time[1]，并在满足条件时立即执行开仓（含风控/时间过滤/Dry Run/真实下单）
4. **TryRecoverFromSafeMode()**：尝试从 Safe Mode 恢复到 RUNNING 状态

### 10.3 实现 Dry Run 模式 ✅

**实现内容：**
- 在 Dry Run 模式下跳过真实订单执行
- 输出模拟交易信号到日志
- 日志包含 "DryRun" 标识字段，明确标记为模拟模式

**关键代码：**
```mql4
void EvaluateAndExecuteSignal() {
    // ... 前置检查 ...
    
    // 检查 Dry Run 模式
    if(DryRun) {
        LogInfo("EA", "========== DRY RUN 模式 ==========");
        LogInfo("EA", StringFormat("模拟开仓: 品种=%s, 入场=%.5f, 止损=%.5f, 总手数=%.2f",
                Symbol(), signal.entry_price, signal.stop_loss, total_lots));
        
        for(int i = 0; i < tp_count; i++) {
            LogInfo("EA", StringFormat("  订单 %d: 手数=%.2f, 止盈=%.5f", 
                    i + 1, splits[i].lots, splits[i].tp_price));
        }
        
        LogInfo("EA", "DryRun 标识: 此为模拟交易，未执行真实订单");
        LogInfo("EA", "========== DRY RUN 结束 ==========");
        return;
    }
    
    // 执行真实订单
    // ...
}
```

### 10.4 实现 OnDeinit 清理 ✅

**实现内容：**
- 保存 EA 状态（使用 GlobalVariable）
- 清理持仓管理器
- 清理资源
- 关闭日志系统

**关键代码：**
```mql4
void OnDeinit(const int reason)
{
    LogInfo("EA", "EA 停止，原因: " + DeInitReasonToString(reason));
    
    // 保存状态
    SaveEAState();
    
    // 清理持仓管理器
    CleanupPositionManager();
    
    // 清理资源
    CleanupResources();
    
    // 关闭日志系统
    CloseLogger();
}

void SaveEAState() {
    // 使用 GlobalVariable 保存风险状态
    GlobalVariableSet("FSE_DailyProfit", g_risk_state.daily_profit);
    GlobalVariableSet("FSE_ConsecutiveLosses", g_risk_state.consecutive_losses);
    GlobalVariableSet("FSE_CircuitBreakerUntil", (double)g_risk_state.circuit_breaker_until);
    GlobalVariableSet("FSE_LastResetDate", g_risk_state.last_reset_date);
}
```

## 完整的交易执行流程

### 1. 初始化阶段（OnInit）
```
验证输入参数 → 初始化模块 → 校验品种/周期 → 加载参数包 → 设置状态
```

### 2. 运行阶段（OnTick）

**RUNNING 状态：**
```
检测新 K 线 → 定期检查参数更新
    ↓
新 K 线首 tick → 评估 Time[1]（刚收盘 K 线）：
    - 评估信号
    - 检查风控条件
    - 检查时间过滤
    - 计算手数
    - 拆分订单
    - 立即执行开仓（或 Dry Run 模拟）
    ↓
持续检查持仓状态
```

**SAFE_MODE 状态：**
```
只管理持仓 → 定期尝试恢复到 RUNNING 状态
```

### 3. 清理阶段（OnDeinit）
```
保存状态 → 清理持仓管理器 → 清理资源 → 关闭日志
```

## 状态机设计

EA 使用状态机管理运行状态：

```
INITIALIZING → LOADING_PARAMS → RUNNING ⇄ SAFE_MODE
```

**状态转换条件：**
- `INITIALIZING → LOADING_PARAMS`：启动完成
- `LOADING_PARAMS → RUNNING`：参数有效
- `LOADING_PARAMS → SAFE_MODE`：参数无效/过期
- `RUNNING → SAFE_MODE`：参数过期或熔断触发
- `SAFE_MODE → RUNNING`：参数恢复有效且熔断解除

## 关键特性

### 1. 安全优先
- 参数异常时自动进入 Safe Mode
- Safe Mode 下只管理持仓，不开新仓
- 所有异常情况优先保护账户安全

### 2. 可追溯性
- 所有决策都记录到日志
- 包含参数版本、触发条件、执行结果
- Dry Run 模式明确标记模拟交易

### 3. 可恢复性
- 使用 GlobalVariable 保存风险状态
- EA 重启后可恢复状态
- Safe Mode 可自动恢复到 RUNNING 状态

### 4. 模块化设计
- 各模块职责清晰
- 通过包含头文件集成
- 易于维护和扩展

## 验证需求

### 需求 1.1：参数文件读取 ✅
- OnInit 中加载参数包
- 支持自定义路径或默认路径

### 需求 2.7：信号评估与执行 ✅
- 新 K 线首 tick 评估刚收盘 K 线（Time[1]）
- 条件满足时在同一轮立即执行开仓

### 需求 6.1-6.5：Dry Run 模式 ✅
- 执行所有信号判定逻辑
- 不执行真实订单
- 输出模拟信号到日志
- 明确标记为模拟模式

### 需求 8.3：参数刷新机制 ✅
- 定期检查参数更新
- 自动加载新参数

### 需求 10.1-10.6：错误处理与稳定性 ✅
- 参数文件缺失/格式错误不崩溃
- 进入 Safe Mode 保护账户
- 所有异常情况记录日志

## 文件结构

```
domain_experts/forex/ea/
├── ForexStrategyExecutor.mq4          # 主 EA 文件（本次实现）
├── include/
│   ├── TimeUtils.mqh                  # 时间工具
│   ├── Logger.mqh                     # 日志系统
│   ├── ParameterLoader.mqh            # 参数加载器
│   ├── StrategyEngine.mqh             # 策略引擎
│   ├── RiskManager.mqh                # 风险管理器
│   ├── OrderExecutor.mqh              # 订单执行器
│   ├── TimeFilter.mqh                 # 时间过滤器
│   └── PositionManager.mqh            # 持仓管理器
└── README.md                          # 项目说明
```

## 后续进展（已完成）

Task 10 后续工作已完成：

1. Task 11 / 11.5 / 11.6 / 11.7：EA 核心功能与静态复审修复完成
2. Task 13：在线严格验收通过（通过 3 / 失败 0 / 跳过 0）
3. Task 14：回测执行与实盘一致性验证完成
4. Task 15：Final Checkpoint 验收完成

## 注意事项

1. **编译前检查**：确保所有头文件都在 `include/` 目录下
2. **路径配置**：根据实际环境配置参数文件路径
3. **时区设置**：正确配置 ServerUTCOffset 参数
4. **测试建议**：先在 Dry Run 模式下测试，确认逻辑正确后再实盘运行

## 总结

任务 10 成功实现了 EA 主循环集成，将所有模块整合到一个完整的交易系统中。系统具备：

- ✅ 完整的初始化流程
- ✅ 健壮的主循环逻辑
- ✅ Dry Run 模式支持
- ✅ 状态管理和错误处理
- ✅ 资源清理和状态保存

该模块已在后续任务中完成集成验证并进入最终验收收口。
