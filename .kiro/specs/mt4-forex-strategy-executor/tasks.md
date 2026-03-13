# 实现计划：MT4 外汇策略执行系统

## 概述

本实现计划将设计转化为可执行的编码任务。系统分为两个主要部分：
1. MT4 EA（MQL4）- 执行交易策略
2. Blockcell 参数生成器（Rhai）- 生成策略参数

任务按照依赖关系组织，每个任务都引用相关的需求和设计。

## 任务

- [x] 1. MT4 EA 基础架构
  - 创建 EA 主文件和全局变量
  - 实现 OnInit、OnDeinit、OnTick 框架
  - 定义输入参数（ParamFilePath, DryRun, LogLevel, ParamCheckInterval, ServerUTCOffset）
  - _需求：1.1, 10.1, 10.2_

- [x] 2. 时间处理模块
  - [x] 2.1 实现 UTC 时间转换函数
    - 实现 ConvertToUTC(datetime server_time) 函数
    - 使用 ServerUTCOffset 输入参数
    - _需求：1.12, 4.6, 8.5_
    - _设计：时间处理最佳实践_

  - [x] 2.2 实现 ISO 8601 时间解析函数
    - 实现 ParseISO8601(string iso_str) 函数
    - 手工解析 YYYY-MM-DDTHH:MM:SSZ 格式
    - 使用 MqlDateTime 和 StructToTime
    - _需求：1.12_
    - _设计：时间处理最佳实践_

- [x] 3. 参数加载器模块
  - [x] 3.1 定义参数包数据结构
    - 定义 ParameterPack、NewsBlackout、SessionFilter 结构体
    - _需求：1.10_
    - _设计：Parameter Loader 数据结构_

  - [x] 3.2 实现 JSON 参数文件读取
    - 实现 LoadParameterPack(string filePath) 函数
    - 读取 signal_pack.json 文件
    - 解析 JSON 到 ParameterPack 结构体
    - _需求：1.1, 1.2_
    - _设计：Parameter Loader 接口_

  - [x] 3.3 实现参数字段校验
    - 校验所有必需字段存在
    - 校验 symbol == "EURUSD"
    - 校验 timeframe == "H4"
    - 校验 bias == "short_only"
    - 校验 tp_levels 和 tp_ratios 长度相同
    - 校验 abs(sum(tp_ratios) - 1.0) <= 1e-6
    - 校验可选字段（news_blackout, session_filter, comment）的格式正确性
    - _需求：1.3, 1.7, 1.8, 1.9, 1.10, 1.11_
    - _设计：Parameter Loader 校验规则_

  - [x] 3.4 实现参数选择优先级逻辑
    - 实现参数备份保存和加载
    - 实现参数有效期判断
    - 实现多参数优先级选择（按 version 排序）
    - _需求：1.4, 1.5, 1.6, 8.4_
    - _设计：Parameter Loader 参数选择优先级逻辑_

  - [x] 3.5 实现 Safe_Mode 状态管理
    - 参数无效时进入 Safe_Mode
    - Safe_Mode 下禁止开新仓但继续管理持仓
    - _需求：1.5, 3.9_
    - _设计：EA 状态机_

- [x] 4. 策略引擎模块
  - [x] 4.1 实现趋势过滤
    - 实现 CheckTrendFilter(int ema_trend_period) 函数
    - 使用已收盘的 K 线 [1]
    - 判断 Close[1] < EMA200
    - _需求：2.1_
    - _设计：Strategy Engine 策略逻辑 1_

  - [x] 4.2 实现区间过滤
    - 实现 CheckPriceZone(double zone_min, double zone_max) 函数
    - 使用已收盘的 K 线 [1]
    - 判断价格在 entry_zone 范围内
    - _需求：2.2, 2.3_
    - _设计：Strategy Engine 策略逻辑 2_

  - [x] 4.3 实现 EMA 回踩检测
    - 实现 CheckEMARetracement(int ema_fast_period, int lookback, double tolerance) 函数
    - 检查最近 lookback_period 根已收盘的 K 线（从 [1] 开始）
    - 判断是否存在回踩 EMA50
    - _需求：2.4_
    - _设计：Strategy Engine 策略逻辑 3_

  - [x] 4.4 实现形态识别
    - 实现 CheckPattern(string patterns[]) 函数
    - 实现看跌吞没形态识别（使用 [1] 和 [2]）
    - 实现看跌 Pin Bar 形态识别（使用 [1]）
    - _需求：2.5, 2.6_
    - _设计：Strategy Engine 策略逻辑 4, 5_

  - [x] 4.5 实现止损计算
    - 实现 CalculateStopLoss(double invalid_above, double signal_high, double buffer) 函数
    - 计算 max(invalid_above, Signal_K 高点 + buffer)
    - _需求：2.8_
    - _设计：Strategy Engine 策略逻辑 6_

  - [x] 4.6 实现信号评估主函数
    - 实现 EvaluateEntrySignal(ParameterPack params) 函数
    - 整合所有入场条件判断
    - 返回 SignalResult 结构体
    - _需求：2.7, 2.13_
    - _设计：Strategy Engine 接口_


- [x] 5. 风险管理器模块
  - [x] 5.1 实现手数计算
    - 实现 CalculatePositionSize(double entry, double stop_loss, double risk_percent) 函数
    - 使用绝对值计算点数风险
    - 规范化手数到 lot_step、min_lot、max_lot
    - _需求：3.1_
    - _设计：Risk Manager 手数计算逻辑_

  - [x] 5.2 实现拆单逻辑
    - 实现 SplitLots(double total_lots, double ratios[]) 函数
    - 按 tp_ratios 拆分手数
    - 处理舍入余量分配到最后一单
    - 再次规范化并校验约束
    - _需求：2.9, 2.10, 2.11, 2.12_
    - _设计：Risk Manager 拆单逻辑_

  - [x] 5.3 实现点差检查
    - 实现 CheckSpread(double max_spread_points) 函数
    - 计算当前点差
    - 判断是否超过阈值
    - _需求：3.4_
    - _设计：Risk Manager 点差检查_

  - [x] 5.4 实现日亏损熔断
    - 实现日切判断逻辑（使用 UTC 时间）
    - 维护 daily_profit 和 last_reset_date
    - 触发熔断时设置 circuit_breaker_until
    - _需求：3.2_
    - _设计：Risk Manager 熔断机制 1_

  - [x] 5.5 实现连续亏损熔断
    - 维护 consecutive_losses 计数器
    - 触发熔断时设置 circuit_breaker_until
    - _需求：3.3_
    - _设计：Risk Manager 熔断机制 2_

  - [x] 5.6 实现熔断恢复逻辑
    - 检查当前 UTC 时间是否超过 circuit_breaker_until
    - 自动恢复正常交易状态
    - _需求：3.8_
    - _设计：Risk Manager 熔断机制 3_

  - [x] 5.7 实现交易结果记录
    - 实现 RecordTradeResult(int ticket, double profit) 函数
    - 更新 daily_profit 和 consecutive_losses
    - _需求：3.2, 3.3_
    - _设计：Risk Manager 接口_

- [x] 6. 订单执行器模块
  - [x] 6.1 实现单笔开仓
    - 实现 OpenPosition(double lots, double entry, double stop_loss, double take_profit, int slippage) 函数
    - 使用 OrderSend 执行开仓
    - 设置最大允许滑点参数
    - _需求：2.7, 3.5_
    - _设计：Order Executor 开仓逻辑_

  - [x] 6.2 实现批量开仓（拆单）
    - 实现 OpenMultiplePositions(LotSplit splits[], double entry, double stop_loss, int slippage) 函数
    - 为每个拆分订单设置对应的止盈价格
    - _需求：2.9, 2.12_
    - _设计：Order Executor 接口_

  - [x] 6.3 实现订单错误处理和异常场景策略
    - 识别可重试和不可重试错误
    - 实现重试逻辑（最多 3 次，间隔 1 秒）
    - 实现网络中断等待重连逻辑
    - 实现异常市场数据保守拒单策略
    - 所有异常情况优先保护账户安全
    - _需求：10.3, 10.4, 10.5, 10.6_
    - _设计：Order Executor 错误处理、错误处理_

  - [x] 6.4 实现实际滑点记录
    - 获取订单成交价格
    - 计算实际滑点
    - 记录到日志
    - _需求：3.6_
    - _设计：Order Executor 开仓逻辑 4_

- [x] 7. 时间过滤器模块
  - [x] 7.1 实现新闻窗口过滤
    - 实现 IsInNewsBlackout(NewsBlackout blackouts[]) 函数
    - 使用 UTC 时间判断
    - 支持配置多个 news_blackout 时间窗口
    - 正确处理多个时间窗口重叠的情况
    - _需求：4.1, 4.3, 4.4, 4.5_
    - _设计：Time Filter 时间过滤逻辑 1_

  - [x] 7.2 实现交易时段过滤
    - 实现 IsInTradingSession(SessionFilter filter) 函数
    - 使用 UTC 时间判断
    - 检查当前小时是否在允许的时段内
    - _需求：4.2_
    - _设计：Time Filter 时间过滤逻辑 2_

- [x] 8. 日志记录器模块
  - [x] 8.1 实现日志基础功能和统一 Schema
    - 实现日志级别过滤（DEBUG, INFO, WARN, ERROR）
    - 定义统一日志 Schema：timestamp, level, component, symbol, rule_hit, param_version, decision, message
    - 实现字段强校验，确保所有日志包含必需字段
    - 实现日志格式化
    - 支持输出到文件和 MT4 日志窗口
    - _需求：5.6, 5.7_
    - _设计：Logger 接口、Logger 日志格式_

  - [x] 8.2 实现各类日志记录函数
    - LogParameterLoad - 记录参数加载（包含 param_version）
    - LogSignalEvaluation - 记录信号评估（包含 rule_hit, param_version, decision）
    - LogOrderOpen - 记录开仓（包含 symbol, param_version, decision）
    - LogOrderReject - 记录拒单（包含 symbol, rule_hit, param_version, decision）
    - LogCircuitBreaker - 记录熔断（必填字段：circuit_type, trigger_value, recover_at_utc, reason, rule_hit, decision）
    - LogOrderClose - 记录平仓（包含 symbol, decision）
    - 所有日志函数必须传递 rule_hit, param_version, decision 参数
    - _需求：5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 3.7_
    - _设计：Logger 接口、Logger 日志内容_

- [x] 9. 持仓管理器模块
  - [x] 9.1 实现持仓扫描
    - 实现 GetOpenPositions() 函数
    - 扫描所有持仓订单
    - _设计：Position Manager 接口_

  - [x] 9.2 实现持仓状态检查
    - 实现 CheckPositions() 函数
    - 检查订单是否已平仓
    - 触发交易结果记录
    - _设计：Position Manager 持仓管理逻辑_

- [x] 10. EA 主循环集成
  - [x] 10.1 实现 OnInit 初始化
    - 加载参数包
    - 初始化所有模块
    - 验证配置
    - _需求：1.1_

  - [x] 10.2 实现 OnTick 主逻辑
    - 检测 K 线变化
    - 定期检查参数更新
    - 评估入场信号
    - 执行开仓操作
    - 检查持仓状态
    - _需求：2.7, 8.3_

  - [x] 10.3 实现 Dry Run 模式
    - 在 Dry Run 模式下跳过真实订单执行
    - 输出模拟交易信号到日志
    - 日志必须包含 "DryRun" 标识字段，明确标记为模拟模式
    - _需求：6.1, 6.2, 6.3, 6.4, 6.5_

  - [x] 10.4 实现 OnDeinit 清理
    - 保存状态
    - 清理资源

- [x] 11. Checkpoint - EA 核心功能完成
  - 确保所有 EA 模块测试通过
  - 确保参数加载、策略评估、风险管理、订单执行都正常工作
  - 询问用户是否有问题

- [x] 11.5 静态审查缺陷修复（2026-03-10）
  - [x] 11.5.1 修复 Signal_K 执行时序错位（High 优先级）
    - 问题：ExecutePendingSignal() 重新调用 EvaluateEntrySignal()，导致使用"新的 Signal_K"而非最初待执行的那根
    - 解决方案：添加全局变量 g_CachedSignal 缓存信号快照；修改 EvaluateEntrySignal() 缓存完整信号；修改 ExecutePendingSignal() 直接使用缓存信号
    - 影响文件：ForexStrategyExecutor.mq4
    - _需求：2.7, 2.8_
    - _设计：信号缓存机制_

  - [x] 11.5.2 修复 news_blackout/session_filter 未解析（Medium 优先级）
    - 问题：ParseParameterJSON() 中是 TODO，硬编码 blackout_count=0、session_filter.enabled=false，导致时间过滤实际失效
    - 解决方案：实现 ParseNewsBlackout() 函数（约80行）和 ParseSessionFilter() 函数（约80行）；移除硬编码默认值；在 ParseParameterJSON() 中调用这两个函数
    - 影响文件：ParameterLoader.mqh
    - _需求：4.1, 4.2, 4.3, 4.10_
    - _设计：可选字段解析策略_

  - [x] 11.5.3 修复 OnDeinit 日志顺序错误（Low 优先级）
    - 问题：先 CloseLogger() 再 LogInfo("EA 已停止")，最后一条日志丢失
    - 解决方案：调整顺序，先写日志再关闭 Logger
    - 影响文件：ForexStrategyExecutor.mq4
    - _需求：5.8, 5.9_
    - _设计：日志关闭顺序_

- [x] 11.6 静态复审缺陷修复（2026-03-10）
  - [x] 11.6.1 修复 Signal_K 执行时机晚一根 K 线（High 优先级）- 第二次修复
    - 问题：OnTick 中先执行待处理信号，后评估新信号，导致"Signal_K 收盘后下下根 K 线首 tick 执行"
    - 根本原因：缓存-延迟执行模式导致信号延迟一根 K 线
    - 解决方案：
      - 废弃缓存-延迟执行模式（g_PendingSignal, g_CachedSignal）
      - 创建 EvaluateAndExecuteSignal() 函数，在 isNewBar 时立即评估并执行
      - 确保"Signal_K 收盘后下一根 K 线首 tick 执行"的正确时序
    - 影响文件：ForexStrategyExecutor.mq4
    - _需求：2.7_
    - _设计：信号评估与执行时机_

  - [x] 11.6.2 修复执行阶段未完全使用缓存信号（High 优先级）
    - 问题：虽然缓存了信号，但执行时 TP 数据仍从当前参数读取，导致信号和 TP 可能来自不同参数版本
    - 解决方案：在 ExecutePendingSignal() 中使用 signal.tp_count、signal.tp_ratios、signal.tp_levels，而非 params 中的数据
    - 影响文件：ForexStrategyExecutor.mq4
    - 状态：已被 11.6.1 的新方案替代（不再使用缓存模式）
    - _需求：2.7, 2.8_
    - _设计：信号缓存机制_

  - [x] 11.6.3 添加 news_blackout 时间窗口校验（Medium 优先级）
    - 问题：解析时未验证 start < end，可能导致静默失效
    - 解决方案：在 ParseNewsBlackout() 中添加校验，确保 start < end，否则拒绝加载参数包
    - 影响文件：ParameterLoader.mqh
    - _需求：4.3_
    - _设计：可选字段解析策略_

  - [x] 11.6.4 修复定时参数更新时的 Safe_Mode 切换（Medium 优先级）
    - 问题：CheckParameterUpdate() 加载失败时不会切换状态
    - 解决方案：在 CheckParameterUpdate() 中检查参数有效性，无效时切换到 Safe_Mode
    - 影响文件：ForexStrategyExecutor.mq4
    - _需求：1.5, 4.10_
    - _设计：EA 状态机_

- [x] 11.7 静态复审缺陷修复（2026-03-10 - 第四轮）
  - [x] 11.7.1 修复 OpenMultiplePositions 调用参数顺序错误（High 优先级）
    - 问题：调用时参数顺序完全错乱，导致拆单数量异常且止损价格错误
    - 根本原因：
      - 函数签名：`OpenMultiplePositions(splits[], split_count, entry, stop_loss, slippage, tickets[])`
      - 错误调用：`OpenMultiplePositions(splits, entry_price, stop_loss, slippage, tp_count, tickets)`
      - 导致 entry_price → split_count, stop_loss → entry, slippage → stop_loss, tp_count → slippage
    - 解决方案：修正参数顺序为 `OpenMultiplePositions(splits, tp_count, entry_price, stop_loss, slippage, tickets)`
    - 影响文件：ForexStrategyExecutor.mq4 (行 399)
    - _需求：2.9, 2.12_
    - _设计：Order Executor 批量开仓_

  - [x] 11.7.2 修复返回值类型误用（Medium 优先级）
    - 问题：OpenMultiplePositions 返回 int（成功订单数），但用 bool 接收，导致日志误报
    - 解决方案：
      - 使用 `int success_count` 接收返回值
      - 根据 success_count 判断：全部成功、部分成功、全部失败
      - 分别记录不同级别的日志（INFO、WARN、ERROR）
    - 影响文件：ForexStrategyExecutor.mq4 (行 399-413)
    - _需求：5.2_
    - _设计：Logger 日志内容_

- [x] 12. Blockcell 参数生成器
  - [x] 12.1 创建 forex_strategy_generator Skill
    - 创建 Rhai 脚本文件
    - 定义 generate_signal_pack 函数
    - _需求：7.1_
    - _设计：Blockcell Parameter Generator Skill 接口_

  - [x] 12.2 实现 AI 技能调用
    - 调用 forex_news Skill
    - 调用 forex_analysis Skill
    - 调用 forex_strategy Skill
    - _需求：7.1_
    - _设计：Blockcell Parameter Generator Skill 接口 1-3_

  - [x] 12.3 实现参数包构建
    - 构建包含所有必需字段的参数包
    - 使用 now_utc() 获取 UTC 时间
    - 使用 format_iso8601() 格式化时间
    - 生成唯一版本号
    - _需求：7.2, 7.3, 7.4_
    - _设计：Blockcell Parameter Generator Skill 接口 4_

  - [x] 12.4 实现参数包保存
    - 保存到 workspace/ea/signal_pack.json
    - _需求：7.5_
    - _设计：Blockcell Parameter Generator Skill 接口 5_

  - [x] 12.5 配置 Cron 定时任务
    - 配置每天 UTC 06:00 触发
    - 支持手动触发
    - _需求：7.6, 8.1, 8.2_
    - _设计：Blockcell Parameter Generator 定时触发_

- [x] 12.6 静态审查缺陷修复（2026-03-10）
  - [x] 12.6.1 修复 call_skill 函数不可用（Critical 优先级）
    - 问题：SKILL.rhai 调用了 call_skill()，但 Skill 运行时环境中只注册了 call_tool/call_tool_json
    - 解决方案：移除所有 call_skill() 调用，添加 V1 占位符注释，说明 AI 技能待实现
    - 影响文件：SKILL.rhai (行 88-95)
    - _参考：dispatcher.rs:188_

  - [x] 12.6.2 修复 file_ops 不支持 write 操作（Critical 优先级）
    - 问题：使用 call_tool("file_ops", #{action: "write", ...})，但 file_ops 不支持 write 操作
    - 解决方案：改用 write_file(path, content) 函数
    - 影响文件：SKILL.rhai (行 264-267)
    - _参考：file_ops.rs:31-34, fs.rs:98_

  - [x] 12.6.3 修复 Cron 配置脚本 API 协议不匹配（High 优先级）
    - 问题：setup_cron.sh 发送的 JSON 结构不正确（id/schedule/action），Gateway 期望 name/message/cron_expr/skill_name/deliver
    - 解决方案：更新 JSON 结构以匹配 Gateway API，添加 HTTP 状态码检查
    - 影响文件：setup_cron.sh (行 67-98)
    - _参考：cron.rs:30-39, job.rs:5-17_

  - [x] 12.6.4 修复手动触发接口路径错误（High 优先级）
    - 问题：调用 /v1/skills/forex_strategy_generator/run，但 Gateway 不存在该接口
    - 解决方案：创建一次性 Cron 任务（at_ms + delete_after_run: true）来执行 Skill
    - 影响文件：setup_cron.sh (行 107-145), test_example.sh (行 48-72)
    - _参考：gateway.rs:1397-1435_

  - [x] 12.6.5 修复时间格式化算法错误（High 优先级）
    - 问题：format_iso8601() 和 generate_version() 使用简化算法，未考虑闰年和实际月份天数，会生成错误日期
    - 解决方案：实现正确的闰年判断函数，使用实际的每月天数数组，逐年、逐月计算日期
    - 影响文件：SKILL.rhai (行 20-90)
    - _参考：ParameterLoader.mqh:301, ParameterLoader.mqh:697_

- [x] 13. Checkpoint - 系统集成测试
  - 确保 Blockcell 能成功生成参数包
  - 确保 EA 能成功加载参数包
  - 确保参数刷新机制正常工作
  - [x] 在线严格验收已通过（2026-03-10）
    - 执行参数：`RUN_LIVE_TESTS=1`、`STRICT_MODE=1`
    - 验收结果：通过 3 / 失败 0 / 跳过 0
    - 证据（脚本）：[integration_test.ps1](../../../domain_experts/forex/skills/forex_strategy_generator/integration_test.ps1)
    - 证据（记录）：[ONLINE_STRICT_ACCEPTANCE_2026-03-10.md](../../../domain_experts/forex/skills/forex_strategy_generator/ONLINE_STRICT_ACCEPTANCE_2026-03-10.md)
  - 询问用户是否有问题

- [x] 14. 文档与部署
  - [x] 14.1 编写参数协议文档
    - 记录 JSON 字段说明
    - 提供示例参数包
    - _交付物：参数协议文档_

  - [x] 14.2 编写运行手册
    - 部署步骤
    - 参数路径配置
    - 故障处理指南
    - _交付物：运行手册_

  - [x] 14.3 准备回测环境
    - 准备历史数据（6-12 个月）
    - 配置 MT4 Strategy Tester
    - _需求：9.1, 9.2_

  - [x] 14.4 实现回测参数注入机制
    - 实现外部参数注入方式（通过 EA 输入参数）
    - 实现内嵌参数注入方式（硬编码到 EA）
    - 验证两种方式都能正常工作
    - 证据（运行脚本）：[run_mt4_task14_backtest.ps1](../../../domain_experts/forex/ea/scripts/run_mt4_task14_backtest.ps1)
    - 证据（文件模式日志摘录）：[file_mode_log_excerpt.txt](../../../domain_experts/forex/ea/backtest_artifacts/task14_20260311_090410/file_mode_log_excerpt.txt)
    - 证据（内嵌模式日志摘录）：[embedded_mode_log_excerpt.txt](../../../domain_experts/forex/ea/backtest_artifacts/task14_20260311_090410/embedded_mode_log_excerpt.txt)
    - _需求：9.5_

  - [x] 14.5 验证回测与实盘逻辑一致性
    - 对比回测和实盘的决策路径
    - 确保使用相同的策略逻辑
    - 验证历史 K 线数据处理正确
    - 状态说明：在线实盘窗口（2026-03-11 22:25:34 ~ 22:30:34，本地时区）已通过 `passed_startup_and_tick_update_path`；同参数、同 EA 条件下，回测与实盘在参数加载 + 状态机启动 + OnTick 参数更新链路一致（`live_ea_lines_count=209`，`live_tick_update_lines_count=1`）
    - 证据（脚本）：[run_mt4_task14_live_consistency.ps1](../../../domain_experts/forex/ea/scripts/run_mt4_task14_live_consistency.ps1)
    - 证据（一致性报告）：[CONSISTENCY_REPORT.md](../../../domain_experts/forex/ea/backtest_artifacts/task14_consistency_20260311_222534/CONSISTENCY_REPORT.md)
    - 证据（摘要）：[summary.json](../../../domain_experts/forex/ea/backtest_artifacts/task14_consistency_20260311_222534/summary.json)
    - 证据（实盘 EA 日志摘录）：[live_mode_log_excerpt.txt](../../../domain_experts/forex/ea/backtest_artifacts/task14_consistency_20260311_222534/live_mode_log_excerpt.txt)
    - 证据（终端连接日志摘录）：[runner_log_excerpt.txt](../../../domain_experts/forex/ea/backtest_artifacts/task14_consistency_20260311_222534/runner_log_excerpt.txt)
    - _需求：9.2, 9.3, 9.6_

  - [x] 14.6 执行回测
    - 运行回测
    - 生成回测报告
    - 验证无崩溃或异常下单
    - 证据（汇总）：[summary.json](../../../domain_experts/forex/ea/backtest_artifacts/task14_20260311_090410/summary.json)
    - 证据（文件模式报告）：[report_file_mode.htm](../../../domain_experts/forex/ea/backtest_artifacts/task14_20260311_090410/report_file_mode.htm)
    - 证据（内嵌模式报告）：[report_embedded_mode.htm](../../../domain_experts/forex/ea/backtest_artifacts/task14_20260311_090410/report_embedded_mode.htm)
    - 证据（回测报告文档）：[BACKTEST_REPORT.md](../../../domain_experts/forex/ea/docs/BACKTEST_REPORT.md)
    - _需求：9.4, 9.7_
    - _交付物：回测报告_

- [x] 15. Final Checkpoint - 验收（2026-03-11）
  - [x] 验证所有验收标准（需求 1-10）
  - [x] 确认所有交付物完成
  - [x] 产出最终验收记录
    - 证据（最终验收记录）：[final_acceptance_2026-03-11.md](./final_acceptance_2026-03-11.md)
    - 证据（在线严格验收）：[ONLINE_STRICT_ACCEPTANCE_2026-03-10.md](../../../domain_experts/forex/skills/forex_strategy_generator/ONLINE_STRICT_ACCEPTANCE_2026-03-10.md)
    - 证据（回测汇总）：[summary.json](../../../domain_experts/forex/ea/backtest_artifacts/task14_20260311_090410/summary.json)
    - 证据（一致性汇总）：[summary.json](../../../domain_experts/forex/ea/backtest_artifacts/task14_consistency_20260311_222534/summary.json)
  - [x] 询问用户是否满意（待用户反馈）

- [x] 16. 参数包持续同步机制落地（2026-03-12）
  - [x] 16.1 增加持续同步脚本
    - 新增 `sync_signal_pack_continuous.ps1`，支持启动即全量同步 + 轮询增量同步
    - 自动同步到 `.mt4_portable_runner/MQL4/Files/signal_pack.json` 与 `.mt4_portable_runner/tester/files/signal_pack.json`
    - _需求：11.1, 11.2, 11.5_
    - _设计：部署流程 - 文件同步（design.md 1307-1311）_

  - [x] 16.2 增加失败重试与同步日志
    - 写入失败时记录源/目标/错误并自动重试
    - 日志记录 UTC 时间戳与参数包 version（可解析时）
    - _需求：11.3, 11.6_
    - _设计：运维监控与告警_

  - [x] 16.3 补充运维使用文档
    - 在 `domain_experts/forex/ea/scripts/Readme.md` 增加持续同步脚本启动、一次性执行和自定义参数示例
    - _需求：11.5_
    - _设计：部署流程 - 文件同步_

  - [x] 16.4 增加任务计划注册脚本
    - 新增 `register_signal_pack_sync_task.ps1`，支持 Install/Status/RunNow/Remove/Stop
    - 支持登录后自动启动持续同步服务，并可附带 `-StartNow` 立即触发
    - _需求：11.1, 11.2, 11.5_
    - _设计：部署流程 - 文件同步_

  - [x] 16.5 同步服务稳定性增强
    - `sync_signal_pack_continuous.ps1` 增加单实例锁，避免重复启动导致并发写入
    - `register_signal_pack_sync_task.ps1` 增加 `Stop` 动作并修复 `Status` 权限误判
    - _需求：11.3, 11.4, 11.5_
    - _设计：部署流程 - 文件同步_

  - [x] 16.6 同步健康检查脚本
    - 新增 `verify_signal_sync.ps1`，校验 source/live/tester 的 hash/version/mtime 一致性
    - 支持 `-RequireCurrentValidWindow` 与 `-MaxAgeMinutes`，异常返回非 0（`exit 2`）
    - 明确 `RequireCurrentValidWindow=false` 为“连续性监控模式”：过期仅 WARNING，不作为 FAILED
    - 哈希不一致时输出各副本哈希前缀（source/live/tester）用于快速定位
    - 在 `scripts/Readme.md` 补充监控场景命令示例
    - _需求：11.1, 11.3, 11.6, 11.7, 11.8_
    - _设计：运维监控与告警_

  - [x] 16.7 健康检查任务化
    - 新增 `run_signal_sync_health_check.ps1`，统一输出 `signal_sync_health.log` 与 `signal_sync_alert.log`
    - 新增 `register_signal_sync_health_task.ps1`，支持 Install/Status/RunNow/Remove
    - 默认每 5 分钟检查一次，可用于本机 Task Scheduler 运维告警
    - _需求：11.1, 11.3, 11.6_
    - _设计：运维监控与告警_

  - [x] 16.8 健康日志轮转
    - `run_signal_sync_health_check.ps1` 增加按大小轮转（`MaxLogSizeKB`）和备份保留（`MaxLogBackups`）
    - 轮转同时作用于 `signal_sync_health.log` 与 `signal_sync_alert.log`
    - `register_signal_sync_health_task.ps1` 透传轮转参数并在安装输出中展示
    - _需求：11.3, 11.6_
    - _设计：运维监控与告警_

## 注意事项

- 任务按依赖关系组织，建议按顺序执行
- 每个任务都引用了相关的需求和设计
- Checkpoint 任务用于阶段性验证和用户反馈
- 测试相关的子任务已标记，可根据需要调整优先级
- EA 使用 MQL4 语言，Blockcell 使用 Rhai 语言
