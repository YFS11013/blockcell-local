<#
.SYNOPSIS
    P3 特征工程脚本 — 接受 job.json（job_type=feature），驱动 FeatureWorker EA，
    写 result.json + features.json 到 job 目录。

.PARAMETER JobFile
    job.json 的绝对或相对路径（必填）。

.PARAMETER RunnerDir
    MT4 portable runner 目录。默认：ea/.mt4_portable_runner

.PARAMETER SkipCompile
    跳过编译步骤。

.EXAMPLE
    .\run_feature.ps1 -JobFile ".\jobs\feature_20260314_120000_ab12\job.json"
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

# ── 工具函数（与 run_replay.ps1 相同）────────────────────────────────────────

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
function Assert-NoRunnerConflict([string]$RunnerRoot) {
    $terminalPath = (Resolve-Path (Join-Path $RunnerRoot "terminal.exe")).Path
    $running = Get-Process -Name "terminal" -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $terminalPath } catch { $false }
    }
    if ($running -and $running.Count -gt 0) {
        $pids = ($running | Select-Object -ExpandProperty Id) -join ","
        throw "检测到 runner MT4 已在运行（pid=$pids）。请先关闭后重试。"
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

try { $job = Get-Content -Path $jobFilePath -Raw | ConvertFrom-Json }
catch { throw "job.json 解析失败: $_" }

foreach ($field in @("job_id", "job_type", "created_at")) {
    if (-not $job.$field) { throw "job.json 缺少必填字段: $field" }
}
if ($job.job_type -ne "feature") {
    throw "本脚本仅处理 job_type=feature，当前: $($job.job_type)"
}

$jobId      = $job.job_id
$jobDir     = Split-Path -Path $jobFilePath -Parent
$resultPath = Join-Path $jobDir "result.json"
$errorPath  = Join-Path $jobDir "error.json"

if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
    Write-Host "[INFO] result.json 已存在，任务 $jobId 已完成，跳过。"
    exit 0
}

$timeoutSec = if ($job.timeout_seconds) { [int]$job.timeout_seconds } else { 120 }
$eaName     = "FeatureWorker"

# ── 路径初始化 ────────────────────────────────────────────────────────────────

$repoEaRoot = Resolve-Path (Join-Path $PSScriptRoot "..") | Select-Object -ExpandProperty Path
if ([string]::IsNullOrWhiteSpace($RunnerDir)) {
    $RunnerDir = Join-Path $repoEaRoot ".mt4_portable_runner"
}

$artifactRoot = Join-Path $repoEaRoot ("backtest_artifacts\feature_" + $jobId)
Ensure-Dir -Path $artifactRoot

Assert-Dir  -Path $RunnerDir -Label "MT4 portable runner 目录"
Assert-File -Path (Join-Path $RunnerDir "terminal.exe")   -Label "runner terminal.exe"
Assert-File -Path (Join-Path $RunnerDir "metaeditor.exe") -Label "runner metaeditor.exe"

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

# ── 历史数据检查（固定跑 EURUSD H4，精确校验 EURUSD240.hst）────────────────────

$historyRoot = Join-Path $RunnerDir "history"
$historyServerDir = Get-ChildItem -Path $historyRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "EURUSD240.hst") } |
    Sort-Object Name |
    Select-Object -First 1

if ($null -eq $historyServerDir) {
    $msg = "runner 内未找到 EURUSD240.hst 历史数据（FeatureWorker 固定使用 EURUSD H4 触发），请先准备历史数据后重试。"
    Write-ErrorJson -Path $errorPath -JobId $jobId -Code "SYMBOL_NOT_AVAILABLE" -Message $msg
    throw $msg
}

# ── 复制 EA 源文件 ────────────────────────────────────────────────────────────

$repoEaSourcePath = Join-Path $repoEaRoot "${eaName}.mq4"
Assert-File -Path $repoEaSourcePath -Label "${eaName}.mq4"

$runnerEaSource = Join-Path $runnerExpertsDir "${eaName}.mq4"
$runnerEaEx4    = Join-Path $runnerExpertsDir "${eaName}.ex4"
Copy-Item -LiteralPath $repoEaSourcePath -Destination $runnerEaSource -Force

$repoIncludeDir = Join-Path $repoEaRoot "include"
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

# ── 生成 .set 文件 ────────────────────────────────────────────────────────────

# 将 job.json 复制到 tester/files，EA 通过 FileOpen 读取
$runnerJobJsonPath = Join-Path $runnerTesterFilesDir "job.json"
Copy-Item -LiteralPath $jobFilePath -Destination $runnerJobJsonPath -Force

$setLines = @(
    "JobId=$jobId",
    "JobFilePath=job.json",
    "ResultFilePath=result_${jobId}.json",
    "DryRun=true"
)
$setFilePath = Join-Path $runnerTesterDir "feature_${jobId}.set"
Write-AsciiFile -Path $setFilePath -Content ($setLines -join "`r`n")

# ── 生成 MT4 config .ini ──────────────────────────────────────────────────────
# FeatureWorker 只需要一个 bar 就能完成计算，使用 EURUSD H4 作为触发品种

$reportRelBase    = "reports\report_feature_${jobId}"
$runnerReportFile = Join-Path $RunnerDir ($reportRelBase + ".htm")
$artifactReportFile = Join-Path $artifactRoot "report.htm"

if (Test-Path -LiteralPath $runnerReportFile) { Remove-Item -LiteralPath $runnerReportFile -Force }

# 使用最近 7 天的日期范围，确保有足够数据触发 OnTick
$dateTo   = (Get-Date).ToString("yyyy.MM.dd")
$dateFrom = (Get-Date).AddDays(-7).ToString("yyyy.MM.dd")

$configContent = @(
    "[Experts]"
    "Enabled=1"
    "AllowLiveTrading=0"
    "AllowDllImport=1"
    "TestExpert=$eaName"
    "TestExpertParameters=$([System.IO.Path]::GetFileName($setFilePath))"
    "TestSymbol=EURUSD"
    "TestPeriod=H4"
    "TestModel=2"
    "TestOptimization=false"
    "TestDateEnable=true"
    "TestFromDate=$dateFrom"
    "TestToDate=$dateTo"
    "TestReport=$reportRelBase"
    "TestReplaceReport=true"
    "TestShutdownTerminal=true"
    "TestSpread=20"
    "TestDeposit=10000"
    "TestCurrency=USD"
    "TestLeverage=100"
) -join "`r`n"

$configPath = Join-Path $runnerConfigDir "feature_${jobId}.ini"
Write-AsciiFile -Path $configPath -Content ($configContent + "`r`n")

# ── 启动前清理旧产物 ──────────────────────────────────────────────────────────

Assert-NoRunnerConflict -RunnerRoot $RunnerDir

$runnerResultFile   = Join-Path $runnerTesterFilesDir "result_${jobId}.json"
$runnerErrorFile    = Join-Path $runnerTesterFilesDir "error_${jobId}.json"
$runnerFeaturesFile = Join-Path $runnerTesterFilesDir "features_${jobId}.json"

foreach ($stale in @($runnerResultFile, $runnerErrorFile, $runnerFeaturesFile)) {
    if (Test-Path -LiteralPath $stale -PathType Leaf) {
        Remove-Item -LiteralPath $stale -Force
        Write-Host "[INFO] 清理旧产物: $stale"
    }
}

# ── 启动 MT4 Strategy Tester ──────────────────────────────────────────────────

$before = @{}
Get-ChildItem -Path $testerLogsDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    $before[$_.Name] = $_.LastWriteTimeUtc.Ticks
}

Write-Host "[INFO] 启动 FeatureWorker: job_id=$jobId"
$startTime    = Get-Date
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

# ── 读取 EA 产物 ──────────────────────────────────────────────────────────────

$eaResultData   = $null
$eaFeaturesData = $null
$eaErrorData    = $null

if (Test-Path -LiteralPath $runnerResultFile -PathType Leaf) {
    try {
        $eaResultData = Get-Content -Path $runnerResultFile -Raw | ConvertFrom-Json
        Copy-Item -LiteralPath $runnerResultFile -Destination (Join-Path $artifactRoot "ea_result.json") -Force
    } catch { Write-Host "[WARN] 解析 EA result 失败: $_" }
}

if (Test-Path -LiteralPath $runnerFeaturesFile -PathType Leaf) {
    try {
        $eaFeaturesData = Get-Content -Path $runnerFeaturesFile -Raw | ConvertFrom-Json
        Copy-Item -LiteralPath $runnerFeaturesFile -Destination (Join-Path $artifactRoot "features.json") -Force
        # 同时复制到 job 目录，方便 blockcell 直接读取
        Copy-Item -LiteralPath $runnerFeaturesFile -Destination (Join-Path $jobDir "features.json") -Force
    } catch { Write-Host "[WARN] 解析 features.json 失败: $_" }
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
        job_type         = "feature"
        status           = "timeout"
        finished_at      = $finishedAt
        duration_seconds = $durationSec
        error_message    = "FeatureWorker 超时（timeout_seconds=$timeoutSec）"
        meta             = $job.meta
    }
    Write-ErrorJson -Path $errorPath -JobId $jobId -Code "TIMEOUT" -Message "FeatureWorker 超时"
} elseif ($null -ne $eaErrorData) {
    # Bug3 修复：eaErrorData.error_message 为空时兜底，确保 schema 合法（failed 必须有 error_message）
    $eaErrMsg = if (-not [string]::IsNullOrWhiteSpace($eaErrorData.error_message)) {
        [string]$eaErrorData.error_message
    } else {
        "FeatureWorker 报告错误，但 error.json 未提供 error_message"
    }
    $resultObj = [ordered]@{
        job_id           = $jobId
        job_type         = "feature"
        status           = "failed"
        finished_at      = $finishedAt
        duration_seconds = $durationSec
        error_message    = $eaErrMsg
        meta             = $job.meta
    }
} elseif ($null -ne $eaResultData) {
    # Bug2 修复：校验 EA 写出的 status 是否在合法枚举内
    $validStatuses = @("success", "failed", "timeout", "partial")
    $eaStatus = if ($eaResultData.status -and $validStatuses -contains $eaResultData.status) {
        $eaResultData.status
    } else {
        Write-Host "[WARN] EA result.status 非法值: '$($eaResultData.status)'，降级为 partial"
        "partial"
    }

    # Bug3 修复：status=failed 时必须有 error_message（schema allOf 约束）
    $eaErrMsg = if ($eaResultData.error_message) { $eaResultData.error_message } else { $null }
    if ($eaStatus -eq "failed" -and [string]::IsNullOrWhiteSpace($eaErrMsg)) {
        $eaErrMsg = "FeatureWorker 报告失败，但未提供 error_message"
    }

    $dataObj = $eaResultData.data
    if ($null -ne $dataObj -and $null -ne $eaFeaturesData) {
        $dataObj | Add-Member -NotePropertyName "features_file" -NotePropertyValue (Join-Path $jobDir "features.json") -Force
    }

    $resultObj = [ordered]@{
        job_id           = $jobId
        job_type         = "feature"
        status           = $eaStatus
        finished_at      = $finishedAt
        duration_seconds = $durationSec
        data             = $dataObj
        meta             = $job.meta
    }
    if (-not [string]::IsNullOrWhiteSpace($eaErrMsg)) {
        $resultObj["error_message"] = $eaErrMsg
    }
} else {
    $resultObj = [ordered]@{
        job_id           = $jobId
        job_type         = "feature"
        status           = "failed"
        finished_at      = $finishedAt
        duration_seconds = $durationSec
        error_message    = "FeatureWorker 未写出 result.json"
        meta             = $job.meta
    }
    Write-ErrorJson -Path $errorPath -JobId $jobId -Code "OUTPUT_WRITE_FAILED" -Message "FeatureWorker 未写出 result.json"
}

Write-Utf8File -Path $resultPath -Content ($resultObj | ConvertTo-Json -Depth 8)

# ── 汇总 ──────────────────────────────────────────────────────────────────────

$internalSummary = [ordered]@{
    run_at_utc    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    job_id        = $jobId
    runner_dir    = $RunnerDir
    artifact_dir  = $artifactRoot
    config_file   = $configPath
    compile_log   = $compileLogPath
    report_ready  = $reportReady
    timed_out     = $timedOut
    duration_sec  = $durationSec
    exit_code     = if ($timedOut) { -999 } else { $proc.ExitCode }
    result_path   = $resultPath
    result_status = $resultObj.status
    features_file = if ($null -ne $eaFeaturesData) { Join-Path $jobDir "features.json" } else { "" }
}
$internalSummary | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $artifactRoot "summary.json") -Encoding utf8

Write-Host ""
Write-Host "==== run_feature.ps1 完成 ===="
Write-Host "job_id:        $jobId"
Write-Host "status:        $($resultObj.status)"
Write-Host "duration:      ${durationSec}s"
Write-Host "result.json:   $resultPath"
Write-Host "features.json: $(Join-Path $jobDir 'features.json')"
Write-Host "artifact_dir:  $artifactRoot"

if ($resultObj.status -eq "timeout") { throw "任务超时（job_id=$jobId）" }
if ($resultObj.status -eq "failed")  { throw "任务失败（job_id=$jobId）: $($resultObj.error_message)" }
