[CmdletBinding()]
param(
    [string]$BacktestFileModeExcerpt = "",
    [int]$CaptureSec = 300,
    [int]$ParamCheckIntervalSec = 60,
    [int]$BacktestParseMaxLines = 8000,
    [int]$MaxAttempts = 3,
    [int]$RetryDelaySec = 20
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

function Get-LatestConsistencyArtifact([string]$ArtifactsRoot, [datetime]$NotBefore) {
    if (-not (Test-Path -LiteralPath $ArtifactsRoot -PathType Container)) {
        return $null
    }

    $candidates = Get-ChildItem -Path $ArtifactsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "task14_consistency_*" } |
        Sort-Object LastWriteTime -Descending

    $current = $candidates | Where-Object { $_.LastWriteTime -ge $NotBefore.AddSeconds(-2) } | Select-Object -First 1
    if ($null -ne $current) {
        return $current
    }

    return $candidates | Select-Object -First 1
}

if ($CaptureSec -lt 30) {
    throw "CaptureSec must be >= 30"
}
if ($ParamCheckIntervalSec -lt 60) {
    throw "ParamCheckIntervalSec must be >= 60"
}
if ($BacktestParseMaxLines -lt 500) {
    throw "BacktestParseMaxLines must be >= 500"
}
if ($MaxAttempts -lt 1) {
    throw "MaxAttempts must be >= 1"
}
if ($RetryDelaySec -lt 0) {
    throw "RetryDelaySec must be >= 0"
}

$repoEaRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$artifactsRoot = Join-Path $repoEaRoot "backtest_artifacts"
$runnerDir = Join-Path $repoEaRoot ".mt4_portable_runner"
$consistencyScript = Join-Path $PSScriptRoot "run_mt4_task14_live_consistency.ps1"

Assert-File -Path $consistencyScript -Label "run_mt4_task14_live_consistency.ps1"
Assert-Dir -Path $runnerDir -Label "MT4 portable runner dir"
Assert-Dir -Path $artifactsRoot -Label "backtest_artifacts"

$lastSummary = $null
$lastArtifact = $null

Write-Host "Task 14.5 ready-run wrapper"
Write-Host "Mode: no_launch_collect_only (will not close your manually opened MT4)"
Write-Host "CaptureSec: $CaptureSec, ParamCheckIntervalSec: $ParamCheckIntervalSec, MaxAttempts: $MaxAttempts"

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Host ""
    Write-Host "==== Attempt $attempt/$MaxAttempts ===="
    Write-Host "Keep MT4 connected and EA attached on EURUSD,H4 during this window."

    $runStart = Get-Date
    $invokeParams = @{
        NoLaunch = $true
        CaptureSec = $CaptureSec
        ParamCheckIntervalSec = $ParamCheckIntervalSec
        BacktestParseMaxLines = $BacktestParseMaxLines
    }
    if (-not [string]::IsNullOrWhiteSpace($BacktestFileModeExcerpt)) {
        $invokeParams.BacktestFileModeExcerpt = $BacktestFileModeExcerpt
    }

    & $consistencyScript @invokeParams

    $artifactDir = Get-LatestConsistencyArtifact -ArtifactsRoot $artifactsRoot -NotBefore $runStart
    if ($null -eq $artifactDir) {
        Write-Warning "No consistency artifact directory found after attempt $attempt."
        if ($attempt -lt $MaxAttempts -and $RetryDelaySec -gt 0) {
            Start-Sleep -Seconds $RetryDelaySec
        }
        continue
    }

    $summaryPath = Join-Path $artifactDir.FullName "summary.json"
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
        Write-Warning "summary.json not found: $summaryPath"
        if ($attempt -lt $MaxAttempts -and $RetryDelaySec -gt 0) {
            Start-Sleep -Seconds $RetryDelaySec
        }
        continue
    }

    $summary = Get-Content -Path $summaryPath -Raw | ConvertFrom-Json
    $lastSummary = $summary
    $lastArtifact = $artifactDir.FullName

    Write-Host "attempt_status: $($summary.status)"
    Write-Host "live_ea_lines_count: $($summary.live_ea_lines_count)"
    Write-Host "startup_path_pass: $($summary.startup_path_pass)"
    Write-Host "tick_update_path_pass: $($summary.tick_update_path_pass)"

    if ($summary.status -like "passed_*") {
        break
    }

    if ($attempt -lt $MaxAttempts) {
        Write-Warning "No pass status yet. Retrying after $RetryDelaySec seconds..."
        if ($RetryDelaySec -gt 0) {
            Start-Sleep -Seconds $RetryDelaySec
        }
    }
}

if ($null -eq $lastSummary -or [string]::IsNullOrWhiteSpace($lastArtifact)) {
    throw "No valid summary produced. Check MT4 logs and rerun."
}

$finalSummaryPath = Join-Path $lastArtifact "summary.json"
$finalReportPath = Join-Path $lastArtifact "CONSISTENCY_REPORT.md"
$finalLivePath = Join-Path $lastArtifact "live_mode_log_excerpt.txt"
$finalRunnerPath = Join-Path $lastArtifact "runner_log_excerpt.txt"

Write-Host ""
Write-Host "==== Task 14.5 Ready Wrapper Summary ===="
Write-Host "final_status: $($lastSummary.status)"
Write-Host "artifact_dir: $lastArtifact"
Write-Host "summary_json: $finalSummaryPath"
Write-Host "report_md: $finalReportPath"
Write-Host "live_excerpt: $finalLivePath"
Write-Host "runner_excerpt: $finalRunnerPath"

if ($lastSummary.status -eq "failed_no_live_logs") {
    Write-Warning "No new EA lines in capture window. Reload EA on chart, confirm AutoTrading is enabled, then rerun."
}
