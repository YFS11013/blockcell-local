<#
.SYNOPSIS
    P4 通用 EA 测试 runner — 编译并运行任意测试 EA，解析 AUTO_TEST_SUMMARY 输出 PASS/FAIL。

.DESCRIPTION
    泛化自 run_mt4_magic_number_tests.ps1。
    接受任意测试 EA 名称，编译后在 MT4 Strategy Tester 中运行，
    从 tester log 中解析 AUTO_TEST_SUMMARY / AUTO_TEST_RESULT，
    返回结构化结果。

.PARAMETER EaName
    测试 EA 文件名（不含 .mq4），必须位于 ea/tests/ 目录。
    例：TestMagicNumberBugEA

.PARAMETER RunnerDir
    MT4 portable runner 目录。默认：ea/.mt4_portable_runner

.PARAMETER Symbol
    回测品种。默认：EURUSD

.PARAMETER Period
    回测周期。默认：H4

.PARAMETER FromDate
    回测起始日期（MT4 格式 YYYY.MM.DD）。默认：2025.09.10

.PARAMETER ToDate
    回测结束日期（MT4 格式 YYYY.MM.DD）。默认：2026.03.10

.PARAMETER TimeoutSec
    等待超时秒数。默认：240

.PARAMETER SkipCompile
    跳过编译步骤（.ex4 已存在时使用）。

.PARAMETER ExpectedExplorePasses
    期望的 explore_pass 数量（-1 = 不校验）。默认：-1

.PARAMETER ExpectedPreservePasses
    期望的 preserve_pass 数量（-1 = 不校验）。默认：-1

.EXAMPLE
    # 运行 magic number 测试（与旧脚本等价）
    .\run_ea_test.ps1 -EaName TestMagicNumberBugEA -ExpectedExplorePasses 3 -ExpectedPreservePasses 5

    # 运行自定义测试 EA，不校验具体数量
    .\run_ea_test.ps1 -EaName MyCustomTestEA
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EaName,

    [string]$RunnerDir = "",
    [string]$Symbol    = "EURUSD",
    [string]$Period    = "H4",
    [string]$FromDate  = "2025.09.10",
    [string]$ToDate    = "2026.03.10",
    [int]$TimeoutSec   = 240,
    [switch]$SkipCompile,
    [int]$ExpectedExplorePasses  = -1,
    [int]$ExpectedPreservePasses = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 工具函数 ──────────────────────────────────────────────────────────────────

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

function Assert-NoRunnerConflict([string]$RunnerRoot, [string]$ConfigFilePath) {
    $terminalPath = (Resolve-Path (Join-Path $RunnerRoot "terminal.exe")).Path
    $running = Get-Process -Name "terminal" -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $terminalPath } catch { $false }
    }
    if (-not $running -or $running.Count -eq 0) { return }

    # 检查是否使用相同 config
    $sameConfigPids = @()
    foreach ($proc in $running) {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction Stop).CommandLine
            if ($cmd -and $cmd.IndexOf($ConfigFilePath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $sameConfigPids += $proc.Id
            }
        } catch {}
    }

    if ($sameConfigPids.Count -gt 0) {
        throw "检测到 MT4 进程正在使用相同配置（config=$ConfigFilePath，pid=$($sameConfigPids -join ',')）。请先关闭后重试。"
    }

    $allPids = ($running | Select-Object -ExpandProperty Id) -join ","
    throw "检测到 runner MT4 已在运行（pid=$allPids）。为避免日志/报告冲突，请先关闭后重试。"
}

function Parse-AutoTestSummary([string[]]$LogPaths) {
    $summaryRegex = "AUTO_TEST_SUMMARY:\s*explore_pass=(\d+)\s+explore_fail=(\d+)\s+preserve_pass=(\d+)\s+preserve_fail=(\d+)\s+total_fail=(\d+)"
    $resultRegex  = "AUTO_TEST_RESULT:\s*(PASS|FAIL)"

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

# ── 路径初始化 ────────────────────────────────────────────────────────────────

$repoEaRoot = Resolve-Path (Join-Path $PSScriptRoot "..") | Select-Object -ExpandProperty Path
if ([string]::IsNullOrWhiteSpace($RunnerDir)) {
    $RunnerDir = Join-Path $repoEaRoot ".mt4_portable_runner"
}

$runTag      = "${EaName}_" + (Get-Date -Format "yyyyMMdd_HHmmss")
$artifactRoot = Join-Path $repoEaRoot ("backtest_artifacts\test_" + $runTag)
Ensure-Dir -Path $artifactRoot

Assert-Dir  -Path $RunnerDir -Label "MT4 portable runner 目录"
Assert-File -Path (Join-Path $RunnerDir "terminal.exe")   -Label "runner terminal.exe"
Assert-File -Path (Join-Path $RunnerDir "metaeditor.exe") -Label "runner metaeditor.exe"

$periodCode = Get-PeriodCode -PeriodName $Period

# 历史数据检查
$historyRoot = Join-Path $RunnerDir "history"
$hstFile     = "${Symbol}${periodCode}.hst"
$historyServerDir = Get-ChildItem -Path $historyRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $hstFile) } |
    Sort-Object Name |
    Select-Object -First 1
if ($null -eq $historyServerDir) {
    throw "runner 内未找到 $hstFile 历史数据，请先准备历史数据后重试。"
}

$runnerExpertsDir        = Join-Path $RunnerDir "MQL4\Experts"
$runnerExpertsIncludeDir = Join-Path $runnerExpertsDir "include"
$runnerIncludeDir        = Join-Path $RunnerDir "MQL4\Include"
$runnerTesterDir         = Join-Path $RunnerDir "tester"
$runnerConfigDir         = Join-Path $RunnerDir "config"
$runnerReportsDir        = Join-Path $RunnerDir "reports"
$testerLogsDir           = Join-Path $RunnerDir "tester\logs"

foreach ($d in @($runnerExpertsDir, $runnerExpertsIncludeDir, $runnerIncludeDir,
                 $runnerTesterDir, $runnerConfigDir, $runnerReportsDir, $testerLogsDir)) {
    Ensure-Dir -Path $d
}

# ── 复制 EA 源文件 ────────────────────────────────────────────────────────────

# 测试 EA 在 ea/tests/ 目录
$repoTestEaPath = Join-Path $repoEaRoot "tests\${EaName}.mq4"
Assert-File -Path $repoTestEaPath -Label "测试 EA 源文件 ${EaName}.mq4"

$runnerTestEaSource = Join-Path $runnerExpertsDir "${EaName}.mq4"
$runnerTestEaEx4    = Join-Path $runnerExpertsDir "${EaName}.ex4"
Copy-Item -LiteralPath $repoTestEaPath -Destination $runnerTestEaSource -Force

# 复制 include（含 EaTestBase.mqh 和被测模块）
$repoIncludeDir = Join-Path $repoEaRoot "include"
Assert-Dir -Path $repoIncludeDir -Label "仓库 include 目录"
Get-ChildItem -Path $repoIncludeDir -Filter "*.mqh" -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $runnerIncludeDir $_.Name) -Force
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $runnerExpertsIncludeDir $_.Name) -Force
}

# ── 编译 ──────────────────────────────────────────────────────────────────────

$compileLogPath = Join-Path $artifactRoot "compile_${EaName}.log"
if (-not $SkipCompile) {
    Write-Host "[INFO] 编译 $EaName ..."
    $metaEditorPath = Join-Path $RunnerDir "metaeditor.exe"
    $compileProc = Start-Process -FilePath $metaEditorPath `
        -ArgumentList @("/portable", "/compile:$runnerTestEaSource", "/log:$compileLogPath") `
        -PassThru -Wait
    if ($compileProc.ExitCode -ne 0) {
        Write-Host "[WARN] MetaEditor 退出码=$($compileProc.ExitCode)，以编译日志为准。"
    }
    Assert-File -Path $compileLogPath -Label "编译日志"
    Assert-File -Path $runnerTestEaEx4 -Label "编译产物 ${EaName}.ex4"
    $compileLogRaw = Get-Content -Path $compileLogPath -Raw
    if ($compileLogRaw -notmatch "Result:\s+0 errors,\s+0 warnings") {
        throw "编译失败（0 errors/0 warnings 未满足），请检查: $compileLogPath"
    }
    Write-Host "[INFO] 编译成功。"
} else {
    Assert-File -Path $runnerTestEaEx4 -Label "runner 现有 ${EaName}.ex4"
}

# ── 生成 .set 和 .ini ─────────────────────────────────────────────────────────

$setFilePath = Join-Path $runnerTesterDir "${EaName}.set"
Write-AsciiFile -Path $setFilePath -Content "; no external inputs`r`n"

$reportRelBase    = "reports\report_${runTag}"
$runnerReportFile = Join-Path $RunnerDir ($reportRelBase + ".htm")
$artifactReportFile = Join-Path $artifactRoot "report.htm"

if (Test-Path -LiteralPath $runnerReportFile) { Remove-Item -LiteralPath $runnerReportFile -Force }

$configPath = Join-Path $runnerConfigDir "${runTag}.ini"
$configContent = @(
    "[Experts]"
    "Enabled=1"
    "AllowLiveTrading=0"
    "AllowDllImport=1"
    "TestExpert=$EaName"
    "TestExpertParameters=$([System.IO.Path]::GetFileName($setFilePath))"
    "TestSymbol=$Symbol"
    "TestPeriod=$Period"
    "TestModel=2"
    "TestOptimization=false"
    "TestDateEnable=true"
    "TestFromDate=$FromDate"
    "TestToDate=$ToDate"
    "TestReport=$reportRelBase"
    "TestReplaceReport=true"
    "TestShutdownTerminal=true"
    "TestSpread=20"
    "TestDeposit=10000"
    "TestCurrency=USD"
    "TestLeverage=100"
) -join "`r`n"
Write-AsciiFile -Path $configPath -Content ($configContent + "`r`n")

# ── 并发冲突检查 ──────────────────────────────────────────────────────────────

Assert-NoRunnerConflict -RunnerRoot $RunnerDir -ConfigFilePath $configPath

# ── 启动 MT4 Strategy Tester ──────────────────────────────────────────────────

$before = @{}
Get-ChildItem -Path $testerLogsDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    $before[$_.Name] = $_.LastWriteTimeUtc.Ticks
}

Write-Host "[INFO] 运行测试: $EaName / $Symbol / $Period / $FromDate ~ $ToDate"
$terminalPath = Join-Path $RunnerDir "terminal.exe"
$proc = Start-Process -FilePath $terminalPath `
    -ArgumentList @("/portable", "/skipupdate", $configPath) `
    -PassThru

$timedOut = $false
if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    $timedOut = $true
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
}

# ── 收集产物 ──────────────────────────────────────────────────────────────────

$reportReady = Wait-ForFile -Path $runnerReportFile -TimeoutSeconds 30
if ($reportReady) {
    Copy-Item -LiteralPath $runnerReportFile -Destination $artifactReportFile -Force
}

$changedLogs = @()
Get-ChildItem -Path $testerLogsDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
    $oldTicks = 0
    if ($before.ContainsKey($_.Name)) { $oldTicks = [long]$before[$_.Name] }
    if ($oldTicks -ne $_.LastWriteTimeUtc.Ticks) {
        $changedLogs += $_.FullName
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $artifactRoot $_.Name) -Force
    }
}

$parsed = Parse-AutoTestSummary -LogPaths $changedLogs

# ── 汇总 ──────────────────────────────────────────────────────────────────────

$summary = [ordered]@{
    run_at_utc           = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    ea_name              = $EaName
    symbol               = $Symbol
    period               = $Period
    from_date            = $FromDate
    to_date              = $ToDate
    runner_dir           = $RunnerDir
    artifact_dir         = $artifactRoot
    config_file          = $configPath
    set_file             = $setFilePath
    compile_log          = $compileLogPath
    report_file          = if ($reportReady) { $artifactReportFile } else { "" }
    process_id           = $proc.Id
    exit_code            = if ($timedOut) { -999 } else { $proc.ExitCode }
    timed_out            = $timedOut
    report_ready         = $reportReady
    changed_logs         = $changedLogs
    parsed_summary       = $parsed
}

$summaryPath = Join-Path $artifactRoot "summary.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding utf8

Write-Host ""
Write-Host "==== run_ea_test.ps1 结果 ===="
Write-Host "ea_name:      $EaName"
Write-Host "artifact_dir: $artifactRoot"
Write-Host "report_ready: $reportReady"
Write-Host "timed_out:    $timedOut"
Write-Host "exit_code:    $($summary.exit_code)"

if ($null -ne $parsed) {
    Write-Host "explore:      $($parsed.explore_pass) pass / $($parsed.explore_fail) fail"
    Write-Host "preserve:     $($parsed.preserve_pass) pass / $($parsed.preserve_fail) fail"
    Write-Host "result:       $($parsed.result)"
}

# ── 失败判断 ──────────────────────────────────────────────────────────────────

if ($timedOut) {
    throw "测试超时（TimeoutSec=$TimeoutSec）。"
}
if (-not $reportReady) {
    throw "未生成测试报告，请检查 tester logs：$($changedLogs -join ', ')"
}
if ($null -eq $parsed) {
    throw "未在 tester log 中找到 AUTO_TEST_SUMMARY。请确认测试 EA 使用了 EaTestBase.mqh 或输出了标准格式。"
}
if ($parsed.result -ne "PASS") {
    throw "测试失败：explore=$($parsed.explore_pass)/$($parsed.explore_fail), preserve=$($parsed.preserve_pass)/$($parsed.preserve_fail), total_fail=$($parsed.total_fail)"
}

# 可选：校验期望数量
if ($ExpectedExplorePasses -ge 0 -and $parsed.explore_pass -ne $ExpectedExplorePasses) {
    throw "explore_pass 期望 $ExpectedExplorePasses，实际 $($parsed.explore_pass)"
}
if ($ExpectedPreservePasses -ge 0 -and $parsed.preserve_pass -ne $ExpectedPreservePasses) {
    throw "preserve_pass 期望 $ExpectedPreservePasses，实际 $($parsed.preserve_pass)"
}

Write-Host "[PASS] $EaName 全部测试通过。"
