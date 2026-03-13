[CmdletBinding()]
param(
    [string]$SourceSignalPackPath = "",
    [string]$RunnerDir = "",
    [ValidateRange(1, 86400)]
    [int]$MaxMtimeDiffSeconds = 300,
    [ValidateRange(0, 10080)]
    [int]$MaxAgeMinutes = 240,
    [string]$RequireCurrentValidWindow = "true",
    [ValidateRange(0, 1048576)]
    [int]$MaxLogSizeKB = 1024,
    [ValidateRange(1, 100)]
    [int]$MaxLogBackups = 10,
    [string]$VerifyScriptPath = "",
    [string]$HealthLogPath = "",
    [string]$AlertLogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$eaRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($VerifyScriptPath)) {
    $VerifyScriptPath = Join-Path $PSScriptRoot "verify_signal_sync.ps1"
}
if ([string]::IsNullOrWhiteSpace($HealthLogPath)) {
    $HealthLogPath = Join-Path $eaRoot "backtest_artifacts\signal_sync_health.log"
}
if ([string]::IsNullOrWhiteSpace($AlertLogPath)) {
    $AlertLogPath = Join-Path $eaRoot "backtest_artifacts\signal_sync_alert.log"
}

function Resolve-SourceSignalPackPath {
    param([string]$InputPath)

    if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
        if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
            throw "指定的源文件不存在: $InputPath"
        }
        return (Resolve-Path -LiteralPath $InputPath).Path
    }

    $candidates = @(
        (Join-Path $env:USERPROFILE ".blockcell\workspace\domain_experts\forex\ea\signal_pack.json"),
        (Join-Path $eaRoot "signal_pack.json")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw "未找到默认源文件。请通过 -SourceSignalPackPath 指定 signal_pack.json 路径。"
}

function Resolve-RunnerDir {
    param([string]$InputPath)

    $dir = $InputPath
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $dir = Join-Path $eaRoot ".mt4_portable_runner"
    }
    if (Test-Path -LiteralPath $dir -PathType Leaf) {
        throw "RunnerDir 不能是文件: $dir"
    }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "RunnerDir 不存在: $dir"
    }
    return (Resolve-Path -LiteralPath $dir).Path
}

function Resolve-VerifyScriptPath {
    param([string]$InputPath)

    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        throw "校验脚本不存在: $InputPath"
    }
    return (Resolve-Path -LiteralPath $InputPath).Path
}

function Resolve-PwshPath {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Path)) {
        return $cmd.Path
    }
    $fallback = "C:\Program Files\PowerShell\7\pwsh.exe"
    if (Test-Path -LiteralPath $fallback -PathType Leaf) {
        return $fallback
    }
    throw "未找到 pwsh 可执行文件。"
}

function Ensure-ParentDirectory {
    param([string]$FilePath)

    $dir = Split-Path -Parent $FilePath
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-MonitorLog {
    param(
        [string]$Path,
        [string]$Level,
        [string]$Message
    )

    Rotate-LogIfNeeded -Path $Path -MaxBytes $script:MaxLogBytes -MaxBackups $script:MaxLogBackups
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Rotate-LogIfNeeded {
    param(
        [string]$Path,
        [int64]$MaxBytes,
        [int]$MaxBackups
    )

    if ($MaxBytes -le 0) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.Length -lt $MaxBytes) {
        return
    }

    $oldest = "{0}.{1}" -f $Path, $MaxBackups
    if (Test-Path -LiteralPath $oldest -PathType Leaf) {
        Remove-Item -LiteralPath $oldest -Force
    }

    for ($i = $MaxBackups - 1; $i -ge 1; $i--) {
        $src = "{0}.{1}" -f $Path, $i
        $dst = "{0}.{1}" -f $Path, ($i + 1)
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            Move-Item -LiteralPath $src -Destination $dst -Force
        }
    }

    Move-Item -LiteralPath $Path -Destination ("{0}.1" -f $Path) -Force
}

function Parse-BoolLike {
    param([string]$Value)

    $raw = [string]$Value
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $true
    }
    $v = $raw.Trim().ToLowerInvariant()
    if ($v -eq "1" -or $v -eq "true" -or $v -eq "$true") {
        return $true
    }
    if ($v -eq "0" -or $v -eq "false" -or $v -eq "$false") {
        return $false
    }
    throw "RequireCurrentValidWindow 仅支持 true/false/1/0，当前值: $Value"
}

$resolvedSource = Resolve-SourceSignalPackPath -InputPath $SourceSignalPackPath
$resolvedRunner = Resolve-RunnerDir -InputPath $RunnerDir
$resolvedVerify = Resolve-VerifyScriptPath -InputPath $VerifyScriptPath
$pwshPath = Resolve-PwshPath
$requireWindow = Parse-BoolLike -Value $RequireCurrentValidWindow
$script:MaxLogBytes = [int64]$MaxLogSizeKB * 1KB
$script:MaxLogBackups = $MaxLogBackups

Ensure-ParentDirectory -FilePath $HealthLogPath
Ensure-ParentDirectory -FilePath $AlertLogPath

$verifyArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $resolvedVerify,
    "-SourceSignalPackPath", $resolvedSource,
    "-RunnerDir", $resolvedRunner,
    "-MaxMtimeDiffSeconds", [string]$MaxMtimeDiffSeconds,
    "-MaxAgeMinutes", [string]$MaxAgeMinutes
)
if ($requireWindow) {
    $verifyArgs += "-RequireCurrentValidWindow"
}

Write-MonitorLog -Path $HealthLogPath -Level "INFO" -Message ("health_check start: source={0}, runner={1}, require_window={2}" -f $resolvedSource, $resolvedRunner, $requireWindow)

$output = & $pwshPath @verifyArgs 2>&1
$exitCode = $LASTEXITCODE

foreach ($lineObj in $output) {
    $line = [string]$lineObj
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }
    Write-MonitorLog -Path $HealthLogPath -Level "INFO" -Message ("verify> {0}" -f $line)
}

if ($exitCode -eq 0) {
    Write-MonitorLog -Path $HealthLogPath -Level "INFO" -Message "health_check result=OK"
    exit 0
}

$summaryLine = $output | Where-Object { $_ -match "^RESULT=" } | Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace([string]$summaryLine)) {
    $summaryLine = "RESULT=FAILED"
}
$alertMsg = ("health_check FAILED exit={0} summary={1} source={2} runner={3}" -f $exitCode, $summaryLine, $resolvedSource, $resolvedRunner)
Write-MonitorLog -Path $HealthLogPath -Level "ERROR" -Message $alertMsg
Write-MonitorLog -Path $AlertLogPath -Level "ERROR" -Message $alertMsg
exit $exitCode
