[CmdletBinding()]
param(
    [string]$RunnerDir = "",
    [string]$SourceSignalPackPath = "C:\Users\ireke\.blockcell\workspace\domain_experts\forex\ea\signal_pack.json",
    [string]$BacktestFileModeExcerpt = "",
    [string]$Symbol = "EURUSD",
    [string]$Period = "H4",
    [int]$CaptureSec = 180,
    [int]$ParamCheckIntervalSec = 300,
    [int]$BacktestParseMaxLines = 8000,
    [string]$Login = "",
    [string]$Password = "",
    [string]$Server = "",
    [switch]$PrepareOnly,
    [switch]$LaunchOnly,
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-File([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }
}

function Assert-Dir([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label not found: $Path"
    }
}

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-AsciiFile([string]$Path, [string]$Content) {
    $dir = Split-Path -Path $Path -Parent
    Ensure-Dir -Path $dir
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::ASCII)
}

function Scrub-PasswordInConfig([string]$ConfigPath, [bool]$Enabled) {
    if (-not $Enabled) { return }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return }

    $cfgLines = Get-Content -Path $ConfigPath
    $sanitized = @()
    foreach ($line in $cfgLines) {
        if ($line -like "Password=*") {
            $sanitized += "Password="
        } else {
            $sanitized += $line
        }
    }
    Write-AsciiFile -Path $ConfigPath -Content (($sanitized -join "`r`n") + "`r`n")
}

function Get-LineCount([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 0
    }
    return (@(Get-Content -Path $Path)).Count
}

function Get-LatestFile([string]$Dir, [string]$Filter) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        return $null
    }
    return Get-ChildItem -Path $Dir -File -Filter $Filter -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-NewLines(
    [string]$BeforePath,
    [int]$BeforeLineCount,
    [string]$AfterPath
) {
    if (-not (Test-Path -LiteralPath $AfterPath -PathType Leaf)) {
        return @()
    }

    $afterLines = @(Get-Content -Path $AfterPath)
    if ([string]::Equals($BeforePath, $AfterPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($BeforeLineCount -lt $afterLines.Count) {
            return $afterLines[$BeforeLineCount..($afterLines.Count - 1)]
        }
        return @()
    }
    return $afterLines
}

function Parse-EaEvents([string[]]$Lines) {
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $Lines) {
        if ($line -notmatch "ForexStrategyExecutor") { continue }

        $level = ""
        if ($line -match "\[(DEBUG|INFO|WARN|ERROR)\]") {
            $level = $Matches[1]
        }

        $component = ""
        if ($line -match "\[(EA|ParamLoader|PositionManager|RiskMgr|Strategy|OrderExec|TimeFilter)\]") {
            $component = $Matches[1]
        }

        $decision = ""
        if ($line -match "\[decision=([^\]]+)\]") {
            $decision = $Matches[1]
        }

        $version = ""
        if ($line -match "\[version=([^\]]+)\]") {
            $version = $Matches[1]
        }

        $rule = ""
        if ($line -match "\[rule=([^\]]+)\]") {
            $rule = $Matches[1]
        }

        $events.Add([pscustomobject]@{
            level     = $level
            component = $component
            decision  = $decision
            version   = $version
            rule      = $rule
            raw       = $line
        }) | Out-Null
    }
    return @($events)
}

function Find-LatestBacktestExcerpt([string]$RepoEaRoot) {
    $artifactsRoot = Join-Path $RepoEaRoot "backtest_artifacts"
    if (-not (Test-Path -LiteralPath $artifactsRoot -PathType Container)) {
        return ""
    }

    $strictCandidate = Get-ChildItem -Path $artifactsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^task14_\d{8}_\d{6}$" } |
        Sort-Object Name -Descending |
        ForEach-Object {
            $file = Join-Path $_.FullName "file_mode_log_excerpt.txt"
            if (Test-Path -LiteralPath $file -PathType Leaf) { $file } else { $null }
        } |
        Where-Object { $_ -ne $null } |
        Select-Object -First 1
    if ($null -ne $strictCandidate) {
        return $strictCandidate
    }

    $fallback = Get-ChildItem -Path $artifactsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "task14_*" -and $_.Name -notlike "task14_consistency_*" } |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            $file = Join-Path $_.FullName "file_mode_log_excerpt.txt"
            if (Test-Path -LiteralPath $file -PathType Leaf) { $file } else { $null }
        } |
        Where-Object { $_ -ne $null } |
        Select-Object -First 1

    if ($null -eq $fallback) { return "" }
    return $fallback
}

$repoEaRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($RunnerDir)) {
    $RunnerDir = Join-Path $repoEaRoot ".mt4_portable_runner"
}

$requireBacktestCompare = (-not $PrepareOnly) -and (-not $LaunchOnly)
if ($requireBacktestCompare -and [string]::IsNullOrWhiteSpace($BacktestFileModeExcerpt)) {
    $BacktestFileModeExcerpt = Find-LatestBacktestExcerpt -RepoEaRoot $repoEaRoot
}

Assert-Dir -Path $RunnerDir -Label "MT4 portable runner dir"
Assert-File -Path (Join-Path $RunnerDir "terminal.exe") -Label "terminal.exe"
Assert-File -Path $SourceSignalPackPath -Label "signal_pack.json"
if ($ParamCheckIntervalSec -lt 60) {
    throw "ParamCheckIntervalSec must be >= 60"
}
if ($BacktestParseMaxLines -lt 500) {
    throw "BacktestParseMaxLines must be >= 500"
}
if ($LaunchOnly -and $NoLaunch) {
    throw "LaunchOnly and NoLaunch cannot be used together."
}
if ($PrepareOnly -and $LaunchOnly) {
    throw "PrepareOnly and LaunchOnly cannot be used together."
}
if ($requireBacktestCompare) {
    if ([string]::IsNullOrWhiteSpace($BacktestFileModeExcerpt)) {
        throw "No backtest file_mode excerpt found. Run scripts/run_mt4_task14_backtest.ps1 first."
    }
    Assert-File -Path $BacktestFileModeExcerpt -Label "backtest file_mode log excerpt"
} elseif (-not [string]::IsNullOrWhiteSpace($BacktestFileModeExcerpt)) {
    Assert-File -Path $BacktestFileModeExcerpt -Label "backtest file_mode log excerpt"
}

$runnerMqlFilesDir = Join-Path $RunnerDir "MQL4\Files"
$runnerTesterFilesDir = Join-Path $RunnerDir "tester\files"
$runnerPresetsDir = Join-Path $RunnerDir "MQL4\Presets"
$runnerConfigDir = Join-Path $RunnerDir "config"
$runnerLogsDir = Join-Path $RunnerDir "logs"
$runnerMqlLogsDir = Join-Path $RunnerDir "MQL4\Logs"

Ensure-Dir -Path $runnerMqlFilesDir
Ensure-Dir -Path $runnerTesterFilesDir
Ensure-Dir -Path $runnerPresetsDir
Ensure-Dir -Path $runnerConfigDir
Ensure-Dir -Path $runnerLogsDir
Ensure-Dir -Path $runnerMqlLogsDir

$runnerSignalPackLive = Join-Path $runnerMqlFilesDir "signal_pack.json"
$runnerSignalPackTester = Join-Path $runnerTesterFilesDir "signal_pack.json"
Copy-Item -LiteralPath $SourceSignalPackPath -Destination $runnerSignalPackLive -Force
Copy-Item -LiteralPath $SourceSignalPackPath -Destination $runnerSignalPackTester -Force

$liveSetFile = Join-Path $runnerPresetsDir "task14_live_consistency.set"
$liveSetContent = @(
    "ParamFilePath=signal_pack.json"
    "DryRun=true"
    "LogLevel=DEBUG"
    "ParamCheckInterval=$ParamCheckIntervalSec"
    "AutoDetectUTCOffset=true"
    "ServerUTCOffset=2"
    "BacktestParamJSON="
    "BacktestStartDate="
    "BacktestEndDate="
) -join "`r`n"
Write-AsciiFile -Path $liveSetFile -Content ($liveSetContent + "`r`n")

$liveConfigFile = Join-Path $runnerConfigDir "task14_live_consistency.ini"
$liveConfigLines = @()
if (-not [string]::IsNullOrWhiteSpace($Login)) {
    $liveConfigLines += @(
        "[Common]"
        "Login=$Login"
        "Password=$Password"
        "Server=$Server"
        "ProxyEnable=0"
        ""
    )
}
$liveConfigLines += @(
    "[Experts]"
    "Enabled=1"
    "AllowLiveTrading=0"
    "AllowDllImport=1"
    "AllowWebRequest=1"
    "Expert=ForexStrategyExecutor"
    "ExpertParameters=task14_live_consistency.set"
    "Symbol=$Symbol"
    "Period=$Period"
    "Template=default"
    "ShutdownTerminal=false"
)
$liveConfigContent = $liveConfigLines -join "`r`n"
Write-AsciiFile -Path $liveConfigFile -Content ($liveConfigContent + "`r`n")

$terminalPath = Join-Path $RunnerDir "terminal.exe"
$terminalArgs = @("/portable", "/skipupdate", $liveConfigFile)
$launchCommand = "`"$terminalPath`" /portable /skipupdate `"$liveConfigFile`""
$credentialsProvided = -not [string]::IsNullOrWhiteSpace($Login)

if ($PrepareOnly) {
    Scrub-PasswordInConfig -ConfigPath $liveConfigFile -Enabled $credentialsProvided
    Write-Host ""
    Write-Host "==== Task 14.5 Live Consistency Prepare Only ===="
    Write-Host "status: prepared_only"
    Write-Host "config_ini: $liveConfigFile"
    Write-Host "set_file: $liveSetFile"
    Write-Host "runner_dir: $RunnerDir"
    Write-Host "launch_command: $launchCommand"
    Write-Host "note: run launch_command manually, then use -NoLaunch mode to capture."
    return
}

if ($LaunchOnly) {
    $proc = Start-Process -FilePath $terminalPath -ArgumentList $terminalArgs -PassThru
    Scrub-PasswordInConfig -ConfigPath $liveConfigFile -Enabled $credentialsProvided
    Write-Host ""
    Write-Host "==== Task 14.5 Live Consistency Launch Only ===="
    Write-Host "status: launched_only"
    Write-Host "terminal_pid: $($proc.Id)"
    Write-Host "config_ini: $liveConfigFile"
    Write-Host "set_file: $liveSetFile"
    Write-Host "runner_dir: $RunnerDir"
    Write-Host "launch_command: $launchCommand"
    Write-Host "note: script exits now and will not close MT4."
    return
}

$artifactRoot = Join-Path $repoEaRoot ("backtest_artifacts\task14_consistency_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Ensure-Dir -Path $artifactRoot

$beforeRunnerLog = Get-LatestFile -Dir $runnerLogsDir -Filter "*.log"
$beforeMqlLog = Get-LatestFile -Dir $runnerMqlLogsDir -Filter "*.log"
$beforeRunnerLineCount = if ($null -eq $beforeRunnerLog) { 0 } else { Get-LineCount -Path $beforeRunnerLog.FullName }
$beforeMqlLineCount = if ($null -eq $beforeMqlLog) { 0 } else { Get-LineCount -Path $beforeMqlLog.FullName }

$startAt = Get-Date
if ($NoLaunch) {
    Start-Sleep -Seconds $CaptureSec
} else {
    $proc = Start-Process -FilePath $terminalPath -ArgumentList $terminalArgs -PassThru
    Start-Sleep -Seconds $CaptureSec
    $stillRunning = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if ($stillRunning) {
        $null = $stillRunning.CloseMainWindow()
        Start-Sleep -Seconds 5
        $stillRunning = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($stillRunning) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
$endAt = Get-Date

$afterRunnerLog = Get-LatestFile -Dir $runnerLogsDir -Filter "*.log"
$afterMqlLog = Get-LatestFile -Dir $runnerMqlLogsDir -Filter "*.log"
Scrub-PasswordInConfig -ConfigPath $liveConfigFile -Enabled $credentialsProvided

$beforeRunnerPath = if ($null -eq $beforeRunnerLog) { "" } else { $beforeRunnerLog.FullName }
$beforeMqlPath = if ($null -eq $beforeMqlLog) { "" } else { $beforeMqlLog.FullName }
$liveLogFilePath = if ($null -eq $afterMqlLog) { "" } else { $afterMqlLog.FullName }
$runnerLogFilePath = if ($null -eq $afterRunnerLog) { "" } else { $afterRunnerLog.FullName }

$newRunnerLines = if ($null -eq $afterRunnerLog) { @() } else {
    Get-NewLines -BeforePath $beforeRunnerPath `
        -BeforeLineCount $beforeRunnerLineCount `
        -AfterPath $runnerLogFilePath
}
$newMqlLines = if ($null -eq $afterMqlLog) { @() } else {
    Get-NewLines -BeforePath $beforeMqlPath `
        -BeforeLineCount $beforeMqlLineCount `
        -AfterPath $liveLogFilePath
}
$newRunnerLines = @($newRunnerLines)
$newMqlLines = @($newMqlLines)

$liveEaLines = @($newMqlLines | Where-Object { $_ -match "ForexStrategyExecutor" })
$connectErrorLines = @($newRunnerLines | Where-Object { $_ -match "connect failed|invalid|帐户无效|account invalid" })
$loginSuccessLines = @($newRunnerLines | Where-Object { $_ -match "login on .* through|login datacenter on" })
$liveTickUpdateLines = @($liveEaLines | Where-Object { $_ -match "CheckParameterUpdate|定期检查参数更新" })

$liveExcerptPath = Join-Path $artifactRoot "live_mode_log_excerpt.txt"
$runnerExcerptPath = Join-Path $artifactRoot "runner_log_excerpt.txt"
$liveAllNewPath = Join-Path $artifactRoot "live_mode_all_new_lines.txt"

Set-Content -Path $liveAllNewPath -Value $newMqlLines -Encoding utf8
Set-Content -Path $liveExcerptPath -Value $liveEaLines -Encoding utf8
Set-Content -Path $runnerExcerptPath -Value $newRunnerLines -Encoding utf8

$btLines = @(Get-Content -Path $BacktestFileModeExcerpt -TotalCount $BacktestParseMaxLines)
$btSampleMaybeTruncated = ($btLines.Count -ge $BacktestParseMaxLines)
$btEvents = Parse-EaEvents -Lines $btLines
$liveEvents = Parse-EaEvents -Lines $liveEaLines

$btComponents = @($btEvents | Where-Object { $_.component -ne "" } | ForEach-Object { $_.component })
$liveComponents = @($liveEvents | Where-Object { $_.component -ne "" } | ForEach-Object { $_.component })

$prefixRequired = 10
$prefixCompared = [Math]::Min($btComponents.Count, $liveComponents.Count)
$prefixMatched = 0
for ($i = 0; $i -lt $prefixCompared; $i++) {
    if ($btComponents[$i] -eq $liveComponents[$i]) {
        $prefixMatched++
    } else {
        break
    }
}

$btLoaded = [bool]($btLines -match "\[decision=LOADED\]")
if (-not $btLoaded) {
    $btLoaded = [bool](Select-String -Path $BacktestFileModeExcerpt -Pattern "\[decision=LOADED\]" -Quiet)
}
$liveLoaded = $liveEaLines -match "\[decision=LOADED\]"
$btRunning = [bool]($btLines -match "RUNNING")
if (-not $btRunning) {
    $btRunning = [bool](Select-String -Path $BacktestFileModeExcerpt -Pattern "RUNNING" -Quiet)
}
$liveRunning = $liveEaLines -match "RUNNING"
$loginErrorDetected = ($connectErrorLines.Count -gt 0)
$loginRecovered = ($loginSuccessLines.Count -gt 0)
$btHasDecisionMarker = [bool]($btLines -match "\[decision=")
if (-not $btHasDecisionMarker) {
    $btHasDecisionMarker = [bool](Select-String -Path $BacktestFileModeExcerpt -Pattern "\[decision=" -Quiet)
}
$btTickUpdateLines = @($btLines | Where-Object { $_ -match "CheckParameterUpdate|定期检查参数更新" })
if ($btTickUpdateLines.Count -eq 0) {
    if (Select-String -Path $BacktestFileModeExcerpt -Pattern "CheckParameterUpdate|定期检查参数更新" -Quiet) {
        # Keep lightweight count semantics in large-log mode: >0 means marker exists.
        $btTickUpdateLines = @("CheckParameterUpdate")
    }
}

$requiredComponents = @("EA", "PositionManager", "ParamLoader")
$requiredComponentsMatch = $true
foreach ($c in $requiredComponents) {
    if ((-not ($btComponents -contains $c)) -or (-not ($liveComponents -contains $c))) {
        $requiredComponentsMatch = $false
        break
    }
}
$startupPathPass = ($liveLoaded -and $liveRunning -and $requiredComponentsMatch)
$tickUpdatePathPass = ($btTickUpdateLines.Count -gt 0 -and $liveTickUpdateLines.Count -gt 0)

$status = "failed_no_live_logs"
if ($liveEaLines.Count -gt 0) {
    if ($startupPathPass -and $tickUpdatePathPass -and $loginErrorDetected -and $loginRecovered) {
        $status = "passed_startup_and_tick_update_after_reconnect"
    } elseif ($startupPathPass -and $tickUpdatePathPass) {
        $status = "passed_startup_and_tick_update_path"
    } elseif ($startupPathPass -and $loginErrorDetected -and $loginRecovered) {
        $status = "passed_startup_path_after_reconnect"
    } elseif ($startupPathPass -and $loginErrorDetected) {
        $status = "passed_startup_path_with_connect_warning"
    } elseif ($startupPathPass) {
        $status = "passed_startup_path"
    } elseif ($loginErrorDetected) {
        $status = "failed_login_or_connect"
    } else {
        $status = "partial_mismatch_or_incomplete"
    }
}

$launchMode = if ($NoLaunch) { "no_launch_collect_only" } else { "spawn_terminal" }

$summary = [ordered]@{
    run_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    capture_start_local = $startAt.ToString("yyyy-MM-dd HH:mm:ss")
    capture_end_local = $endAt.ToString("yyyy-MM-dd HH:mm:ss")
    capture_seconds = $CaptureSec
    param_check_interval_sec = $ParamCheckIntervalSec
    backtest_parse_max_lines = $BacktestParseMaxLines
    backtest_sample_lines = $btLines.Count
    backtest_sample_maybe_truncated = [bool]$btSampleMaybeTruncated
    launch_mode = $launchMode
    symbol = $Symbol
    period = $Period
    source_signal_pack = $SourceSignalPackPath
    backtest_file_mode_excerpt = $BacktestFileModeExcerpt
    runner_dir = $RunnerDir
    artifact_dir = $artifactRoot
    live_log_file = $liveLogFilePath
    runner_log_file = $runnerLogFilePath
    live_ea_lines_count = $liveEaLines.Count
    runner_new_lines_count = $newRunnerLines.Count
    connect_error_lines_count = $connectErrorLines.Count
    connect_error_detected = $loginErrorDetected
    login_success_lines_count = $loginSuccessLines.Count
    login_recovered = [bool]$loginRecovered
    startup_path_pass = [bool]$startupPathPass
    tick_update_path_pass = [bool]$tickUpdatePathPass
    live_tick_update_lines_count = $liveTickUpdateLines.Count
    backtest_tick_update_lines_count = $btTickUpdateLines.Count
    backtest_has_decision_marker = [bool]$btHasDecisionMarker
    marker_backtest_loaded = [bool]$btLoaded
    marker_live_loaded = [bool]$liveLoaded
    marker_backtest_running = [bool]$btRunning
    marker_live_running = [bool]$liveRunning
    required_components = $requiredComponents
    required_components_match = [bool]$requiredComponentsMatch
    component_prefix_required = $prefixRequired
    component_prefix_compared = $prefixCompared
    component_prefix_matched = $prefixMatched
    status = $status
}

$summaryPath = Join-Path $artifactRoot "summary.json"
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding utf8

$reportPath = Join-Path $artifactRoot "CONSISTENCY_REPORT.md"
$reportLines = @(
    "# Task 14.5 Live vs Backtest Consistency"
    ""
    "- run_at_utc: $($summary.run_at_utc)"
    "- status: $status"
    "- capture_window_local: $($summary.capture_start_local) ~ $($summary.capture_end_local)"
    "- live_ea_lines_count: $($summary.live_ea_lines_count)"
    "- connect_error_detected: $($summary.connect_error_detected)"
    "- login_recovered: $($summary.login_recovered)"
    "- startup_path_pass: $($summary.startup_path_pass)"
    "- tick_update_path_pass: $($summary.tick_update_path_pass)"
    "- live_tick_update_lines_count: $($summary.live_tick_update_lines_count)"
    "- backtest_tick_update_lines_count: $($summary.backtest_tick_update_lines_count)"
    ""
    "## Marker Check"
    ""
    "- backtest has decision markers: $($summary.backtest_has_decision_marker)"
    "- backtest decision=LOADED: $($summary.marker_backtest_loaded)"
    "- live decision=LOADED: $($summary.marker_live_loaded)"
    "- backtest RUNNING: $($summary.marker_backtest_running)"
    "- live RUNNING: $($summary.marker_live_running)"
    "- required components match (EA/PositionManager/ParamLoader): $($summary.required_components_match)"
    "- component prefix matched: $($summary.component_prefix_matched) / $($summary.component_prefix_compared)"
    ""
    "## Files"
    ""
    "- summary: $summaryPath"
    "- live excerpt: $liveExcerptPath"
    "- runner excerpt: $runnerExcerptPath"
    "- backtest excerpt: $BacktestFileModeExcerpt"
    ""
    "## Notes"
    ""
    "- This script validates startup/parameter-load path consistency in live mode vs backtest file-mode logs."
    "- If connect_error_detected=true, log in once on MT4 terminal and rerun this script."
)
Set-Content -Path $reportPath -Value $reportLines -Encoding utf8

Write-Host ""
Write-Host "==== Task 14.5 Live Consistency Summary ===="
Write-Host "status: $status"
Write-Host "artifact_dir: $artifactRoot"
Write-Host "summary_json: $summaryPath"
Write-Host "report_md: $reportPath"
Write-Host "live_excerpt: $liveExcerptPath"
Write-Host "runner_excerpt: $runnerExcerptPath"
if ($loginErrorDetected -and -not $loginRecovered) {
    Write-Warning "Detected connect/login errors in runner logs. Startup-path evidence may still be usable, but tick-driven live path should be rerun after successful login."
}
