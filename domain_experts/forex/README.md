# Forex 文档索引

## 目标

本索引用于统一 `domain_experts/forex` 下分散的 Markdown 文档入口，降低重复文档带来的查找和维护成本。

## 当前有效入口（优先阅读）

### EA 执行侧

- `ea/README.md`：EA 总览与状态
- `ea/docs/PARAMETER_PROTOCOL.md`：参数协议（JSON 契约）
- `ea/docs/OPERATION_MANUAL.md`：部署与运行手册
- `ea/docs/BACKTEST_REPORT.md`：Task 14 回测与一致性结果

### Blockcell Skill 侧

- `skills/forex_strategy_generator/README.md`：Skill 总览
- `skills/forex_strategy_generator/SKILL.md`：Skill 细节与接口
- `skills/forex_strategy_generator/CRON_SETUP.md`：Cron 配置
- `skills/forex_strategy_generator/ONLINE_STRICT_ACCEPTANCE_2026-03-10.md`：在线严格验收记录

## 历史/证据文档（按需查看）

- `ea/backtest_artifacts/**/CONSISTENCY_REPORT.md`
- `ea/backtest_artifacts/**/EVIDENCE.md`
- `ea/STATIC_REVIEW_FIXES.md`
- `skills/forex_strategy_generator/STATIC_REVIEW_FIXES.md`
- `skills/forex_strategy_generator/IMPLEMENTATION_SUMMARY.md`
- `skills/forex_strategy_generator/COMPLETION_REPORT.md`

说明：`backtest_artifacts` 目录包含多次重复运行生成的证据快照；日常阅读优先以 `ea/docs/BACKTEST_REPORT.md` 和最新验收记录为准。

## 文档维护约定

1. 新增功能文档优先写入 `ea/docs/` 或对应技能目录，避免散落在脚本目录。
2. 证据型文档（回测、一致性）保留原始快照，但需在主报告中给出“当前基准”链接。
3. 修改外部路径或目录结构后，必须执行一次本地 Markdown 链接检查。
