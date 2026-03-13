[CmdletBinding()]
param(
    [ValidateSet("Install", "Remove", "Status", "RunNow", "Stop")]
    [string]$Action = "Install",
    [string]$TaskName = "Blockcell-Forex-SignalPackSync",
    [string]$SyncScriptPath = "",
    [string]$SourceSignalPackPath = "",
    [string]$RunnerDir = "",
    [ValidateRange(1, 3600)]
    [int]$PollIntervalSeconds = 30,
    [string]$PwshPath = "",
    [switch]$StartNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$eaRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:HasScheduledTaskModule = [bool](Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)

function Is-AccessDeniedMessage {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }
    return ($Message -like "*拒绝访问*") `
        -or ($Message -like "*Access is denied*") `
        -or ($Message -like "*is denied*")
}

function Resolve-SyncScriptPath {
    param([string]$InputPath)

    $path = $InputPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path $PSScriptRoot "sync_signal_pack_continuous.ps1"
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "同步脚本不存在: $path"
    }
    return (Resolve-Path -LiteralPath $path).Path
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
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
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

function Get-StartupLauncherPath {
    param([string]$Name)

    $startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
    return Join-Path $startupDir ("{0}.cmd" -f $Name)
}

function Build-SyncArguments {
    param(
        [string]$SyncScriptPath,
        [string]$SourcePath,
        [string]$RunnerPath,
        [int]$PollSeconds
    )

    return ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -SourceSignalPackPath "{1}" -RunnerDir "{2}" -PollIntervalSeconds {3}' -f `
        $SyncScriptPath, `
        $SourcePath, `
        $RunnerPath, `
        $PollSeconds)
}

function Install-StartupLauncher {
    param(
        [string]$LauncherPath,
        [string]$PwshExePath,
        [string]$SyncArgs
    )

    $startupDir = Split-Path -Parent $LauncherPath
    if (-not (Test-Path -LiteralPath $startupDir -PathType Container)) {
        New-Item -ItemType Directory -Path $startupDir -Force | Out-Null
    }

    $cmdLine = ('"{0}" {1}' -f $PwshExePath, $SyncArgs)
    $content = @(
        "@echo off"
        ('start "" {0}' -f $cmdLine)
    )
    Set-Content -LiteralPath $LauncherPath -Value $content -Encoding ASCII -Force -ErrorAction Stop
}

function Try-GetScheduledTaskSafe {
    param([string]$Name)

    $result = [ordered]@{
        Task         = $null
        AccessDenied = $false
        ErrorMessage = ""
    }

    if (-not $script:HasScheduledTaskModule) {
        $result.ErrorMessage = "ScheduledTasks 模块不可用"
        return [pscustomobject]$result
    }

    try {
        $result.Task = Get-ScheduledTask -TaskName $Name -ErrorAction Stop
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
    param([string]$Name)

    $result = [ordered]@{
        Info         = $null
        AccessDenied = $false
        ErrorMessage = ""
    }

    if (-not $script:HasScheduledTaskModule) {
        $result.ErrorMessage = "ScheduledTasks 模块不可用"
        return [pscustomobject]$result
    }

    try {
        $result.Info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction Stop
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
    param([string]$Name)

    $result = [ordered]@{
        Removed      = $false
        AccessDenied = $false
        ErrorMessage = ""
    }

    if (-not $script:HasScheduledTaskModule) {
        $result.ErrorMessage = "ScheduledTasks 模块不可用"
        return [pscustomobject]$result
    }

    try {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop
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

function Try-StartScheduledTaskSafe {
    param([string]$Name)

    $result = [ordered]@{
        Started      = $false
        AccessDenied = $false
        ErrorMessage = ""
    }

    if (-not $script:HasScheduledTaskModule) {
        $result.ErrorMessage = "ScheduledTasks 模块不可用"
        return [pscustomobject]$result
    }

    try {
        Start-ScheduledTask -TaskName $Name -ErrorAction Stop
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

function Find-SyncProcesses {
    param(
        [string]$SyncScriptFullPath,
        [string]$RunnerPath = ""
    )

    $result = [ordered]@{
        Processes    = @()
        AccessDenied = $false
        ErrorMessage = ""
    }

    try {
        $all = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction Stop
        $syncPathLower = $SyncScriptFullPath.ToLowerInvariant()
        $runnerPathLower = $RunnerPath.ToLowerInvariant()
        $matches = @()
        foreach ($p in $all) {
            $cmdLine = [string]$p.CommandLine
            if ([string]::IsNullOrWhiteSpace($cmdLine)) {
                continue
            }
            $cmdLower = $cmdLine.ToLowerInvariant()
            if (-not ($cmdLower.Contains("sync_signal_pack_continuous.ps1") -and $cmdLower.Contains($syncPathLower))) {
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($runnerPathLower) -and -not $cmdLower.Contains($runnerPathLower)) {
                continue
            }
            $matches += $p
        }
        $result.Processes = $matches
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

function Stop-SyncProcesses {
    param(
        [string]$SyncScriptFullPath,
        [string]$RunnerPath = ""
    )

    $find = Find-SyncProcesses -SyncScriptFullPath $SyncScriptFullPath -RunnerPath $RunnerPath
    $result = [ordered]@{
        StoppedCount = 0
        FailedCount  = 0
        AccessDenied = $find.AccessDenied
        ErrorMessage = $find.ErrorMessage
    }

    if ($find.AccessDenied) {
        return [pscustomobject]$result
    }

    foreach ($proc in $find.Processes) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            $result.StoppedCount++
        }
        catch {
            $result.FailedCount++
            $result.ErrorMessage = $_.Exception.Message
        }
    }

    return [pscustomobject]$result
}

switch ($Action) {
    "Status" {
        $taskLookup = Try-GetScheduledTaskSafe -Name $TaskName
        $launcherPath = Get-StartupLauncherPath -Name $TaskName
        $hasLauncher = Test-Path -LiteralPath $launcherPath -PathType Leaf

        if ($taskLookup.AccessDenied) {
            Write-Host "任务计划状态: 无权限读取（可能存在）: $TaskName"
        }
        elseif ($null -ne $taskLookup.Task) {
            $infoLookup = Try-GetScheduledTaskInfoSafe -Name $TaskName
            Write-Host "任务计划存在: $TaskName"
            Write-Host "  State: $($taskLookup.Task.State)"
            if ($infoLookup.AccessDenied) {
                Write-Host "  详情: 无权限读取任务详情"
            }
            elseif ($null -ne $infoLookup.Info) {
                Write-Host "  LastRunTime: $($infoLookup.Info.LastRunTime)"
                Write-Host "  LastTaskResult: $($infoLookup.Info.LastTaskResult)"
                Write-Host "  NextRunTime: $($infoLookup.Info.NextRunTime)"
            }
            elseif (-not [string]::IsNullOrWhiteSpace($infoLookup.ErrorMessage)) {
                Write-Host "  详情读取失败: $($infoLookup.ErrorMessage)"
            }
        }
        else {
            Write-Host "任务计划不存在: $TaskName"
        }

        if ($hasLauncher) {
            Write-Host "启动文件夹启动器存在: $launcherPath"
        }
        else {
            Write-Host "启动文件夹启动器不存在: $launcherPath"
        }
        exit 0
    }

    "Remove" {
        $taskLookup = Try-GetScheduledTaskSafe -Name $TaskName
        $launcherPath = Get-StartupLauncherPath -Name $TaskName
        $removedAny = $false

        if ($taskLookup.AccessDenied) {
            Write-Host "警告: 无权限删除任务计划: $TaskName"
        }
        elseif ($null -ne $taskLookup.Task) {
            $removeTaskResult = Try-UnregisterScheduledTaskSafe -Name $TaskName
            if ($removeTaskResult.Removed) {
                Write-Host "已删除任务计划: $TaskName"
                $removedAny = $true
            }
            else {
                Write-Host "警告: 删除任务计划失败: $($removeTaskResult.ErrorMessage)"
            }
        }

        if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $launcherPath -Force
                Write-Host "已删除启动文件夹启动器: $launcherPath"
                $removedAny = $true
            }
            catch {
                Write-Host "警告: 删除启动文件夹启动器失败: $($_.Exception.Message)"
            }
        }

        if (-not $removedAny) {
            Write-Host "未发现可删除的自动同步启动器: task=$TaskName, launcher=$launcherPath"
        }
        exit 0
    }

    "RunNow" {
        $taskLookup = Try-GetScheduledTaskSafe -Name $TaskName
        if (-not $taskLookup.AccessDenied -and $null -ne $taskLookup.Task) {
            $startResult = Try-StartScheduledTaskSafe -Name $TaskName
            if ($startResult.Started) {
                Write-Host "已触发任务计划立即运行: $TaskName"
                exit 0
            }
            Write-Host "警告: 任务计划立即运行失败: $($startResult.ErrorMessage)"
        }

        $launcherPath = Get-StartupLauncherPath -Name $TaskName
        if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
            if ($taskLookup.AccessDenied) {
                throw "无法读取任务计划且找不到启动器，无法运行: $TaskName"
            }
            throw "任务计划和启动器都不存在，无法运行: $TaskName"
        }
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$launcherPath`"" -WindowStyle Hidden
        Write-Host "已通过启动文件夹启动器触发运行: $launcherPath"
        exit 0
    }

    "Stop" {
        $resolvedSyncScriptPath = Resolve-SyncScriptPath -InputPath $SyncScriptPath
        $resolvedRunnerDir = Resolve-RunnerDir -InputPath $RunnerDir
        $launcherPath = Get-StartupLauncherPath -Name $TaskName
        $taskLookup = Try-GetScheduledTaskSafe -Name $TaskName
        $removedAny = $false

        if ($taskLookup.AccessDenied) {
            Write-Host "警告: 无权限停止/删除任务计划: $TaskName"
        }
        elseif ($null -ne $taskLookup.Task) {
            $removeTaskResult = Try-UnregisterScheduledTaskSafe -Name $TaskName
            if ($removeTaskResult.Removed) {
                Write-Host "已删除任务计划: $TaskName"
                $removedAny = $true
            }
            else {
                Write-Host "警告: 删除任务计划失败: $($removeTaskResult.ErrorMessage)"
            }
        }

        if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $launcherPath -Force
                Write-Host "已删除启动文件夹启动器: $launcherPath"
                $removedAny = $true
            }
            catch {
                Write-Host "警告: 删除启动文件夹启动器失败: $($_.Exception.Message)"
            }
        }

        $stopResult = Stop-SyncProcesses -SyncScriptFullPath $resolvedSyncScriptPath -RunnerPath $resolvedRunnerDir
        if ($stopResult.AccessDenied) {
            Write-Host "警告: 无权限枚举/停止同步进程，建议以管理员权限重试。"
        }
        else {
            Write-Host "已停止同步进程数量: $($stopResult.StoppedCount)"
            if ($stopResult.FailedCount -gt 0) {
                Write-Host "停止失败数量: $($stopResult.FailedCount), 原因: $($stopResult.ErrorMessage)"
            }
        }

        if (-not $removedAny -and $stopResult.StoppedCount -eq 0 -and -not $stopResult.AccessDenied) {
            Write-Host "未发现可清理的启动器或运行中同步进程。"
        }
        exit 0
    }

    "Install" {
        $resolvedSyncScriptPath = Resolve-SyncScriptPath -InputPath $SyncScriptPath
        $resolvedSourceSignalPackPath = Resolve-SourceSignalPackPath -InputPath $SourceSignalPackPath
        $resolvedRunnerDir = Resolve-RunnerDir -InputPath $RunnerDir
        $resolvedPwshPath = Resolve-PwshPath -InputPath $PwshPath
        $launcherPath = Get-StartupLauncherPath -Name $TaskName

        $arguments = Build-SyncArguments `
            -SyncScriptPath $resolvedSyncScriptPath `
            -SourcePath $resolvedSourceSignalPackPath `
            -RunnerPath $resolvedRunnerDir `
            -PollSeconds $PollIntervalSeconds

        $scheduledTaskInstalled = $false
        if ($script:HasScheduledTaskModule) {
            $existingTask = Try-GetScheduledTaskSafe -Name $TaskName
            if ($existingTask.AccessDenied) {
                Write-Host "警告: 无权限读取现有任务计划，跳过任务计划模式，回退启动文件夹自启。"
            }
            else {
                if ($null -ne $existingTask.Task) {
                    $removeExisting = Try-UnregisterScheduledTaskSafe -Name $TaskName
                    if (-not $removeExisting.Removed) {
                        if ($removeExisting.AccessDenied) {
                            Write-Host "警告: 无权限替换现有任务计划，回退启动文件夹自启。"
                        }
                        else {
                            Write-Host "警告: 替换现有任务计划失败，回退启动文件夹自启。原因: $($removeExisting.ErrorMessage)"
                        }
                    }
                }

                if (-not $scheduledTaskInstalled) {
                    $actionObj = New-ScheduledTaskAction `
                        -Execute $resolvedPwshPath `
                        -Argument $arguments `
                        -WorkingDirectory (Split-Path -Parent $resolvedSyncScriptPath)

                    $triggerObj = New-ScheduledTaskTrigger -AtLogOn
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
                        Action      = $actionObj
                        Trigger     = $triggerObj
                        Settings    = $settingsObj
                        Principal   = $principalObj
                        Description = "Auto-sync signal_pack.json to MT4 runner targets at user logon"
                        Force       = $true
                    }

                    try {
                        Register-ScheduledTask @registerParams | Out-Null
                        $scheduledTaskInstalled = $true
                    }
                    catch {
                        $msg = $_.Exception.Message
                        if (Is-AccessDeniedMessage -Message $msg) {
                            Write-Host "任务计划注册被拒绝，尝试默认上下文重试..."
                            $registerParams.Remove("Principal") | Out-Null
                            try {
                                Register-ScheduledTask @registerParams | Out-Null
                                $scheduledTaskInstalled = $true
                            }
                            catch {
                                if (Is-AccessDeniedMessage -Message $_.Exception.Message) {
                                    Write-Host "任务计划注册仍被拒绝，回退启动文件夹自启模式。"
                                    $scheduledTaskInstalled = $false
                                }
                                else {
                                    throw
                                }
                            }
                        }
                        else {
                            throw
                        }
                    }
                }
            }
        }

        if ($scheduledTaskInstalled) {
            if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
                Remove-Item -LiteralPath $launcherPath -Force
            }

            Write-Host "任务计划已安装: $TaskName"
            Write-Host "  Source:  $resolvedSourceSignalPackPath"
            Write-Host "  Runner:  $resolvedRunnerDir"
            Write-Host "  Interval: $PollIntervalSeconds s"

            if ($StartNow) {
                $startResult = Try-StartScheduledTaskSafe -Name $TaskName
                if ($startResult.Started) {
                    Write-Host "已触发任务计划立即运行: $TaskName"
                }
                else {
                    Write-Host "警告: 无法立即启动任务计划: $($startResult.ErrorMessage)"
                    Write-Host "任务将在下次登录时自动运行。"
                }
            }
            exit 0
        }

        try {
            Install-StartupLauncher -LauncherPath $launcherPath -PwshExePath $resolvedPwshPath -SyncArgs $arguments
        }
        catch {
            if (Is-AccessDeniedMessage -Message $_.Exception.Message) {
                throw "无法写入启动文件夹启动器（权限不足）。请以管理员权限运行，或手动授予 Startup 目录写权限。"
            }
            throw
        }
        Write-Host "已安装启动文件夹自启: $launcherPath"
        Write-Host "  Source:  $resolvedSourceSignalPackPath"
        Write-Host "  Runner:  $resolvedRunnerDir"
        Write-Host "  Interval: $PollIntervalSeconds s"
        if ($StartNow) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$launcherPath`"" -WindowStyle Hidden
            Write-Host "已触发启动器立即运行。"
        }
        exit 0
    }
}
