[CmdletBinding()]
param(
    [string]$SourceSignalPackPath = "C:\Users\ireke\.blockcell\workspace\domain_experts\forex\ea\signal_pack.json",
    [string]$RunnerDir = "",
    [string]$Symbol = "EURUSD",
    [string]$Period = "H4",
    [string]$FromDate = "2025.09.10",
    [string]$ToDate = "2026.03.10",
    [int]$Model = 2,
    [int]$Spread = 20,
    [string]$EmbeddedProbeJson = "abc",
    [switch]$UseFullEmbeddedJson,
    [int]$TimeoutSec = 360,
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

function Build-SetFile(
    [string]$Path,
    [string]$ParamFilePath,
    [string]$BacktestParamJson,
    [string]$FromDateValue,
    [string]$ToDateValue
) {
    $content = @(
        "ParamFilePath=$ParamFilePath"
        "DryRun=true"
        "LogLevel=DEBUG"
        "ParamCheckInterval=300"
        "AutoDetectUTCOffset=true"
        "ServerUTCOffset=2"
        "BacktestParamJSON=$BacktestParamJson"
        "BacktestStartDate=$FromDateValue 00:00"
        "BacktestEndDate=$ToDateValue 23:59"
    ) -join "`r`n"

    Write-AsciiFile -Path $Path -Content ($content + "`r`n")
}

function Build-RunConfig(
    [string]$Path,
    [string]$ExpertParametersFileName,
    [string]$ReportBasePath
) {
    $config = @(
        "[Experts]"
        "Enabled=1"
        "AllowLiveTrading=0"
        "AllowDllImport=1"
        "TestExpert=ForexStrategyExecutor"
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

function Wait-ForFile([string]$Path, [int]$TimeoutSeconds) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $item = Get-Item -LiteralPath $Path
            if ($item.Length -gt 0) {
                return $true
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Invoke-BacktestCase(
    [string]$CaseName,
    [string]$RunnerRoot,
    [string]$SetFilePath,
    [string]$ArtifactRoot,
    [int]$WaitTimeoutSec
) {
    $terminalPath = Join-Path $RunnerRoot "terminal.exe"
    Assert-File -Path $terminalPath -Label "terminal.exe"

    $configPath = Join-Path $RunnerRoot "config\task14_${CaseName}.ini"
    $reportRelBase = "reports\report_${CaseName}"
    $runnerReportFile = Join-Path $RunnerRoot ($reportRelBase + ".htm")
    $reportFile = Join-Path $ArtifactRoot ("report_${CaseName}.htm")

    if (Test-Path -LiteralPath $runnerReportFile) {
        Remove-Item -LiteralPath $runnerReportFile -Force
    }
    if (Test-Path -LiteralPath $reportFile) { Remove-Item -LiteralPath $reportFile -Force }

    Build-RunConfig -Path $configPath -ExpertParametersFileName ([System.IO.Path]::GetFileName($SetFilePath)) -ReportBasePath $reportRelBase

    $testerLogsDir = Join-Path $RunnerRoot "tester\logs"
    Ensure-Dir -Path $testerLogsDir
    Ensure-Dir -Path (Join-Path $RunnerRoot "reports")
    $before = @{}
    Get-ChildItem -Path $testerLogsDir -File -ErrorAction SilentlyContinue | ForEach-Object { $before[$_.Name] = $_.LastWriteTimeUtc.Ticks }

    # MT4 start config file is passed as a plain argument path (not /config:...).
    $args = @("/portable", "/skipupdate", $configPath)
    $proc = Start-Process -FilePath $terminalPath -ArgumentList $args -PassThru
    $timedOut = $false
    if (-not $proc.WaitForExit($WaitTimeoutSec * 1000)) {
        $timedOut = $true
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }

    $reportReady = Wait-ForFile -Path $runnerReportFile -TimeoutSeconds 30
    if ($reportReady) {
        Copy-Item -LiteralPath $runnerReportFile -Destination $reportFile -Force
    }

    $afterLogs = Get-ChildItem -Path $testerLogsDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    $changedLogs = @()
    foreach ($log in $afterLogs) {
        $oldTicks = 0
        if ($before.ContainsKey($log.Name)) {
            $oldTicks = [long]$before[$log.Name]
        }
        if ($oldTicks -ne $log.LastWriteTimeUtc.Ticks) {
            $changedLogs += $log.FullName
        }
    }

    return [pscustomobject]@{
        case_name   = $CaseName
        process_id  = $proc.Id
        exit_code   = if ($timedOut) { -999 } else { $proc.ExitCode }
        timed_out   = $timedOut
        report_file = $reportFile
        report_ready = $reportReady
        tester_logs = $changedLogs
        config_file = $configPath
        set_file    = $SetFilePath
    }
}

function Pick-EmbeddedSignalPack([string]$RepoEaRoot, [string]$DefaultJson) {
    $historyDir = Join-Path $RepoEaRoot "history\signal_packs"
    if (-not (Test-Path -LiteralPath $historyDir -PathType Container)) {
        return $DefaultJson
    }

    $candidate = Get-ChildItem -Path $historyDir -Filter "signal_pack_*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return $DefaultJson
    }

    $json = Get-Content -Path $candidate.FullName -Raw
    $obj = $json | ConvertFrom-Json
    if ($null -eq $obj.version -or $obj.version -eq "") {
        return $DefaultJson
    }

    # Ensure embedded mode uses a different version to make evidence explicit.
    $baseObj = $DefaultJson | ConvertFrom-Json
    if ($baseObj.version -eq $obj.version) {
        return $DefaultJson
    }
    return ($obj | ConvertTo-Json -Compress)
}

$repoEaRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($RunnerDir)) {
    $RunnerDir = Join-Path $repoEaRoot ".mt4_portable_runner"
}
$artifactRoot = Join-Path $repoEaRoot ("backtest_artifacts\task14_" + (Get-Date -Format "yyyyMMdd_HHmmss"))

Assert-Dir -Path $RunnerDir -Label "MT4 portable runner 目录"
Assert-File -Path (Join-Path $RunnerDir "terminal.exe") -Label "runner terminal.exe"
Assert-File -Path (Join-Path $RunnerDir "metaeditor.exe") -Label "runner metaeditor.exe"
Assert-File -Path $SourceSignalPackPath -Label "signal_pack.json"

Ensure-Dir -Path $artifactRoot
Ensure-Dir -Path $RunnerDir

$runnerExpertsDir = Join-Path $RunnerDir "MQL4\Experts"
$runnerExpertsIncludeDir = Join-Path $runnerExpertsDir "include"
$runnerIncludeDir = Join-Path $RunnerDir "MQL4\Include"
$runnerTesterDir = Join-Path $RunnerDir "tester"
$runnerConfigDir = Join-Path $RunnerDir "config"
$runnerHistoryRoot = Join-Path $RunnerDir "history"
$runnerTesterFilesDir = Join-Path $RunnerDir "tester\files"

Ensure-Dir -Path $runnerExpertsDir
Ensure-Dir -Path $runnerExpertsIncludeDir
Ensure-Dir -Path $runnerIncludeDir
Ensure-Dir -Path $runnerTesterDir
Ensure-Dir -Path $runnerConfigDir
Ensure-Dir -Path $runnerHistoryRoot
Ensure-Dir -Path $runnerTesterFilesDir

$repoEaSourcePath = Join-Path $repoEaRoot "ForexStrategyExecutor.mq4"
$repoIncludeDir = Join-Path $repoEaRoot "include"
Assert-File -Path $repoEaSourcePath -Label "仓库 EA 源文件"
Assert-Dir -Path $repoIncludeDir -Label "仓库 include 目录"

Copy-Item -LiteralPath $repoEaSourcePath -Destination (Join-Path $runnerExpertsDir "ForexStrategyExecutor.mq4") -Force
Get-ChildItem -Path $repoIncludeDir -Filter "*.mqh" -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $runnerIncludeDir $_.Name) -Force
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $runnerExpertsIncludeDir $_.Name) -Force
}

if (-not $SkipCompile) {
    $runnerEaSourceForCompile = Join-Path $runnerExpertsDir "ForexStrategyExecutor.mq4"
    $runnerEaEx4Path = Join-Path $runnerExpertsDir "ForexStrategyExecutor.ex4"
    $compileLogPath = Join-Path $artifactRoot "compile_forex_executor.log"
    $metaEditorPath = Join-Path $RunnerDir "metaeditor.exe"

    Write-Host "[INFO] 在 runner 内编译 EA..."
    $compileProc = Start-Process -FilePath $metaEditorPath -ArgumentList @("/portable", "/compile:$runnerEaSourceForCompile", "/log:$compileLogPath") -PassThru -Wait
    if ($compileProc.ExitCode -ne 0) {
        Write-Host "[WARN] MetaEditor 进程退出码=$($compileProc.ExitCode)，将以编译日志为准判定是否成功。"
    }
    Assert-File -Path $compileLogPath -Label "编译日志"
    Assert-File -Path $runnerEaEx4Path -Label "编译产物 ForexStrategyExecutor.ex4"
    $compileLogRaw = Get-Content -Path $compileLogPath -Raw
    if ($compileLogRaw -notmatch "Result:\s+0 errors,\s+0 warnings") {
        throw "编译日志未显示 0 error/0 warning，请检查: $compileLogPath"
    }
}
else {
    Assert-File -Path (Join-Path $runnerExpertsDir "ForexStrategyExecutor.ex4") -Label "runner 现有 ForexStrategyExecutor.ex4"
}

$runnerSignalPackPath = Join-Path $runnerTesterFilesDir "signal_pack.json"
Copy-Item -LiteralPath $SourceSignalPackPath -Destination $runnerSignalPackPath -Force

$historyServerDir = Get-ChildItem -Path $runnerHistoryRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "${Symbol}240.hst") } |
    Sort-Object Name |
    Select-Object -First 1
if ($null -eq $historyServerDir) {
    throw "runner 内未找到 $Symbol 历史数据（${Symbol}240.hst）。请先在 $RunnerDir/history 下准备历史数据后重试。"
}

$paramFileForEa = "signal_pack.json"
$baseSignalJson = (Get-Content -Path $SourceSignalPackPath -Raw | ConvertFrom-Json | ConvertTo-Json -Compress)
$embeddedSignalJson = if ($UseFullEmbeddedJson) {
    Pick-EmbeddedSignalPack -RepoEaRoot $repoEaRoot -DefaultJson $baseSignalJson
} else {
    # Default probe value intentionally short. It is used to verify the embedded branch is selected.
    $EmbeddedProbeJson
}

$fileModeSetPath = Join-Path $runnerTesterDir "task14_file_mode.set"
$embeddedModeSetPath = Join-Path $runnerTesterDir "task14_embedded_mode.set"

Build-SetFile -Path $fileModeSetPath -ParamFilePath $paramFileForEa -BacktestParamJson "" -FromDateValue $FromDate -ToDateValue $ToDate
Build-SetFile -Path $embeddedModeSetPath -ParamFilePath $paramFileForEa -BacktestParamJson $embeddedSignalJson -FromDateValue $FromDate -ToDateValue $ToDate

Write-Host "[INFO] 运行文件参数模式回测..."
$fileModeResult = Invoke-BacktestCase -CaseName "file_mode" -RunnerRoot $RunnerDir -SetFilePath $fileModeSetPath -ArtifactRoot $artifactRoot -WaitTimeoutSec $TimeoutSec

Write-Host "[INFO] 运行内嵌参数模式回测..."
$embeddedModeResult = Invoke-BacktestCase -CaseName "embedded_mode" -RunnerRoot $RunnerDir -SetFilePath $embeddedModeSetPath -ArtifactRoot $artifactRoot -WaitTimeoutSec $TimeoutSec

$summary = [ordered]@{
    run_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    symbol = $Symbol
    period = $Period
    from_date = $FromDate
    to_date = $ToDate
    model = $Model
    spread = $Spread
    source_signal_pack = $SourceSignalPackPath
    runner_signal_pack = $runnerSignalPackPath
    runner_dir = $RunnerDir
    artifact_dir = $artifactRoot
    file_mode = $fileModeResult
    embedded_mode = $embeddedModeResult
}

$summaryPath = Join-Path $artifactRoot "summary.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding utf8

Write-Host ""
Write-Host "==== Task 14 Backtest Summary ===="
Write-Host "artifact_dir: $artifactRoot"
Write-Host "summary_json: $summaryPath"
Write-Host "file_mode_report: $($fileModeResult.report_file)"
Write-Host "file_mode_ready: $($fileModeResult.report_ready)"
Write-Host "embedded_mode_report: $($embeddedModeResult.report_file)"
Write-Host "embedded_mode_ready: $($embeddedModeResult.report_ready)"
Write-Host "file_mode_timed_out: $($fileModeResult.timed_out)"
Write-Host "embedded_mode_timed_out: $($embeddedModeResult.timed_out)"

if (-not $fileModeResult.report_ready -or -not $embeddedModeResult.report_ready) {
    throw "至少一轮回测报告未生成，请检查 summary.json 与 tester logs。"
}
