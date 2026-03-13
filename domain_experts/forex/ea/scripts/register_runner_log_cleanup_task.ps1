[CmdletBinding()]
param(
    [ValidateSet("Install", "Status", "RunNow", "Remove")]
    [string]$Action = "Install",
    [string]$TaskName = "Blockcell-Forex-RunnerLogCleanup",
    [string]$TaskPath = "\blockcell\",
    [string]$CleanupScriptPath = "",
    [string]$RunnerDir = "",
    [ValidateRange(0, 3650)]
    [int]$RetentionDays = 14,
    [ValidateRange(0, 1048576)]
    [int]$MaxTotalSizeMB = 1024,
    [string[]]$IncludeRelativeDirs = @("logs", "MQL4\\Logs", "tester\\logs"),
    [ValidateRange(5, 1440)]
    [int]$IntervalMinutes = 180,
    [string]$PwshPath = "",
    [switch]$StartNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$eaRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Is-AccessDeniedMessage {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }
    return ($Message -like "*拒绝访问*") `
        -or ($Message -like "*Access is denied*") `
        -or ($Message -like "*is denied*")
}

function Is-TaskNotFoundMessage {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }
    return ($Message -like "*找不到*") `
        -or ($Message -like "*不存在*") `
        -or ($Message -like "*cannot find*") `
        -or ($Message -like "*No MSFT_ScheduledTask objects found*") `
        -or ($Message -like "*No matching MSFT_ScheduledTask objects found*")
}

function Resolve-CleanupScriptPath {
    param([string]$InputPath)

    $path = $InputPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path $PSScriptRoot "cleanup_runner_logs.ps1"
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "日志清理脚本不存在: $path"
    }
    return (Resolve-Path -LiteralPath $path).Path
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

function Resolve-PwshPath {
    param([string]$InputPath)

    if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
        if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
            throw "指定的 pwsh 路径不存在: $InputPath"
        }
        return (Resolve-Path -LiteralPath $InputPath).Path
    }

    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Path)) {
        return $cmd.Path
    }

    $fallback = "C:\Program Files\PowerShell\7\pwsh.exe"
    if (Test-Path -LiteralPath $fallback -PathType Leaf) {
        return $fallback
    }

    throw "未找到 pwsh，可通过 -PwshPath 指定。"
}

function Resolve-TaskPath {
    param([string]$InputPath)

    $path = $InputPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = "\"
    }

    $normalized = $path.Trim().Replace("/", "\")
    $normalized = [regex]::Replace($normalized, '\\{2,}', '\')

    if (-not $normalized.StartsWith("\")) {
        $normalized = "\" + $normalized
    }
    if (($normalized.Length -gt 1) -and (-not $normalized.EndsWith("\"))) {
        $normalized += "\"
    }
    return $normalized
}

function Normalize-IncludeRelativeDir {
    param([string]$InputPath)

    if ([string]::IsNullOrWhiteSpace($InputPath)) {
        return $null
    }

    $normalized = $InputPath.Trim().Replace("/", "\")
    $normalized = [regex]::Replace($normalized, '\\{2,}', '\')
    $normalized = $normalized.TrimStart("\")
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }
    if ($normalized.Contains(":")) {
        throw "IncludeRelativeDirs 必须是相对路径，不能包含盘符: $InputPath"
    }

    $segments = $normalized.Split("\") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($segment in $segments) {
        if ($segment -eq "..") {
            throw "IncludeRelativeDirs 不允许包含 '..': $InputPath"
        }
    }
    return ($segments -join "\")
}

function Resolve-IncludeRelativeDirs {
    param([string[]]$InputDirs)

    $resolved = New-Object System.Collections.Generic.List[string]
    $seen = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in $InputDirs) {
        $normalized = Normalize-IncludeRelativeDir -InputPath $entry
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }
        if ($seen.Add($normalized)) {
            $resolved.Add($normalized) | Out-Null
        }
    }

    if ($resolved.Count -eq 0) {
        throw "IncludeRelativeDirs 不能为空。"
    }
    return $resolved
}

function Try-GetScheduledTaskSafe {
    param(
        [string]$Name,
        [string]$Path
    )

    $result = [ordered]@{
        Task         = $null
        AccessDenied = $false
        ErrorMessage = ""
    }
    try {
        $result.Task = Get-ScheduledTask -TaskName $Name -TaskPath $Path -ErrorAction Stop
    }
    catch {
        $msg = $_.Exception.Message
        $result.ErrorMessage = $msg
        if (Is-AccessDeniedMessage -Message $msg) {
            $result.AccessDenied = $true
        }
    }
    return [pscustomobject]$result
}

function Try-GetScheduledTaskInfoSafe {
    param(
        [string]$Name,
        [string]$Path
    )

    $result = [ordered]@{
        Info         = $null
        AccessDenied = $false
        ErrorMessage = ""
    }
    try {
        $result.Info = Get-ScheduledTaskInfo -TaskName $Name -TaskPath $Path -ErrorAction Stop
    }
    catch {
        $msg = $_.Exception.Message
        $result.ErrorMessage = $msg
        if (Is-AccessDeniedMessage -Message $msg) {
            $result.AccessDenied = $true
        }
    }
    return [pscustomobject]$result
}

function Try-StartScheduledTaskSafe {
    param(
        [string]$Name,
        [string]$Path
    )

    $result = [ordered]@{
        Started      = $false
        AccessDenied = $false
        ErrorMessage = ""
    }
    try {
        Start-ScheduledTask -TaskName $Name -TaskPath $Path -ErrorAction Stop
        $result.Started = $true
    }
    catch {
        $msg = $_.Exception.Message
        $result.ErrorMessage = $msg
        if (Is-AccessDeniedMessage -Message $msg) {
            $result.AccessDenied = $true
        }
    }
    return [pscustomobject]$result
}

function Try-UnregisterScheduledTaskSafe {
    param(
        [string]$Name,
        [string]$Path
    )

    $result = [ordered]@{
        Removed      = $false
        AccessDenied = $false
        ErrorMessage = ""
    }
    try {
        Unregister-ScheduledTask -TaskName $Name -TaskPath $Path -Confirm:$false -ErrorAction Stop
        $result.Removed = $true
    }
    catch {
        $msg = $_.Exception.Message
        $result.ErrorMessage = $msg
        if (Is-AccessDeniedMessage -Message $msg) {
            $result.AccessDenied = $true
        }
    }
    return [pscustomobject]$result
}

function Assert-InstallPermissionEarly {
    param(
        [string]$Name,
        [string]$Path
    )

    $probe = Try-GetScheduledTaskSafe -Name $Name -Path $Path
    if ($probe.AccessDenied) {
        throw "Install 前置权限检查失败：当前会话无权限访问任务计划。请以管理员权限执行后重试。"
    }

    if (($null -eq $probe.Task) -and `
            (-not [string]::IsNullOrWhiteSpace($probe.ErrorMessage)) -and `
            (-not (Is-TaskNotFoundMessage -Message $probe.ErrorMessage))) {
        throw ("Install 前置检查失败：任务计划服务不可用或访问异常: {0}" -f $probe.ErrorMessage)
    }

    return $probe
}

function Build-CleanupArguments {
    param(
        [string]$CleanupScript,
        [string]$ResolvedRunnerDir,
        [int]$KeepDays,
        [int]$MaxSizeMB,
        [System.Collections.Generic.List[string]]$RelativeDirs
    )

    $parts = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $CleanupScript),
        "-RunnerDir", ('"{0}"' -f $ResolvedRunnerDir),
        "-RetentionDays", [string]$KeepDays,
        "-MaxTotalSizeMB", [string]$MaxSizeMB
    )

    if ($RelativeDirs.Count -gt 0) {
        $dirArrayLiteral = (($RelativeDirs | ForEach-Object { '"{0}"' -f $_ }) -join ",")
        $parts += "-IncludeRelativeDirs"
        $parts += $dirArrayLiteral
    }

    return ($parts -join " ")
}

if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    throw "当前环境不可用 ScheduledTasks 模块，无法管理 runner 日志清理任务。"
}

$resolvedTaskPath = Resolve-TaskPath -InputPath $TaskPath

switch ($Action) {
    "Status" {
        $taskLookup = Try-GetScheduledTaskSafe -Name $TaskName -Path $resolvedTaskPath
        if ($taskLookup.AccessDenied) {
            Write-Host "runner 日志清理任务状态: 无权限读取（可能存在）: $resolvedTaskPath$TaskName"
            exit 0
        }
        if ($null -eq $taskLookup.Task) {
            Write-Host "runner 日志清理任务不存在: $resolvedTaskPath$TaskName"
            exit 0
        }

        $infoLookup = Try-GetScheduledTaskInfoSafe -Name $TaskName -Path $resolvedTaskPath
        Write-Host "runner 日志清理任务存在: $resolvedTaskPath$TaskName"
        Write-Host ("  State: {0}" -f $taskLookup.Task.State)
        if ($infoLookup.AccessDenied) {
            Write-Host "  详情: 无权限读取任务详情"
        }
        elseif ($null -ne $infoLookup.Info) {
            Write-Host ("  LastRunTime: {0}" -f $infoLookup.Info.LastRunTime)
            Write-Host ("  LastTaskResult: {0}" -f $infoLookup.Info.LastTaskResult)
            Write-Host ("  NextRunTime: {0}" -f $infoLookup.Info.NextRunTime)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($infoLookup.ErrorMessage)) {
            Write-Host ("  详情读取失败: {0}" -f $infoLookup.ErrorMessage)
        }
        exit 0
    }

    "RunNow" {
        $taskLookup = Try-GetScheduledTaskSafe -Name $TaskName -Path $resolvedTaskPath
        if ($taskLookup.AccessDenied) {
            throw "无权限读取任务计划，无法触发 RunNow。"
        }
        if ($null -eq $taskLookup.Task) {
            throw "runner 日志清理任务不存在: $resolvedTaskPath$TaskName"
        }

        $runResult = Try-StartScheduledTaskSafe -Name $TaskName -Path $resolvedTaskPath
        if (-not $runResult.Started) {
            throw ("触发 runner 日志清理任务失败: {0}" -f $runResult.ErrorMessage)
        }
        Write-Host "已触发 runner 日志清理任务立即运行。"
        exit 0
    }

    "Remove" {
        $taskLookup = Try-GetScheduledTaskSafe -Name $TaskName -Path $resolvedTaskPath
        if ($taskLookup.AccessDenied) {
            throw "无权限删除 runner 日志清理任务。请以管理员权限执行。"
        }
        if ($null -eq $taskLookup.Task) {
            Write-Host "runner 日志清理任务不存在，无需删除: $resolvedTaskPath$TaskName"
            exit 0
        }

        $removeResult = Try-UnregisterScheduledTaskSafe -Name $TaskName -Path $resolvedTaskPath
        if (-not $removeResult.Removed) {
            throw ("删除 runner 日志清理任务失败: {0}" -f $removeResult.ErrorMessage)
        }
        Write-Host "已删除 runner 日志清理任务: $resolvedTaskPath$TaskName"
        exit 0
    }

    "Install" {
        $existingTask = Assert-InstallPermissionEarly -Name $TaskName -Path $resolvedTaskPath
        Write-Host "Install 前置权限检查通过：可访问任务计划服务。"

        $resolvedScript = Resolve-CleanupScriptPath -InputPath $CleanupScriptPath
        $resolvedRunner = Resolve-RunnerDir -InputPath $RunnerDir
        $resolvedPwsh = Resolve-PwshPath -InputPath $PwshPath
        $resolvedRelativeDirs = Resolve-IncludeRelativeDirs -InputDirs $IncludeRelativeDirs

        if ($null -ne $existingTask.Task) {
            $removeExisting = Try-UnregisterScheduledTaskSafe -Name $TaskName -Path $resolvedTaskPath
            if (-not $removeExisting.Removed) {
                throw ("替换现有 runner 日志清理任务失败: {0}" -f $removeExisting.ErrorMessage)
            }
        }

        $arguments = Build-CleanupArguments `
            -CleanupScript $resolvedScript `
            -ResolvedRunnerDir $resolvedRunner `
            -KeepDays $RetentionDays `
            -MaxSizeMB $MaxTotalSizeMB `
            -RelativeDirs $resolvedRelativeDirs

        $actionObj = New-ScheduledTaskAction `
            -Execute $resolvedPwsh `
            -Argument $arguments `
            -WorkingDirectory (Split-Path -Parent $resolvedScript)

        $triggerObj = New-ScheduledTaskTrigger `
            -Once `
            -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
            -RepetitionDuration (New-TimeSpan -Days 3650)

        $settingsObj = New-ScheduledTaskSettingsSet `
            -StartWhenAvailable `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -MultipleInstances IgnoreNew

        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principalObj = New-ScheduledTaskPrincipal `
            -UserId $currentUser `
            -LogonType Interactive `
            -RunLevel Limited

        $registerParams = @{
            TaskName    = $TaskName
            TaskPath    = $resolvedTaskPath
            Action      = $actionObj
            Trigger     = $triggerObj
            Settings    = $settingsObj
            Principal   = $principalObj
            Description = "Periodic cleanup for MT4 portable runner logs"
            Force       = $true
        }

        $installed = $false
        try {
            Register-ScheduledTask @registerParams | Out-Null
            $installed = $true
        }
        catch {
            if (Is-AccessDeniedMessage -Message $_.Exception.Message) {
                Write-Host "检测到 Principal 注册被拒绝，尝试默认当前用户上下文重试..."
                $registerParams.Remove("Principal") | Out-Null
                try {
                    Register-ScheduledTask @registerParams | Out-Null
                    $installed = $true
                }
                catch {
                    throw ("创建 runner 日志清理任务失败: {0}" -f $_.Exception.Message)
                }
            }
            else {
                throw
            }
        }

        if (-not $installed) {
            throw "创建 runner 日志清理任务失败: 未知错误。"
        }

        Write-Host "runner 日志清理任务已安装: $resolvedTaskPath$TaskName"
        Write-Host ("  IntervalMinutes: {0}" -f $IntervalMinutes)
        Write-Host ("  RunnerDir:       {0}" -f $resolvedRunner)
        Write-Host ("  RetentionDays:   {0}" -f $RetentionDays)
        Write-Host ("  MaxTotalSizeMB:  {0}" -f $MaxTotalSizeMB)
        Write-Host ("  IncludeDirs:     {0}" -f ($resolvedRelativeDirs -join ", "))

        if ($StartNow) {
            $runResult = Try-StartScheduledTaskSafe -Name $TaskName -Path $resolvedTaskPath
            if ($runResult.Started) {
                Write-Host "已触发 runner 日志清理任务立即运行。"
            }
            else {
                Write-Host ("警告: 无法立即启动 runner 日志清理任务: {0}" -f $runResult.ErrorMessage)
            }
        }
        exit 0
    }
}
