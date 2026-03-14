# EA Scripts

## Runner-Only 规则（重要）

- Task14 回测/一致性脚本默认只操作 `domain_experts/forex/ea/.mt4_portable_runner`。
- 不再依赖或读取 `AppData\Roaming\MetaQuotes\Terminal\...` 作为输入源。
- `run_mt4_task14_backtest.ps1` 会先把仓库中的 EA 源码同步到 runner，再在 runner 内执行编译与回测。

## 1) Copy EA Files To MT4

```powershell
pwsh -NoProfile -File "domain_experts/forex/ea/scripts/copy_to_mt4.ps1"
```

## 2) Batch Generate Historical Signal Packs

Script: `generate_historical_signal_packs.py`

### Dry-run preview (no file writes)

```powershell
python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --months 6 --dry-run
```

### Generate latest 6 months (daily)

```powershell
python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --months 6 --write-index
```

### Generate latest 12 months (daily, overwrite existing)

```powershell
python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --months 12 --overwrite --write-index
```

### Generate a fixed date range

```powershell
python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --start-date 2025-01-01 --end-date 2025-12-31 --write-index
```

### Output location

Default output directory:

`domain_experts/forex/ea/history/signal_packs/`

Generated file name pattern (default):

`signal_pack_{version}.json`

You can customize it:

```powershell
python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --months 6 --filename-pattern "pack_{date}_{version}.json"
```

## 3) Run MT4 Task 14 Backtests (Live MT4)

Script: `run_mt4_task14_backtest.ps1`

Default behavior:

- uses a portable runner under `domain_experts/forex/ea/.mt4_portable_runner/`
- syncs `ForexStrategyExecutor.mq4` + `include/*.mqh` from repo into runner
- compiles inside runner via `.\.mt4_portable_runner\metaeditor.exe`
- runs two cases:
  - `file_mode`: load from `signal_pack.json` in `tester/files`
  - `embedded_mode`: uses `BacktestParamJSON` probe to verify embedded branch
- writes artifacts under `domain_experts/forex/ea/backtest_artifacts/task14_YYYYMMDD_HHMMSS/`

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_task14_backtest.ps1"
```

Use full embedded JSON mode (if your MT4 input length allows):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_task14_backtest.ps1" -UseFullEmbeddedJson
```

Skip compile and reuse existing `ForexStrategyExecutor.ex4` in runner:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_task14_backtest.ps1" -SkipCompile
```

## 3.5) Run Magic Number Auto Tests (Headless)

Script: `run_mt4_magic_number_tests.ps1`

What it does:

- syncs `tests/TestMagicNumberBugEA.mq4` + `include/*.mqh` into runner
- compiles `TestMagicNumberBugEA.mq4` via `metaeditor.exe`
- runs Strategy Tester once in portable runner
- before launching, checks whether runner `terminal.exe` is already running with the same config (or same runner instance) and aborts to avoid artifact/log conflicts
- parses tester logs for:
  - `AUTO_TEST_SUMMARY: explore_pass=... explore_fail=... preserve_pass=... preserve_fail=... total_fail=...`
  - `AUTO_TEST_RESULT: PASS|FAIL`
- exits non-zero on test failure / timeout / missing summary

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_magic_number_tests.ps1"
```

Skip compile and reuse existing `TestMagicNumberBugEA.ex4`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_magic_number_tests.ps1" -SkipCompile
```

Artifacts:

- `domain_experts/forex/ea/backtest_artifacts/magic_number_tests_YYYYMMDD_HHMMSS/`
- contains `summary.json`, compile log, copied tester logs, and report file

## 4) Run Task 14.5 Live-vs-Backtest Consistency Check

Script: `run_mt4_task14_live_consistency.ps1`

What it does:

- starts MT4 in live chart mode (not Strategy Tester) with `ForexStrategyExecutor`
- reuses current terminal login state (no hard-coded account in config)
- captures fresh `MQL4/Logs` entries for the EA
- compares startup + parameter-load path against latest backtest file-mode excerpt
- writes evidence under `domain_experts/forex/ea/backtest_artifacts/task14_consistency_YYYYMMDD_HHMMSS/`

Run (recommended):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_task14_live_consistency.ps1" -CaptureSec 60
```

For short-window OnTick evidence, lower parameter refresh interval to 60s:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_task14_live_consistency.ps1" -CaptureSec 240 -ParamCheckIntervalSec 60
```

If MT4 is already manually started and connected, collect-only mode (no relaunch):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_task14_live_consistency.ps1" -NoLaunch -CaptureSec 180 -ParamCheckIntervalSec 60
```

Notes:

- default mode (`without -NoLaunch`) will start MT4 and close that spawned terminal after capture.
- `-NoLaunch` mode never closes your manually opened MT4 terminal.
- if `-BacktestFileModeExcerpt` points to a very large tester log, tune parse window with `-BacktestParseMaxLines` (default `8000`) to keep runtime stable.

If needed, specify a fixed backtest excerpt:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_task14_live_consistency.ps1" -CaptureSec 60 -BacktestFileModeExcerpt "domain_experts/forex/ea/backtest_artifacts/task14_20260311_090410/file_mode_log_excerpt.txt"
```

Optional: pass account fields directly (if you do not want to rely on current saved login state):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_task14_live_consistency.ps1" -CaptureSec 120 -Login "12345678" -Password "<password>" -Server "ICMarketsSC-Demo03"
```

Security note: if `-Login/-Password` are provided, the script scrubs `Password=` in the generated config file after run.

Manual-start friendly modes (same script):

- `-PrepareOnly`: only generate `.ini/.set` and print exact MT4 launch command; does not start terminal.
- `-LaunchOnly`: starts MT4 with Task14 config and exits immediately; does not capture logs and does not close MT4.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_task14_live_consistency.ps1" -PrepareOnly
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_task14_live_consistency.ps1" -LaunchOnly
```

### 中文说明（Task 14.5 实盘一致性）

- 默认模式（不加 `-NoLaunch`）会拉起一个 MT4 进程，采集结束后会尝试关闭这个“脚本拉起的”终端。
- 采集你手动已登录的 MT4，请使用 `-NoLaunch`；该模式不会关闭你手动打开的 MT4。
- 如果 `-BacktestFileModeExcerpt` 指向很大的 tester 日志，建议保留默认 `-BacktestParseMaxLines 8000`，避免解析阶段过慢。

推荐命令（手动登录 MT4 后执行）：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_task14_live_consistency.ps1" -NoLaunch -CaptureSec 240 -ParamCheckIntervalSec 60 -BacktestFileModeExcerpt "C:\Users\ireke\Documents\GitHub\blockcell\domain_experts\forex\ea\.mt4_portable_runner\tester\logs\20260311.log"
```

如何判断“跑完”：

- 控制台出现 `==== Task 14.5 Live Consistency Summary ====`
- 并输出 `summary_json/report_md/live_excerpt/runner_excerpt` 路径
- 总时长通常约为 `CaptureSec + 2~10 秒`

常见状态说明：

- `passed_startup_path` / `passed_startup_and_tick_update_path`：已拿到有效一致性证据
- `failed_no_live_logs`：采集窗口内没抓到 EA 新日志（常见于图表未挂 EA、自动交易权限未开、窗口内无新 tick）

一键版（自动 `-NoLaunch` + 重试）：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_task14_live_consistency_ready.ps1" -CaptureSec 300 -ParamCheckIntervalSec 60 -MaxAttempts 3 -RetryDelaySec 20 -BacktestFileModeExcerpt "C:\Users\ireke\Documents\GitHub\blockcell\domain_experts\forex\ea\.mt4_portable_runner\tester\logs\20260311.log"
```

## 5) Continuous Signal Pack Sync (运营持续同步)

Script: `sync_signal_pack_continuous.ps1`

What it does:

- startup: immediate full sync
- runtime: poll source file and sync only when content changes
- singleton lock: same `RunnerDir` only allows one sync process; duplicate instances exit immediately
- targets:
  - `.mt4_portable_runner/MQL4/Files/signal_pack.json`
  - `.mt4_portable_runner/tester/files/signal_pack.json`
- logs:
  - default: `domain_experts/forex/ea/backtest_artifacts/signal_sync.log`
  - includes UTC timestamp and parameter `version` when parseable

Run continuously (recommended):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/sync_signal_pack_continuous.ps1" -PollIntervalSeconds 30
```

Run once (manual repair):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/sync_signal_pack_continuous.ps1" -RunOnce
```

Specify source/runner path explicitly:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/sync_signal_pack_continuous.ps1" -SourceSignalPackPath "C:\Users\ireke\.blockcell\workspace\domain_experts\forex\ea\signal_pack.json" -RunnerDir "C:\Users\ireke\Documents\GitHub\blockcell\domain_experts\forex\ea\.mt4_portable_runner" -PollIntervalSeconds 20
```

Tips:

- stop sync service with `Ctrl + C`
- for startup recovery, prefer `-RunOnce` before mounting EA chart
- if sync fails, check `signal_sync.log` and verify both source file and runner directory permissions

## 6) Register Auto-Start Sync Task (任务计划)

Script: `register_signal_pack_sync_task.ps1`

Install task (at user logon):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_signal_pack_sync_task.ps1" -Action Install -StartNow
```

Check task status:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_signal_pack_sync_task.ps1" -Action Status
```

Run task immediately:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_signal_pack_sync_task.ps1" -Action RunNow
```

Remove task:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_signal_pack_sync_task.ps1" -Action Remove
```

Stop service + cleanup auto-start artifacts:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_signal_pack_sync_task.ps1" -Action Stop
```

Stop only a specific runner instance:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_signal_pack_sync_task.ps1" -Action Stop -RunnerDir "C:\Users\ireke\Documents\GitHub\blockcell\domain_experts\forex\ea\.mt4_portable_runner"
```

Install with custom source/runner:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_signal_pack_sync_task.ps1" -Action Install -SourceSignalPackPath "C:\Users\ireke\.blockcell\workspace\domain_experts\forex\ea\signal_pack.json" -RunnerDir "C:\Users\ireke\Documents\GitHub\blockcell\domain_experts\forex\ea\.mt4_portable_runner" -PollIntervalSeconds 20 -StartNow
```

Notes:

- `Status` will explicitly report `无权限读取（可能存在）` when Task Scheduler read is blocked by OS permissions.
- `Stop` removes task/launcher and then stops running `sync_signal_pack_continuous.ps1` processes when permissions allow.

## 7) Verify Signal Sync Health (同步健康检查)

Script: `verify_signal_sync.ps1`

What it checks:

- source/live/tester file existence
- SHA256 hash consistency
- `version` consistency
- source/target mtime delta (`-MaxMtimeDiffSeconds`)
- optional stale check (`-MaxAgeMinutes`)
- optional validity window check (`-RequireCurrentValidWindow`)

Health result semantics:

- `-RequireCurrentValidWindow` enabled: `valid_from/valid_to` violations are hard failures (`RESULT=FAILED`).
- `-RequireCurrentValidWindow` disabled: expired `valid_to` only produces `WARNINGS`, and does not fail by itself.
- business meaning: disabled mode is for "sync continuity monitoring" (file distribution health), not for "trading readiness gate".
- hash mismatch failure now prints per-file hash prefixes for quick triage (e.g. `source=abc123..., live_target=...`).

Run (default):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/verify_signal_sync.ps1"
```

Run with strict checks (recommended for monitoring):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/verify_signal_sync.ps1" -RequireCurrentValidWindow -MaxAgeMinutes 240 -MaxMtimeDiffSeconds 300
```

Custom source/runner:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/verify_signal_sync.ps1" -SourceSignalPackPath "C:\Users\ireke\.blockcell\workspace\domain_experts\forex\ea\signal_pack.json" -RunnerDir "C:\Users\ireke\Documents\GitHub\blockcell\domain_experts\forex\ea\.mt4_portable_runner"
```

Exit code:

- `0`: all checks passed
- `2`: check failed (suitable for CI/cron alerting)

## 8) Register Health-Check Task (周期监控任务)

Scripts:

- `run_signal_sync_health_check.ps1` (执行一次健康检查并写 health/alert 日志)
- `register_signal_sync_health_task.ps1` (注册/查询/触发/删除任务计划)

Install periodic task (every 5 minutes):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_signal_sync_health_task.ps1" -Action Install -IntervalMinutes 5 -StartNow
```

Install with log rotation tuning (example: 512KB, keep 14 backups):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_signal_sync_health_task.ps1" -Action Install -IntervalMinutes 5 -MaxLogSizeKB 512 -MaxLogBackups 14 -StartNow
```

Status:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_signal_sync_health_task.ps1" -Action Status
```

Run once immediately:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_signal_sync_health_task.ps1" -Action RunNow
```

Remove:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_signal_sync_health_task.ps1" -Action Remove
```

Health-check logs:

- health log: `domain_experts/forex/ea/backtest_artifacts/signal_sync_health.log`
- alert log: `domain_experts/forex/ea/backtest_artifacts/signal_sync_alert.log`
- rotated files: `.1`, `.2`, ... (e.g. `signal_sync_health.log.1`)

Notes:

- `register_signal_sync_health_task.ps1` requires permission to read/write Task Scheduler; without permission, `Status` reports `无权限读取（可能存在）`.
- default threshold includes `-MaxAgeMinutes 240`, so stale signal packs will intentionally produce `RESULT=FAILED` and write alerts.
- production recommendation: keep `-RequireCurrentValidWindow=true` for scheduled health tasks when alerting should represent tradability.
- log rotation defaults: `-MaxLogSizeKB 1024` and `-MaxLogBackups 10`; set `-MaxLogSizeKB 0` to disable rotation.

## 9) Runner Log Cleanup Task (按天数/总大小清理)

Scripts:

- `cleanup_runner_logs.ps1` (执行一次清理：先按保留天数删旧，再按总大小上限继续淘汰最旧文件)
- `register_runner_log_cleanup_task.ps1` (注册/查询/触发/删除周期清理任务)

Default cleanup scope (relative to `.mt4_portable_runner`):

- `logs`
- `MQL4/Logs`
- `tester/logs`

Install periodic cleanup task (default every 180 minutes, task path `\blockcell\`):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_runner_log_cleanup_task.ps1" -Action Install -RetentionDays 14 -MaxTotalSizeMB 1024 -IntervalMinutes 180 -StartNow
```

Install with tighter limits (example: keep 7 days, cap 512MB, run every 60 minutes):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_runner_log_cleanup_task.ps1" -Action Install -RetentionDays 7 -MaxTotalSizeMB 512 -IntervalMinutes 60 -StartNow
```

Status:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_runner_log_cleanup_task.ps1" -Action Status
```

Run once immediately:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_runner_log_cleanup_task.ps1" -Action RunNow
```

Remove:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/register_runner_log_cleanup_task.ps1" -Action Remove
```

Manual dry run (no file deletion):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/cleanup_runner_logs.ps1" -RetentionDays 7 -MaxTotalSizeMB 512 -DryRun
```

## 10) Run Magic Number Auto Tests (Headless)

Script: `run_mt4_magic_number_tests.ps1`

What it does:

- syncs `tests/TestMagicNumberBugEA.mq4` + `include/*.mqh` into runner
- compiles `TestMagicNumberBugEA.mq4` via `metaeditor.exe`
- runs the EA in Strategy Tester (headless); tests execute in `OnInit`
- parses `AUTO_TEST_SUMMARY` / `AUTO_TEST_RESULT` from tester log
- exits with error (throw) if any test fails or log is missing
- writes artifacts under `backtest_artifacts/magic_number_tests_YYYYMMDD_HHMMSS/`

Expected result: `explore: 3 pass / 0 fail`, `preserve: 5 pass / 0 fail`, `auto_result: PASS`

Run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_magic_number_tests.ps1"
```

Skip recompile (reuse existing `.ex4`):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_magic_number_tests.ps1" -SkipCompile
```

Custom runner path:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "domain_experts/forex/ea/scripts/run_mt4_magic_number_tests.ps1" -RunnerDir "C:\path\to\runner"
```
