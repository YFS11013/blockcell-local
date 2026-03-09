# 实现计划：MT4 外汇策略执行系统

## 概述

本实现计划将设计转化为可执行的编码任务。系统分为两个主要部分：
1. MT4 EA（MQL4）- 执行交易策略
2. Blockcell 参数生成器（Rhai）- 生成策略参数

任务按照依赖关系组织，每个任务都引用相关的需求和设计。

## 任务

- [ ] 1. MT4 EA 基础架构
  - 创建 EA 主文件和全局变量
  - 实现 OnInit、OnDeinit、OnTick 框架
  - 定义输入参数（ParamFilePath, DryRun, LogLevel, ParamCheckInterval, ServerUTCOffset）
  - _需求：1.1, 10.1, 10.2_

- [ ] 2. 时间处理模块
  - [ ] 2.1 实现 UTC 时间转换函数
    - 实现 ConvertToUTC(datetime server_time) 函数
    - 使用 ServerUTCOffset 输入参数
    - _需求：1.12, 4.6, 8.5_
    - _设计：时间处理最佳实践_

  - [ ] 2.2 实现 ISO 8601 时间解析函数
    - 实现 ParseISO8601(string iso_str) 函数
    - 手工解析 YYYY-MM-DDTHH:MM:SSZ 格式
    - 使用 MqlDateTime 和 StructToTime
    - _需求：1.12_
    - _设计：时间处理最佳实践_

- [ ] 3. 参数加载器模块
  - [ ] 3.1 定义参数包数据结构
    - 定义 ParameterPack、NewsBlackout、SessionFilter 结构体
    - _需求：1.10_
    - _设计：Parameter Loader 数据结构_

  - [ ] 3.2 实现 JSON 参数文件读取
    - 实现 LoadParameterPack(string filePath) 函数
    - 读取 signal_pack.json 文件
    - 解析 JSON 到 ParameterPack 结构体
    - _需求：1.1, 1.2_
    - _设计：Parameter Loader 接口_

  - [ ] 3.3 实现参数字段校验
    - 校验所有必需字段存在
    - 校验 symbol == "EURUSD"
    - 校验 timeframe == "H4"
    - 校验 bias == "short_only"
    - 校验 tp_levels 和 tp_ratios 长度相同
    - 校验 abs(sum(tp_ratios) - 1.0) <= 1e-6
    - 校验可选字段（news_blackout, session_filter, comment）的格式正确性
    - _需求：1.3, 1.7, 1.8, 1.9, 1.10, 1.11_
    - _设计：Parameter Loader 校验规则_

  - [ ] 3.4 实现参数选择优先级逻辑
    - 实现参数备份保存和加载
    - 实现参数有效期判断
    - 实现多参数优先级选择（按 version 排序）
    - _需求：1.4, 1.5, 1.6, 8.4_
    - _设计：Parameter Loader 参数选择优先级逻辑_

  - [ ] 3.5 实现 Safe_Mode 状态管理
    - 参数无效时进入 Safe_Mode
    - Safe_Mode 下禁止开新仓但继续管理持仓
    - _需求：1.5, 3.9_
    - _设计：EA 状态机_

- [ ] 4. 策略引擎模块
  - [ ] 4.1 实现趋势过滤
    - 实现 CheckTrendFilter(int ema_trend_period) 函数
    - 使用已收盘的 K 线 [1]
    - 判断 Close[1] < EMA200
    - _需求：2.1_
    - _设计：Strategy Engine 策略逻辑 1_

  - [ ] 4.2 实现区间过滤
    - 实现 CheckPriceZone(double zone_min, double zone_max) 函数
    - 使用已收盘的 K 线 [1]
    - 判断价格在 entry_zone 范围内
    - _需求：2.2, 2.3_
    - _设计：Strategy Engine 策略逻辑 2_

  - [ ] 4.3 实现 EMA 回踩检测
    - 实现 CheckEMARetracement(int ema_fast_period, int lookback, double tolerance) 函数
    - 检查最近 lookback_period 根已收盘的 K 线（从 [1] 开始）
    - 判断是否存在回踩 EMA50
    - _需求：2.4_
    - _设计：Strategy Engine 策略逻辑 3_

  - [ ] 4.4 实现形态识别
    - 实现 CheckPattern(string patterns[]) 函数
    - 实现看跌吞没形态识别（使用 [1] 和 [2]）
    - 实现看跌 Pin Bar 形态识别（使用 [1]）
    - _需求：2.5, 2.6_
    - _设计：Strategy Engine 策略逻辑 4, 5_

  - [ ] 4.5 实现止损计算
    - 实现 CalculateStopLoss(double invalid_above, double signal_high, double buffer) 函数
    - 计算 max(invalid_above, Signal_K 高点 + buffer)
    - _需求：2.8_
    - _设计：Strategy Engine 策略逻辑 6_

  - [ ] 4.6 实现信号评估主函数
    - 实现 EvaluateEntrySignal(ParameterPack params) 函数
    - 整合所有入场条件判断
    - 返回 SignalResult 结构体
    - _需求：2.7, 2.13_
    - _设计：Strategy Engine 接口_


- [ ] 5. 风险管理器模块
  - [ ] 5.1 实现手数计算
    - 实现 CalculatePositionSize(double entry, double stop_loss, double risk_percent) 函数
    - 使用绝对值计算点数风险
    - 规范化手数到 lot_step、min_lot、max_lot
    - _需求：3.1_
    - _设计：Risk Manager 手数计算逻辑_

  - [ ] 5.2 实现拆单逻辑
    - 实现 SplitLots(double total_lots, double ratios[]) 函数
    - 按 tp_ratios 拆分手数
    - 处理舍入余量分配到最后一单
    - 再次规范化并校验约束
    - _需求：2.9, 2.10, 2.11, 2.12_
    - _设计：Risk Manager 拆单逻辑_

  - [ ] 5.3 实现点差检查
    - 实现 CheckSpread(double max_spread_points) 函数
    - 计算当前点差
    - 判断是否超过阈值
    - _需求：3.4_
    - _设计：Risk Manager 点差检查_

  - [ ] 5.4 实现日亏损熔断
    - 实现日切判断逻辑（使用 UTC 时间）
    - 维护 daily_profit 和 last_reset_date
    - 触发熔断时设置 circuit_breaker_until
    - _需求：3.2_
    - _设计：Risk Manager 熔断机制 1_

  - [ ] 5.5 实现连续亏损熔断
    - 维护 consecutive_losses 计数器
    - 触发熔断时设置 circuit_breaker_until
    - _需求：3.3_
    - _设计：Risk Manager 熔断机制 2_

  - [ ] 5.6 实现熔断恢复逻辑
    - 检查当前 UTC 时间是否超过 circuit_breaker_until
    - 自动恢复正常交易状态
    - _需求：3.8_
    - _设计：Risk Manager 熔断机制 3_

  - [ ] 5.7 实现交易结果记录
    - 实现 RecordTradeResult(int ticket, double profit) 函数
    - 更新 daily_profit 和 consecutive_losses
    - _需求：3.2, 3.3_
    - _设计：Risk Manager 接口_

- [ ] 6. 订单执行器模块
  - [ ] 6.1 实现单笔开仓
    - 实现 OpenPosition(double lots, double entry, double stop_loss, double take_profit, int slippage) 函数
    - 使用 OrderSend 执行开仓
    - 设置最大允许滑点参数
    - _需求：2.7, 3.5_
    - _设计：Order Executor 开仓逻辑_

  - [ ] 6.2 实现批量开仓（拆单）
    - 实现 OpenMultiplePositions(LotSplit splits[], double entry, double stop_loss, int slippage) 函数
    - 为每个拆分订单设置对应的止盈价格
    - _需求：2.9, 2.12_
    - _设计：Order Executor 接口_

  - [ ] 6.3 实现订单错误处理和异常场景策略
    - 识别可重试和不可重试错误
    - 实现重试逻辑（最多 3 次，间隔 1 秒）
    - 实现网络中断等待重连逻辑
    - 实现异常市场数据保守拒单策略
    - 所有异常情况优先保护账户安全
    - _需求：10.3, 10.4, 10.5, 10.6_
    - _设计：Order Executor 错误处理、错误处理_

  - [ ] 6.4 实现实际滑点记录
    - 获取订单成交价格
    - 计算实际滑点
    - 记录到日志
    - _需求：3.6_
    - _设计：Order Executor 开仓逻辑 4_

- [ ] 7. 时间过滤器模块
  - [ ] 7.1 实现新闻窗口过滤
    - 实现 IsInNewsBlackout(NewsBlackout blackouts[]) 函数
    - 使用 UTC 时间判断
    - 支持配置多个 news_blackout 时间窗口
    - 正确处理多个时间窗口重叠的情况
    - _需求：4.1, 4.3, 4.4, 4.5_
    - _设计：Time Filter 时间过滤逻辑 1_

  - [ ] 7.2 实现交易时段过滤
    - 实现 IsInTradingSession(SessionFilter filter) 函数
    - 使用 UTC 时间判断
    - 检查当前小时是否在允许的时段内
    - _需求：4.2_
    - _设计：Time Filter 时间过滤逻辑 2_

- [ ] 8. 日志记录器模块
  - [ ] 8.1 实现日志基础功能和统一 Schema
    - 实现日志级别过滤（DEBUG, INFO, WARN, ERROR）
    - 定义统一日志 Schema：timestamp, level, component, symbol, rule_hit, param_version, decision, message
    - 实现字段强校验，确保所有日志包含必需字段
    - 实现日志格式化
    - 支持输出到文件和 MT4 日志窗口
    - _需求：5.6, 5.7_
    - _设计：Logger 接口、Logger 日志格式_

  - [ ] 8.2 实现各类日志记录函数
    - LogParameterLoad - 记录参数加载（包含 param_version）
    - LogSignalEvaluation - 记录信号评估（包含 rule_hit, param_version, decision）
    - LogOrderOpen - 记录开仓（包含 symbol, param_version, decision）
    - LogOrderReject - 记录拒单（包含 symbol, rule_hit, param_version, decision）
    - LogCircuitBreaker - 记录熔断（必填字段：circuit_type, trigger_value, recover_at_utc, reason, rule_hit, decision）
    - LogOrderClose - 记录平仓（包含 symbol, decision）
    - 所有日志函数必须传递 rule_hit, param_version, decision 参数
    - _需求：5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 3.7_
    - _设计：Logger 接口、Logger 日志内容_

- [ ] 9. 持仓管理器模块
  - [ ] 9.1 实现持仓扫描
    - 实现 GetOpenPositions() 函数
    - 扫描所有持仓订单
    - _设计：Position Manager 接口_

  - [ ] 9.2 实现持仓状态检查
    - 实现 CheckPositions() 函数
    - 检查订单是否已平仓
    - 触发交易结果记录
    - _设计：Position Manager 持仓管理逻辑_

- [ ] 10. EA 主循环集成
  - [ ] 10.1 实现 OnInit 初始化
    - 加载参数包
    - 初始化所有模块
    - 验证配置
    - _需求：1.1_

  - [ ] 10.2 实现 OnTick 主逻辑
    - 检测 K 线变化
    - 定期检查参数更新
    - 评估入场信号
    - 执行开仓操作
    - 检查持仓状态
    - _需求：2.7, 8.3_

  - [ ] 10.3 实现 Dry Run 模式
    - 在 Dry Run 模式下跳过真实订单执行
    - 输出模拟交易信号到日志
    - 日志必须包含 "DryRun" 标识字段，明确标记为模拟模式
    - _需求：6.1, 6.2, 6.3, 6.4, 6.5_

  - [ ] 10.4 实现 OnDeinit 清理
    - 保存状态
    - 清理资源

- [ ] 11. Checkpoint - EA 核心功能完成
  - 确保所有 EA 模块测试通过
  - 确保参数加载、策略评估、风险管理、订单执行都正常工作
  - 询问用户是否有问题

- [ ] 12. Blockcell 参数生成器
  - [ ] 12.1 创建 forex_strategy_generator Skill
    - 创建 Rhai 脚本文件
    - 定义 generate_signal_pack 函数
    - _需求：7.1_
    - _设计：Blockcell Parameter Generator Skill 接口_

  - [ ] 12.2 实现 AI 技能调用
    - 调用 forex_news Skill
    - 调用 forex_analysis Skill
    - 调用 forex_strategy Skill
    - _需求：7.1_
    - _设计：Blockcell Parameter Generator Skill 接口 1-3_

  - [ ] 12.3 实现参数包构建
    - 构建包含所有必需字段的参数包
    - 使用 now_utc() 获取 UTC 时间
    - 使用 format_iso8601() 格式化时间
    - 生成唯一版本号
    - _需求：7.2, 7.3, 7.4_
    - _设计：Blockcell Parameter Generator Skill 接口 4_

  - [ ] 12.4 实现参数包保存
    - 保存到 workspace/ea/signal_pack.json
    - _需求：7.5_
    - _设计：Blockcell Parameter Generator Skill 接口 5_

  - [ ] 12.5 配置 Cron 定时任务
    - 配置每天 UTC 06:00 触发
    - 支持手动触发
    - _需求：7.6, 8.1, 8.2_
    - _设计：Blockcell Parameter Generator 定时触发_

- [ ] 13. Checkpoint - 系统集成测试
  - 确保 Blockcell 能成功生成参数包
  - 确保 EA 能成功加载参数包
  - 确保参数刷新机制正常工作
  - 询问用户是否有问题

- [ ] 14. 文档与部署
  - [ ] 14.1 编写参数协议文档
    - 记录 JSON 字段说明
    - 提供示例参数包
    - _交付物：参数协议文档_

  - [ ] 14.2 编写运行手册
    - 部署步骤
    - 参数路径配置
    - 故障处理指南
    - _交付物：运行手册_

  - [ ] 14.3 准备回测环境
    - 准备历史数据（6-12 个月）
    - 配置 MT4 Strategy Tester
    - _需求：9.1, 9.2_

  - [ ] 14.4 实现回测参数注入机制
    - 实现外部参数注入方式（通过 EA 输入参数）
    - 实现内嵌参数注入方式（硬编码到 EA）
    - 验证两种方式都能正常工作
    - _需求：9.5_

  - [ ] 14.5 验证回测与实盘逻辑一致性
    - 对比回测和实盘的决策路径
    - 确保使用相同的策略逻辑
    - 验证历史 K 线数据处理正确
    - _需求：9.2, 9.3, 9.6_

  - [ ] 14.6 执行回测
    - 运行回测
    - 生成回测报告
    - 验证无崩溃或异常下单
    - _需求：9.4, 9.7_
    - _交付物：回测报告_

- [ ] 15. Final Checkpoint - 验收
  - 验证所有验收标准
  - 确认所有交付物完成
  - 询问用户是否满意

## 注意事项

- 任务按依赖关系组织，建议按顺序执行
- 每个任务都引用了相关的需求和设计
- Checkpoint 任务用于阶段性验证和用户反馈
- 测试相关的子任务已标记，可根据需要调整优先级
- EA 使用 MQL4 语言，Blockcell 使用 Rhai 语言
