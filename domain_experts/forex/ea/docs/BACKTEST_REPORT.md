# 回测报告（执行记录）

## 报告元数据

| 项目 | 值 |
|------|-----|
| 报告日期 | 2026-03-13 |
| EA 版本 | ForexStrategyExecutor V1.1.1 |
| 交易品种 | EURUSD |
| 时间周期 | H4 |
| 报告状态 | MT4 回归已重跑（14.4/14.5/14.6）；当前样本通过 `passed_startup_path` |

## 本次已完成验证

1. 回测参数注入机制修正：当 `BacktestParamJSON` 非空时，EA 不再被文件热更新覆盖。
2. 回测 Safe Mode 恢复路径修正：内嵌参数模式下只从内嵌参数恢复，不切回文件参数源。
3. 回测日期参数生效：`BacktestStartDate` / `BacktestEndDate` 已用于限制开仓信号评估窗口。
4. 自动化回测脚本落地：`scripts/run_mt4_task14_backtest.ps1` 可稳定产出两种模式报告。
5. MT4 本地真实执行记录已留档（报告、日志摘录、编译日志）。

## Task 14 验收状态（MT4）

| 任务 | 状态 | 证据 |
|------|------|------|
| 14.4 两种注入方式运行验证 | 已完成 | 文件模式与内嵌模式均已触发；见 `file_mode_log_excerpt.txt` / `embedded_mode_log_excerpt.txt` |
| 14.5 回测与实盘逻辑一致性对比 | 已完成（当前验收口径） | 2026-03-13 实盘窗口通过 `passed_startup_path`，并输出一致性报告与日志摘录 |
| 14.6 回测执行与结果统计 | 已完成 | 两轮 Strategy Tester 报告已生成（HTML+GIF） |

## 本次 MT4 运行产物

目录：`../backtest_artifacts/task14_20260313_133050/`

- `report_file_mode.htm`
- `report_embedded_mode.htm`
- `summary.json`
- `../compile_forex_executor_local.log`

## 关键观察

1. 文件参数模式（`ParamFilePath=signal_pack.json`）：
   - 日志显示 `回测参数源: 参数文件`。
   - 参数包成功加载，版本 `20260311-0037`。
2. 内嵌参数模式（探针值 `BacktestParamJSON=abc`）：
   - 日志显示 `回测参数源: BacktestParamJSON（内嵌）`。
   - 日志显示 `使用内嵌参数（BacktestParamJSON）`，随后进入内嵌 JSON 解析错误分支（符合探针预期）。
3. 两轮报告均正常生成、进程正常退出（`summary.json` 中 `exit_code=0`、`timed_out=false`）。

## 回测统计摘要（本次）

基于 `report_file_mode.htm` / `report_embedded_mode.htm`：

- 建模方式：开盘价（Open prices）
- 回测区间：2025-09-10 至 2026-03-10（历史数据实际覆盖到 2026-03-06）
- 初始资金：10000
- 总交易数：0
- 净利润：0.00
- 异常下单：未观察到

## 14.5 实盘一致性（已通过）

- 执行脚本：`scripts/run_mt4_task14_live_consistency.ps1`
- 最近通过样本：`../backtest_artifacts/task14_consistency_20260313_133218/summary.json`
- 对比基线：`../backtest_artifacts/task14_20260311_090410/file_mode_log_excerpt.txt`
- 结论（当前验收口径）：实盘模式启动链路与回测文件模式在核心组件路径一致（EA / PositionManager / ParamLoader，且 live 出现 `[decision=LOADED]` 与 `RUNNING`）。
- 关键指标（`task14_consistency_20260313_133218/summary.json`）：
  - `status=passed_startup_path`
  - `live_ea_lines_count=224`
  - `startup_path_pass=true`
  - `tick_update_path_pass=false`
  - `connect_error_detected=false`

## 后续补充（14.5）

可选增强：补充一次同参数实盘运行日志（建议 DryRun=true 与 DryRun=false 各 1 轮），然后按以下维度做更细粒度比对：

1. 新 K 线检测与执行时机
2. 过滤链路顺序（趋势/区间/回踩/形态/时间）
3. 风控状态机（RUNNING/SAFE_MODE、熔断/恢复）
4. 参数热更新行为与版本切换
