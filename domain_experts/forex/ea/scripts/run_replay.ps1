<#
.SYNOPSIS
    P2 通用历史回放脚本 — 接受 job.json，驱动 MT4 Strategy Tester，写 result.json。

.DESCRIPTION
    读取 job.json（P0 协议），编译并运行指定 EA，等待 result.json 或 error.json 出现，
    将结果写回 job 目录。支持任意 EA + 品种 + 日期范围 + EA 参数。

.PARAMETER JobFile
    job.json 的绝对或相对路径（必填）。

.PARAMETER RunnerDir
    MT4 portable runner 目录。默认：ea/.mt4_portable_runner

.PARAMETER SkipCompile
    跳过编译步骤（EA .ex4 已存在时使用）。

.EXAMPLE
    # 最简调用
    .\run_replay.ps1 -JobFile "C:\path\to\job.json"

    # 指定 runner 目录
    .\run_replay.ps1 -JobFile ".\jobs\replay_20260314_153000_a1b2\job.json" -RunnerDir "D:\mt4_runner"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JobFile,

    [string]$RunnerDir = "",
    [switch]$SkipCompile
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

function Write-Utf8File([string]$Path, [string]$Content) {
    $dir = Split-Path -Path $Path -Parent
    Ensure-Dir -Path $dir
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
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

function Get-PeriodName([int]$TimeframeMinutes) {
    switch ($TimeframeMinutes) {
        1     { return "M1" }
        5     { return "M5" }
        15    { return "M15" }
        30    { return "M30" }
        60    { return "H1" }
        240   { return "H4" }
        1440  { return "D1" }
        10080 { return "W1" }
        default { throw "不支持的 timeframe: $TimeframeMinutes 分钟" }
    }
}

function Format-Mt4Date([string]$IsoDate) {
    # 将 YYYY-MM-DD 转为 MT4 格式 YYYY.MM.DD
    return $IsoDate -replace "-", "."
}

function Assert-NoRunnerConflict([string]$RunnerRoot) {
    $terminalPath = (Resolve-Path (Join-Path $RunnerRoot "terminal.exe")).Path
    $running = Get-Process -Name "terminal" -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $terminalPath } catch { $false }
    }
    if ($running -and $running.Count -gt 0) {
        $pids = ($running | Select-Object -ExpandProperty Id) -join ","
        throw "检测到 runner MT4 已在运行（pid=$pids）。为避免日志/报告冲突，请先关闭后重试。"
    }
}

function Write-ErrorJson([string]$Path, [string]$JobId, [string]$Code, [string]$Message) {
    $obj = [ordered]@{
        job_id        = $JobId
        error_code    = $Code
        error_message = $Message
        timestamp     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    Write-Utf8File -Path $Path -Content ($obj | ConvertTo-Json -Depth 4)
}

# ── 读取并验证 job.json ───────────────────────────────────────────────────────

$jobFilePath = Resolve-Path $JobFile | Select-Object -ExpandProperty Path
Assert-File -Path $jobFilePath -Label "job.json"

$jobJson = Get-Content -Path $jobFilePath -Raw
try {
    $job = $jobJson | ConvertFrom-Json
} catch {
    throw "job.json 解析失败: $_"
}

# 必填字段校验
foreach ($field in @("job_id", "job_type", "created_at")) {
    if (-not $job.$field) { throw "job.json 缺少必填字段: $field" }
}
if ($job.job_type -ne "replay") {
    throw "本脚本仅处理 job_type=replay，当前: $($job.job_type)"
}

$jobId      = $job.job_id
$jobDir     = Split-Path -Path $jobFilePath -Parent
$resultPath = Join-Path $jobDir "result.json"
$errorPath  = Join-Path $jobDir "error.json"

# 如果 result.json 已存在，跳过（幂等）
if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
    Write-Host "[INFO] result.json 已存在，任务 $jobId 已完成，跳过。"
    exit 0
}

# ── 解析参数 ──────────────────────────────────────────────────────────────────

$eaName       = if ($job.ea_name)          { $job.ea_name }          else { "ForexStrategyExecutor" }
$symbol       = if ($job.symbol)           { $job.symbol }           else { "EURUSD" }
$timeframe    = if ($job.timeframe)        { [int]$job.timeframe }   else { 240 }
$dateFrom     = if ($job.date_from)        { $job.date_from }        else { "2025-01-01" }
$dateTo       = if ($job.date_to)          { $job.date_to }          else { "2026-01-01" }
$timeoutSec   = if ($job.timeout_seconds)  { [int]$job.timeout_seconds } else { 300 }
$eaParams     = if ($job.ea_params)        { $job.ea_params }        else { $null }

$periodName   = Get-PeriodName -TimeframeMinutes $timeframe
$mt4DateFrom  = Format-Mt4Date -IsoDate $dateFrom
$mt4DateTo    = Format-Mt4Date -IsoDate $dateTo

# ── 路径初始化 ────────────────────────────────────────────────────────────────

$repoEaRoot = Resolve-Path (Join-Path $PSScriptRoot "..") | Select-Object -ExpandProperty Path
if ([string]::IsNullOrWhiteSpace($RunnerDir)) {
    $RunnerDir = Join-Path $repoEaRoot ".mt4_portable_runner"
}

$artifactRoot = Join-Path $repoEaRoot ("backtest_artifacts\replay_" + $jobId)
Ensure-Dir -Path $artifactRoot

Assert-Dir  -Path $RunnerDir -Label "MT4 portable runner 目录"
Assert-File -Path (Join-Path $RunnerDir "terminal.exe")    -Label "runner terminal.exe"
Assert-File -Path (Join-Path $RunnerDir "metaeditor.exe")  -Label "runner metaeditor.exe"

$runnerExpertsDir        = Join-Path $RunnerDir "MQL4\Experts"
$runnerExpertsIncludeDir = Join-Path $runnerExpertsDir "include"
$runnerIncludeDir        = Join-Path $RunnerDir "MQL4\Include"
$runnerTesterDir         = Join-Path $RunnerDir "tester"
$runnerTesterFilesDir    = Join-Path $RunnerDir "tester\files"
$runnerConfigDir         = Join-Path $RunnerDir "config"
$runnerReportsDir        = Join-Path $RunnerDir "reports"
$testerLogsDir           = Join-Path $RunnerDir "tester\logs"

foreach ($d in @($runnerExpertsDir, $runnerExpertsIncludeDir, $runnerIncludeDir,
                 $runnerTesterDir, $runnerTesterFilesDir, $runnerConfigDir,
                 $runnerReportsDir, $testerLogsDir)) {
    Ensure-Dir -Path $d
}

# ── 历史数据检查 ──────────────────────────────────────────────────────────────

$historyRoot = Join-Path $RunnerDir "history"
$hstFile     = "${symbol}${timeframe}.hst"
$historyServerDir = Get-ChildItem -Path $historyRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $hstFile) } |
    Sort-Object Name |
    Select-Object -First 1

if ($null -eq $historyServerDir) {
    $msg = "runner 内未找到 $hstFile 历史数据，请先准备历史数据后重试。"
    Write-ErrorJson -Path $errorPath -JobId $jobId -Code "SYMBOL_NOT_AVAILABLE" -Message $msg
    throw $msg
}

# ── 复制 EA 源文件 + include ──────────────────────────────────────────────────

$repoEaSourcePath = Join-Path $repoEaRoot "${eaName}.mq4"
$repoIncludeDir   = Join-Path $repoEaRoot "include"

if (-not (Test-Path -LiteralPath $repoEaSourcePath -PathType Leaf)) {
    $msg = "EA 源文件不存在: $repoEaSourcePath"
    Write-ErrorJson -Path $errorPath -JobId $jobId -Code "EA_INIT_FAILED" -Message $msg
    throw $msg
}

$runnerEaSource = Join-Path $runnerExpertsDir "${eaName}.mq4"
$runnerEaEx4    = Join-Path $runnerExpertsDir "${eaName}.ex4"
Copy-Item -LiteralPath $repoEaSourcePath -Destination $runnerEaSource -Force

if (Test-Path -LiteralPath $repoIncludeDir -PathType Container) {
    Get-ChildItem -Path $repoIncludeDir -Filter "*.mqh" -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $runnerIncludeDir $_.Name) -Force
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $runnerExpertsIncludeDir $_.Name) -Force
    }
}

# ── 编译 ──────────────────────────────────────────────────────────────────────

$compileLogPath = Join-Path $artifactRoot "compile_${eaName}.log"
if (-not $SkipCompile) {
    Write-Host "[INFO] 编译 $eaName ..."
    $metaEditorPath = Join-Path $RunnerDir "metaeditor.exe"
    $compileProc = Start-Process -FilePath $metaEditorPath `
        -ArgumentList @("/portable", "/compile:$runnerEaSource", "/log:$compileLogPath") `
        -PassThru -Wait
    if ($compileProc.ExitCode -ne 0) {
        Write-Host "[WARN] MetaEditor 退出码=$($compileProc.ExitCode)，以编译日志为准。"
    }
    Assert-File -Path $compileLogPath -Label "编译日志"
    Assert-File -Path $runnerEaEx4    -Label "编译产物 ${eaName}.ex4"
    $compileLogRaw = Get-Content -Path $compileLogPath -Raw
    if ($compileLogRaw -notmatch "Result:\s+0 errors,\s+0 warnings") {
        $msg = "编译失败，请检查: $compileLogPath"
        Write-ErrorJson -Path $errorPath -JobId $jobId -Code "EA_INIT_FAILED" -Message $msg
        throw $msg
    }
    Write-Host "[INFO] 编译成功。"
} else {
    Assert-File -Path $runnerEaEx4 -Label "runner 现有 ${eaName}.ex4"
}

# ── 生成 .set 文件（EA 输入参数）────────────────────────────────────────────

$setLines = @()

# 将 job.json 路径写入 tester/files，EA 可通过 FileOpen 读取
$runnerJobJsonPath = Join-Path $runnerTesterFilesDir "job.json"
Copy-Item -LiteralPath $jobFilePath -Destination $runnerJobJsonPath -Force

# 基础参数：告知 EA 当前 job_id 和输出路径
$setLines += "JobId=$jobId"
$setLines += "JobFilePath=job.json"
$setLines += "ResultFilePath=result_${jobId}.json"
$setLines += "DryRun=true"

# 追加 job.ea_params 中的自定义参数
if ($null -ne $eaParams) {
    $eaParams.PSObject.Properties | ForEach-Object {
        $setLines += "$($_.Name)=$($_.Value)"
    }
}

$setFilePath = Join-Path $runnerTesterDir "replay_${jobId}.set"
Write-AsciiFile -Path $setFilePath -Content ($setLines -join "`r`n")

# ── 生成 MT4 config .ini ──────────────────────────────────────────────────────

$reportRelBase  = "reports\report_replay_${jobId}"
$runnerReportFile = Join-Path $RunnerDir ($reportRelBase + ".htm")
$artifactReportFile = Join-Path $artifactRoot "report.htm"

if (Test-Path -LiteralPath $runnerReportFile) { Remove-Item -LiteralPath $runnerReportFile -Force }

$configContent = @(
    "[Experts]"
    "Enabled=1"
    "AllowLiveTrading=0"
    "AllowDllImport=1"
    "TestExpert=$eaName"
    "TestExpertParameters=$([System.IO.Path]::GetFileName($setFilePath))"
    "TestSymbol=$symbol"
    "TestPeriod=$periodName"
    "TestModel=2"
    "TestOptimization=false"
    "TestDateEnable=true"
    "TestFromDate=$mt4DateFrom"
    "TestToDate=$mt4DateTo"
    "TestReport=$reportRelBase"
    "TestReplaceReport=true"
    "TestShutdownTerminal=true"
    "TestSpread=20"
    "TestDeposit=10000"
    "TestCurrency=USD"
    "TestLeverage=100"
) -join "`r`n"

$configPath = Join-Path $runnerConfigDir "replay_${jobId}.ini"
Write-AsciiFile -Path $configPath -Content ($configContent + "`r`n")

# ── 并发冲突检查 ──────────────────────────────────────────────────────────────

Assert-NoRunnerConflict -RunnerRoot $RunnerDir

# ── 启动 MT4 Strategy Tester ──────────────────────────────────────────────────

$before = @{}
Get-ChildItem -Path $testerLogsDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    $before[$_.Name] = $_.LastWriteTimeUtc.Ticks
}

Write-Host "[INFO] 启动 MT4 Strategy Tester: $eaName / $symbol / $periodName / $mt4DateFrom ~ $mt4DateTo"
$startTime = Get-Date
$terminalPath = Join-Path $RunnerDir "terminal.exe"
$proc = Start-Process -FilePath $terminalPath `
    -ArgumentList @("/portable", "/skipupdate", $configPath) `
    -PassThru

$timedOut = $false
if (-not $proc.WaitForExit($timeoutSec * 1000)) {
    $timedOut = $true
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
}

$durationSec = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

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

# ── Bug5 修复：启动前清理同 job_id 的旧产物，防止重跑读到旧结果 ──────────────

$runnerResultFile = Join-Path $runnerTesterFilesDir "result_${jobId}.json"
$runnerErrorFile  = Join-Path $runnerTesterFilesDir "error_${jobId}.json"
foreach ($stale in @($runnerResultFile, $runnerErrorFile)) {
    if (Test-Path -LiteralPath $stale -PathType Leaf) {
        Remove-Item -LiteralPath $stale -Force
        Write-Host "[INFO] 清理旧产物: $stale"
    }
}

# ── 检查 EA 写出的 result / error ─────────────────────────────────────────────

$eaResultData = $null
$eaErrorData  = $null

if (Test-Path -LiteralPath $runnerResultFile -PathType Leaf) {
    try {
        $eaResultData = Get-Content -Path $runnerResultFile -Raw | ConvertFrom-Json
        Copy-Item -LiteralPath $runnerResultFile -Destination (Join-Path $artifactRoot "ea_result.json") -Force
    } catch {
        Write-Host "[WARN] 解析 EA result 文件失败: $_"
    }
}

if (Test-Path -LiteralPath $runnerErrorFile -PathType Leaf) {
    try {
        $eaErrorData = Get-Content -Path $runnerErrorFile -Raw | ConvertFrom-Json
        Copy-Item -LiteralPath $runnerErrorFile -Destination (Join-Path $artifactRoot "ea_error.json") -Force
    } catch {}
}

# ── 构建最终 result.json ──────────────────────────────────────────────────────

$finishedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

if ($timedOut) {
    $resultObj = [ordered]@{
        job_id           = $jobId
        job_type         = "replay"
        status           = "timeout"
        finished_at      = $finishedAt
        duration_seconds = $durationSec
        error_message    = "Strategy Tester 超时（timeout_seconds=$timeoutSec）"
        meta             = $job.meta
    }
    Write-ErrorJson -Path $errorPath -JobId $jobId -Code "TIMEOUT" -Message "Strategy Tester 超时（timeout_seconds=$timeoutSec）"
} elseif ($null -ne $eaErrorData) {
    # EA 写出了 error 文件
    $resultObj = [ordered]@{
        job_id           = $jobId
        job_type         = "replay"
        status           = "failed"
        finished_at      = $finishedAt
        duration_seconds = $durationSec
        error_message    = [string]$eaErrorData.error_message
        meta             = $job.meta
    }
} elseif ($null -ne $eaResultData) {
    # Bug1 修复：透传 EA 自己写出的 status，不强制覆盖为 success
    $eaStatus = [string]$eaResultData.status
    if ($eaStatus -notin @("success", "failed", "timeout", "partial")) {
        $eaStatus = "failed"  # 非法值降级为 failed
    }
    $resultObj = [ordered]@{
        job_id           = $jobId
        job_type         = "replay"
        status           = $eaStatus
        finished_at      = $finishedAt
        duration_seconds = $durationSec
        data             = $eaResultData.data
        meta             = $job.meta
    }
    # EA 报告失败时补充 error_message
    if ($eaStatus -eq "failed") {
        $resultObj["error_message"] = if ($eaResultData.error_message) { [string]$eaResultData.error_message } else { "EA 报告执行失败" }
    }
} elseif ($reportReady) {
    # Bug3 修复：partial 分支不写 note/report_file（schema additionalProperties:false）
    # 报告路径记录在 artifact 目录的 summary.json，不写入 result.json
    $resultObj = [ordered]@{
        job_id           = $jobId
        job_type         = "replay"
        status           = "partial"
        finished_at      = $finishedAt
        duration_seconds = $durationSec
        meta             = $job.meta
    }
} else {
    $resultObj = [ordered]@{
        job_id           = $jobId
        job_type         = "replay"
        status           = "failed"
        finished_at      = $finishedAt
        duration_seconds = $durationSec
        error_message    = "Strategy Tester 未生成报告，EA 也未写出 result.json"
        meta             = $job.meta
    }
    Write-ErrorJson -Path $errorPath -JobId $jobId -Code "OUTPUT_WRITE_FAILED" -Message "Strategy Tester 未生成报告"
}

$resultJson = $resultObj | ConvertTo-Json -Depth 8
Write-Utf8File -Path $resultPath -Content $resultJson

# ── 汇总输出 ──────────────────────────────────────────────────────────────────

$internalSummary = [ordered]@{
    run_at_utc      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    job_id          = $jobId
    ea_name         = $eaName
    symbol          = $symbol
    period          = $periodName
    date_from       = $mt4DateFrom
    date_to         = $mt4DateTo
    runner_dir      = $RunnerDir
    artifact_dir    = $artifactRoot
    config_file     = $configPath
    set_file        = $setFilePath
    compile_log     = $compileLogPath
    report_ready    = $reportReady
    timed_out       = $timedOut
    duration_sec    = $durationSec
    exit_code       = if ($timedOut) { -999 } else { $proc.ExitCode }
    changed_logs    = $changedLogs
    result_path     = $resultPath
    result_status   = $resultObj.status
}
$internalSummary | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $artifactRoot "summary.json") -Encoding utf8

Write-Host ""
Write-Host "==== run_replay.ps1 完成 ===="
Write-Host "job_id:       $jobId"
Write-Host "status:       $($resultObj.status)"
Write-Host "duration:     ${durationSec}s"
Write-Host "result.json:  $resultPath"
Write-Host "artifact_dir: $artifactRoot"

if ($resultObj.status -eq "timeout") {
    throw "任务超时（job_id=$jobId）"
}
if ($resultObj.status -eq "failed") {
    throw "任务失败（job_id=$jobId）: $($resultObj.error_message)"
}
