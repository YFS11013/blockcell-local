[CmdletBinding()]
param(
    [string]$RunnerDir = "",
    [string]$Symbol = "EURUSD",
    [string]$Period = "H4",
    [string]$FromDate = "2025.09.10",
    [string]$ToDate = "2026.03.10",
    [int]$Model = 2,
    [int]$Spread = 20,
    [int]$TimeoutSec = 240,
    [switch]$SkipCompile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-File([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label 不存在: $Path"
    }
}

function Assert-Dir([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label 不存在: $Path"
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

function Wait-ForFile([string]$Path, [int]$TimeoutSeconds) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $item = Get-Item -LiteralPath $Path
            if ($item.Length -gt 0) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-PeriodCode([string]$PeriodName) {
    switch ($PeriodName.ToUpperInvariant()) {
        "M1"  { return 1 }
        "M5"  { return 5 }
        "M15" { return 15 }
        "M30" { return 30 }
        "H1"  { return 60 }
        "H4"  { return 240 }
        "D1"  { return 1440 }
        "W1"  { return 10080 }
        "MN1" { return 43200 }
        default { throw "不支持的 Period: $PeriodName" }
    }
}

function Build-RunConfig(
    [string]$Path,
    [string]$ExpertName,
    [string]$ExpertParametersFileName,
    [string]$ReportBasePath
) {
    $config = @(
        "[Experts]"
        "Enabled=1"
        "AllowLiveTrading=0"
        "AllowDllImport=1"
        "TestExpert=$ExpertName"
        "TestExpertParameters=$ExpertParametersFileName"
        "TestSymbol=$Symbol"
        "TestPeriod=$Period"
        "TestModel=$Model"
        "TestOptimization=false"
        "TestDateEnable=true"
        "TestFromDate=$FromDate"
        "TestToDate=$ToDate"
        "TestReport=$ReportBasePath"
        "TestReplaceReport=true"
        "TestShutdownTerminal=true"
        "TestSpread=$Spread"
        "TestDeposit=10000"
        "TestCurrency=USD"
        "TestLeverage=100"
    ) -join "`r`n"

    Write-AsciiFile -Path $Path -Content ($config + "`r`n")
}

function Parse-AutoTestSummary([string[]]$LogPaths) {
    $summaryRegex = "AUTO_TEST_SUMMARY:\s*explore_pass=(\d+)\s+explore_fail=(\d+)\s+preserve_pass=(\d+)\s+preserve_fail=(\d+)\s+total_fail=(\d+)"
    $resultRegex = "AUTO_TEST_RESULT:\s*(PASS|FAIL)"

    foreach ($log in $LogPaths) {
        if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { continue }
        $raw = Get-Content -Path $log -Raw
        $m = [regex]::Match($raw, $summaryRegex)
        if (-not $m.Success) { continue }

        $r = [regex]::Match($raw, $resultRegex)
        $result = if ($r.Success) { $r.Groups[1].Value } else { "UNKNOWN" }

        return [pscustomobject]@{
            log_file      = $log
            explore_pass  = [int]$m.Groups[1].Value
            explore_fail  = [int]$m.Groups[2].Value
            preserve_pass = [int]$m.Groups[3].Value
            preserve_fail = [int]$m.Groups[4].Value
            total_fail    = [int]$m.Groups[5].Value
            result        = $result
        }
    }

    return $null
}

function Get-ProcessCommandLineSafe([int]$ProcessId) {
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        return [string]$p.CommandLine
    }
    catch {
        return ""
    }
}

function Assert-NoRunnerConfigConflict(
    [string]$RunnerRoot,
    [string]$ConfigFilePath
) {
    $runnerTerminalPath = (Resolve-Path (Join-Path $RunnerRoot "terminal.exe")).Path
    $running = Get-Process -Name "terminal" -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $runnerTerminalPath } catch { $false }
    }

    if (-not $running -or $running.Count -eq 0) { return }

    $sameConfigPids = @()
    foreach ($proc in $running) {
        $cmd = Get-ProcessCommandLineSafe -ProcessId $proc.Id
        if (-not [string]::IsNullOrWhiteSpace($cmd) -and
            $cmd.IndexOf($ConfigFilePath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $sameConfigPids += $proc.Id
        }
    }

    if ($sameConfigPids.Count -gt 0) {
        throw "检测到 MT4 进程正在使用相同配置运行（config=$ConfigFilePath，pid=$($sameConfigPids -join ',')）。请先关闭该进程后重试。"
    }

    $allPids = ($running | Select-Object -ExpandProperty Id) -join ","
    throw "检测到 runner MT4 已在运行（pid=$allPids，path=$runnerTerminalPath）。为避免日志/报告冲突，本脚本已中止。请先关闭 runner MT4 后重试。"
}

$repoEaRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($RunnerDir)) {
    $RunnerDir = Join-Path $repoEaRoot ".mt4_portable_runner"
}

$artifactRoot = Join-Path $repoEaRoot ("backtest_artifacts\magic_number_tests_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Ensure-Dir -Path $artifactRoot

Assert-Dir -Path $RunnerDir -Label "MT4 portable runner 目录"
Assert-File -Path (Join-Path $RunnerDir "terminal.exe") -Label "runner terminal.exe"
Assert-File -Path (Join-Path $RunnerDir "metaeditor.exe") -Label "runner metaeditor.exe"

$periodCode = Get-PeriodCode -PeriodName $Period
$historyServerDir = Get-ChildItem -Path (Join-Path $RunnerDir "history") -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName ("{0}{1}.hst" -f $Symbol, $periodCode)) } |
    Sort-Object Name |
    Select-Object -First 1
if ($null -eq $historyServerDir) {
    throw "runner 内未找到 ${Symbol}${periodCode}.hst 历史数据，请先准备历史数据。"
}

$runnerExpertsDir = Join-Path $RunnerDir "MQL4\Experts"
$runnerExpertsIncludeDir = Join-Path $runnerExpertsDir "include"
$runnerIncludeDir = Join-Path $RunnerDir "MQL4\Include"
$runnerTesterDir = Join-Path $RunnerDir "tester"
$runnerConfigDir = Join-Path $RunnerDir "config"
$runnerReportsDir = Join-Path $RunnerDir "reports"
$testerLogsDir = Join-Path $RunnerDir "tester\logs"

Ensure-Dir -Path $runnerExpertsDir
Ensure-Dir -Path $runnerExpertsIncludeDir
Ensure-Dir -Path $runnerIncludeDir
Ensure-Dir -Path $runnerTesterDir
Ensure-Dir -Path $runnerConfigDir
Ensure-Dir -Path $runnerReportsDir
Ensure-Dir -Path $testerLogsDir

$repoTestEaPath = Join-Path $repoEaRoot "tests\TestMagicNumberBugEA.mq4"
$repoIncludeDir = Join-Path $repoEaRoot "include"
Assert-File -Path $repoTestEaPath -Label "测试 EA 源文件"
Assert-Dir -Path $repoIncludeDir -Label "仓库 include 目录"

$runnerTestEaSource = Join-Path $runnerExpertsDir "TestMagicNumberBugEA.mq4"
$runnerTestEaEx4 = Join-Path $runnerExpertsDir "TestMagicNumberBugEA.ex4"
Copy-Item -LiteralPath $repoTestEaPath -Destination $runnerTestEaSource -Force
Get-ChildItem -Path $repoIncludeDir -Filter "*.mqh" -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $runnerIncludeDir $_.Name) -Force
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $runnerExpertsIncludeDir $_.Name) -Force
}

$compileLogPath = Join-Path $artifactRoot "compile_test_magic_number_bug_ea.log"
if (-not $SkipCompile) {
    Write-Host "[INFO] 在 runner 内编译 TestMagicNumberBugEA..."
    $metaEditorPath = Join-Path $RunnerDir "metaeditor.exe"
    $compileProc = Start-Process -FilePath $metaEditorPath -ArgumentList @("/portable", "/compile:$runnerTestEaSource", "/log:$compileLogPath") -PassThru -Wait
    if ($compileProc.ExitCode -ne 0) {
        Write-Host "[WARN] MetaEditor 进程退出码=$($compileProc.ExitCode)，将以编译日志为准判定是否成功。"
    }
    Assert-File -Path $compileLogPath -Label "编译日志"
    Assert-File -Path $runnerTestEaEx4 -Label "编译产物 TestMagicNumberBugEA.ex4"
    $compileLogRaw = Get-Content -Path $compileLogPath -Raw
    if ($compileLogRaw -notmatch "Result:\s+0 errors,\s+0 warnings") {
        throw "编译日志未显示 0 error/0 warning，请检查: $compileLogPath"
    }
}
else {
    Assert-File -Path $runnerTestEaEx4 -Label "runner 现有 TestMagicNumberBugEA.ex4"
}

$setFilePath = Join-Path $runnerTesterDir "magic_number_tests.set"
Write-AsciiFile -Path $setFilePath -Content "; no external inputs`r`n"

$configPath = Join-Path $runnerConfigDir "magic_number_tests.ini"
$reportRelBase = "reports\report_magic_number_tests"
$runnerReportFile = Join-Path $RunnerDir ($reportRelBase + ".htm")
$artifactReportFile = Join-Path $artifactRoot "report_magic_number_tests.htm"

if (Test-Path -LiteralPath $runnerReportFile) { Remove-Item -LiteralPath $runnerReportFile -Force }
if (Test-Path -LiteralPath $artifactReportFile) { Remove-Item -LiteralPath $artifactReportFile -Force }

Build-RunConfig -Path $configPath -ExpertName "TestMagicNumberBugEA" -ExpertParametersFileName ([System.IO.Path]::GetFileName($setFilePath)) -ReportBasePath $reportRelBase

# 冲突检查：同一 runner 若已有 terminal 进程运行，默认阻断，防止产物互相污染
Assert-NoRunnerConfigConflict -RunnerRoot $RunnerDir -ConfigFilePath $configPath

$before = @{}
Get-ChildItem -Path $testerLogsDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    $before[$_.Name] = $_.LastWriteTimeUtc.Ticks
}

Write-Host "[INFO] 运行 Magic Number 自动化测试回测..."
$terminalPath = Join-Path $RunnerDir "terminal.exe"
$proc = Start-Process -FilePath $terminalPath -ArgumentList @("/portable", "/skipupdate", $configPath) -PassThru
$timedOut = $false
if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    $timedOut = $true
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
}

$reportReady = Wait-ForFile -Path $runnerReportFile -TimeoutSeconds 30
if ($reportReady) {
    Copy-Item -LiteralPath $runnerReportFile -Destination $artifactReportFile -Force
}

$changedLogs = @()
$afterLogs = Get-ChildItem -Path $testerLogsDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
foreach ($log in $afterLogs) {
    $oldTicks = 0
    if ($before.ContainsKey($log.Name)) {
        $oldTicks = [long]$before[$log.Name]
    }
    if ($oldTicks -ne $log.LastWriteTimeUtc.Ticks) {
        $changedLogs += $log.FullName
        Copy-Item -LiteralPath $log.FullName -Destination (Join-Path $artifactRoot $log.Name) -Force
    }
}

$parsed = Parse-AutoTestSummary -LogPaths $changedLogs

$summary = [ordered]@{
    run_at_utc      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    runner_dir      = $RunnerDir
    artifact_dir    = $artifactRoot
    config_file     = $configPath
    set_file        = $setFilePath
    compile_log     = $compileLogPath
    report_file     = if ($reportReady) { $artifactReportFile } else { "" }
    process_id      = $proc.Id
    exit_code       = if ($timedOut) { -999 } else { $proc.ExitCode }
    timed_out       = $timedOut
    report_ready    = $reportReady
    changed_logs    = $changedLogs
    parsed_summary  = $parsed
}

$summaryPath = Join-Path $artifactRoot "summary.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding utf8

Write-Host ""
Write-Host "==== Magic Number Auto Test Summary ===="
Write-Host "artifact_dir: $artifactRoot"
Write-Host "summary_json: $summaryPath"
Write-Host "report_ready: $reportReady"
Write-Host "timed_out: $timedOut"
Write-Host "exit_code: $($summary.exit_code)"
if ($null -ne $parsed) {
    Write-Host "explore: $($parsed.explore_pass) pass / $($parsed.explore_fail) fail"
    Write-Host "preserve: $($parsed.preserve_pass) pass / $($parsed.preserve_fail) fail"
    Write-Host "auto_result: $($parsed.result)"
}

if ($timedOut) {
    throw "测试超时（TimeoutSec=$TimeoutSec）。"
}
if (-not $reportReady) {
    throw "未生成测试报告文件，请检查 tester logs。"
}
if ($null -eq $parsed) {
    throw "未在 tester log 中找到 AUTO_TEST_SUMMARY，请检查日志编码或测试是否执行。"
}
if ($parsed.explore_pass -ne 3 -or $parsed.explore_fail -ne 0 -or $parsed.preserve_pass -ne 5 -or $parsed.preserve_fail -ne 0 -or $parsed.total_fail -ne 0) {
    throw "测试未通过：explore=$($parsed.explore_pass)/$($parsed.explore_fail), preserve=$($parsed.preserve_pass)/$($parsed.preserve_fail), total_fail=$($parsed.total_fail)"
}

Write-Host "[PASS] Magic Number 自动化测试全部通过。"
