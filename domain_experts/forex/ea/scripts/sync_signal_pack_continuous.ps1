[CmdletBinding()]
param(
    [string]$SourceSignalPackPath = "",
    [string]$RunnerDir = "",
    [ValidateRange(1, 3600)]
    [int]$PollIntervalSeconds = 30,
    [switch]$RunOnce,
    [switch]$ForceSync,
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$eaRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($RunnerDir)) {
    $RunnerDir = Join-Path $eaRoot ".mt4_portable_runner"
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $eaRoot "backtest_artifacts\signal_sync.log"
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

function Ensure-ParentDirectory {
    param([string]$FilePath)

    $dir = Split-Path -Parent $FilePath
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Get-InstanceLockName {
    param([string]$RunnerPath)

    $normalized = $RunnerPath.ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hashBytes = $sha1.ComputeHash($bytes)
    }
    finally {
        $sha1.Dispose()
    }
    $hashHex = [System.BitConverter]::ToString($hashBytes).Replace("-", "")
    return "Local\Blockcell_Forex_SignalSync_$hashHex"
}

function Acquire-InstanceLock {
    param([string]$RunnerPath)

    $lockName = Get-InstanceLockName -RunnerPath $RunnerPath
    $mutex = New-Object System.Threading.Mutex($false, $lockName)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }

    if (-not $acquired) {
        $mutex.Dispose()
        return $null
    }

    return $mutex
}

function Release-InstanceLock {
    if ($null -eq $script:InstanceMutex) {
        return
    }

    try {
        $script:InstanceMutex.ReleaseMutex()
    }
    catch {
        # Ignore if mutex is already released.
    }

    try {
        $script:InstanceMutex.Dispose()
    }
    catch {
        # Ignore dispose errors on shutdown.
    }
    $script:InstanceMutex = $null
}

function Write-SyncLog {
    param(
        [string]$Level,
        [string]$Message
    )

    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Get-FileSha256OrEmpty {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-SourceVersion {
    param([string]$Path)

    try {
        $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $obj -and $null -ne $obj.version) {
            return [string]$obj.version
        }
    }
    catch {
        return "<unknown>"
    }
    return "<unknown>"
}

function Copy-WithRetry {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [int]$MaxAttempts = 3
    )

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            Copy-Item -LiteralPath $SourcePath -Destination $TargetPath -Force
            return
        }
        catch {
            if ($i -eq $MaxAttempts) {
                throw
            }
            Start-Sleep -Seconds 1
        }
    }
}

function Invoke-SignalPackSync {
    param(
        [string]$Reason,
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $script:SourceSignalPackPath -PathType Leaf)) {
        Write-SyncLog -Level "WARN" -Message "源文件不存在，跳过本轮同步: source=$($script:SourceSignalPackPath), reason=$Reason"
        return @{
            changed = $false
            had_error = $true
        }
    }

    $sourceHash = Get-FileSha256OrEmpty -Path $script:SourceSignalPackPath
    if ([string]::IsNullOrWhiteSpace($sourceHash)) {
        Write-SyncLog -Level "WARN" -Message "无法计算源文件哈希，跳过本轮同步: source=$($script:SourceSignalPackPath), reason=$Reason"
        return @{
            changed = $false
            had_error = $true
        }
    }

    $sourceVersion = Get-SourceVersion -Path $script:SourceSignalPackPath
    $copiedTargets = @()
    $failedTargets = @()

    foreach ($targetPath in $script:TargetPaths) {
        try {
            $targetHash = Get-FileSha256OrEmpty -Path $targetPath
            $needCopy = $Force -or [string]::IsNullOrWhiteSpace($targetHash) -or ($targetHash -ne $sourceHash)
            if (-not $needCopy) {
                continue
            }

            Copy-WithRetry -SourcePath $script:SourceSignalPackPath -TargetPath $targetPath -MaxAttempts 3
            $verifyHash = Get-FileSha256OrEmpty -Path $targetPath
            if ($verifyHash -ne $sourceHash) {
                throw "同步后哈希不一致"
            }
            $copiedTargets += $targetPath
        }
        catch {
            $failedTargets += @{
                target = $targetPath
                error = $_.Exception.Message
            }
        }
    }

    if ($failedTargets.Count -gt 0) {
        foreach ($failure in $failedTargets) {
            Write-SyncLog -Level "ERROR" -Message ("同步失败: source={0}, target={1}, reason={2}, version={3}" -f $script:SourceSignalPackPath, $failure.target, $failure.error, $sourceVersion)
        }
    }

    if ($copiedTargets.Count -gt 0) {
        $targetText = ($copiedTargets -join "; ")
        Write-SyncLog -Level "INFO" -Message ("同步成功: reason={0}, version={1}, targets={2}" -f $Reason, $sourceVersion, $targetText)
        return @{
            changed = $true
            had_error = ($failedTargets.Count -gt 0)
        }
    }

    return @{
        changed = $false
        had_error = ($failedTargets.Count -gt 0)
    }
}

$script:InstanceMutex = $null

try {
    $script:SourceSignalPackPath = Resolve-SourceSignalPackPath -InputPath $SourceSignalPackPath
    if (Test-Path -LiteralPath $RunnerDir -PathType Leaf) {
        throw "RunnerDir 不能是文件: $RunnerDir"
    }
    if (-not (Test-Path -LiteralPath $RunnerDir -PathType Container)) {
        New-Item -ItemType Directory -Path $RunnerDir -Force | Out-Null
    }
    $script:RunnerDir = (Resolve-Path -LiteralPath $RunnerDir).Path
    $script:LogPath = $LogPath

    $liveTarget = Join-Path $script:RunnerDir "MQL4\Files\signal_pack.json"
    $testerTarget = Join-Path $script:RunnerDir "tester\files\signal_pack.json"
    $script:TargetPaths = @($liveTarget, $testerTarget)

    Ensure-ParentDirectory -FilePath $script:LogPath
    foreach ($targetPath in $script:TargetPaths) {
        Ensure-ParentDirectory -FilePath $targetPath
    }

    $script:InstanceMutex = Acquire-InstanceLock -RunnerPath $script:RunnerDir
    if ($null -eq $script:InstanceMutex) {
        $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $line = "[$ts] [INFO] 检测到已有同步实例运行，当前实例退出。runner=$($script:RunnerDir)"
        Write-Host $line
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
        exit 0
    }

    Write-SyncLog -Level "INFO" -Message ("启动参数包同步: source={0}, poll={1}s, run_once={2}, force_sync={3}" -f $script:SourceSignalPackPath, $PollIntervalSeconds, $RunOnce.IsPresent, $ForceSync.IsPresent)

    [void](Invoke-SignalPackSync -Reason "startup" -Force:($ForceSync.IsPresent -or $RunOnce.IsPresent))

    if ($RunOnce) {
        Write-SyncLog -Level "INFO" -Message "一次性同步完成，脚本退出。"
        exit 0
    }

    $heartbeatLoops = [Math]::Max(1, [int](600 / $PollIntervalSeconds))
    $loop = 0

    while ($true) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $loop++
        $result = Invoke-SignalPackSync -Reason "poll" -Force:$false
        if (-not $result.changed -and -not $result.had_error -and ($loop % $heartbeatLoops -eq 0)) {
            Write-SyncLog -Level "INFO" -Message "同步服务运行中，当前无变更。"
        }
    }
}
finally {
    Release-InstanceLock
}
