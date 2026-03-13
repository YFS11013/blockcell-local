[CmdletBinding()]
param(
    [string]$RunnerDir = "",
    [ValidateRange(0, 3650)]
    [int]$RetentionDays = 14,
    [ValidateRange(0, 1048576)]
    [int]$MaxTotalSizeMB = 1024,
    [string[]]$IncludeRelativeDirs = @("logs", "MQL4\\Logs", "tester\\logs"),
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$eaRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

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
        $rawParts = @($entry)
        if (-not [string]::IsNullOrWhiteSpace($entry) -and ($entry.Contains(",") -or $entry.Contains(";"))) {
            $rawParts = $entry.Split([string[]]@(",", ";"), [System.StringSplitOptions]::RemoveEmptyEntries)
        }

        foreach ($rawPart in $rawParts) {
            $candidate = [string]$rawPart
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }
            $candidate = $candidate.Trim().Trim('"').Trim("'")

            $normalized = Normalize-IncludeRelativeDir -InputPath $candidate
            if ([string]::IsNullOrWhiteSpace($normalized)) {
                continue
            }
            if ($seen.Add($normalized)) {
                $resolved.Add($normalized) | Out-Null
            }
        }
    }

    if ($resolved.Count -eq 0) {
        throw "IncludeRelativeDirs 不能为空。"
    }
    return $resolved
}

function Collect-TargetFiles {
    param(
        [string]$ResolvedRunnerDir,
        [System.Collections.Generic.List[string]]$RelativeDirs
    )

    $fileMap = @{}
    foreach ($relativeDir in $RelativeDirs) {
        $targetDir = Join-Path $ResolvedRunnerDir $relativeDir
        if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
            Write-Host ("skip_missing_dir: {0}" -f $targetDir)
            continue
        }

        $items = Get-ChildItem -LiteralPath $targetDir -Recurse -File -ErrorAction Stop
        foreach ($item in $items) {
            $fileMap[$item.FullName] = $item
        }
    }
    return ,@($fileMap.GetEnumerator() | ForEach-Object { $_.Value })
}

function Get-TotalBytes {
    param([object[]]$Files)

    $measure = $Files | Measure-Object -Property Length -Sum
    if ($null -eq $measure) {
        return [int64]0
    }
    $sum = $measure.Sum
    if ($null -eq $sum) {
        return [int64]0
    }
    return [int64]$sum
}

function Remove-FileWithReport {
    param(
        [System.IO.FileInfo]$File,
        [string]$Reason,
        [switch]$DryRunMode
    )

    $result = [ordered]@{
        Removed = $false
        Error   = $null
        Bytes   = [int64]$File.Length
    }

    if ($DryRunMode) {
        Write-Host ("[DryRun] remove reason={0} path={1}" -f $Reason, $File.FullName)
        $result.Removed = $true
        return [pscustomobject]$result
    }

    try {
        Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop
        Write-Host ("removed reason={0} path={1}" -f $Reason, $File.FullName)
        $result.Removed = $true
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-Warning ("remove_failed reason={0} path={1} error={2}" -f $Reason, $File.FullName, $result.Error)
    }
    return [pscustomobject]$result
}

try {
    $resolvedRunnerDir = Resolve-RunnerDir -InputPath $RunnerDir
    $resolvedRelativeDirs = Resolve-IncludeRelativeDirs -InputDirs $IncludeRelativeDirs
    $relativeDirText = ($resolvedRelativeDirs -join ", ")

    $initialFiles = Collect-TargetFiles -ResolvedRunnerDir $resolvedRunnerDir -RelativeDirs $resolvedRelativeDirs
    $initialBytes = Get-TotalBytes -Files $initialFiles

    $retentionDeletedFiles = 0
    $retentionDeletedBytes = [int64]0
    $sizeDeletedFiles = 0
    $sizeDeletedBytes = [int64]0
    $deleteErrors = 0

    Write-Host ("runner_dir={0}" -f $resolvedRunnerDir)
    Write-Host ("include_dirs={0}" -f $relativeDirText)
    Write-Host ("retention_days={0} max_total_mb={1} dry_run={2}" -f $RetentionDays, $MaxTotalSizeMB, $DryRun.IsPresent)
    Write-Host ("before_total_files={0} before_total_bytes={1}" -f @($initialFiles).Count, $initialBytes)

    if ($RetentionDays -gt 0) {
        $cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
        $retentionCandidates = $initialFiles |
            Where-Object { $_.LastWriteTimeUtc -lt $cutoffUtc } |
            Sort-Object LastWriteTimeUtc, FullName

        foreach ($candidate in $retentionCandidates) {
            $removeResult = Remove-FileWithReport -File $candidate -Reason "retention" -DryRunMode:$DryRun.IsPresent
            if ($removeResult.Removed) {
                $retentionDeletedFiles++
                $retentionDeletedBytes += [int64]$removeResult.Bytes
            }
            elseif ($null -ne $removeResult.Error) {
                $deleteErrors++
            }
        }
    }
    else {
        Write-Host "retention_cleanup_disabled: RetentionDays=0"
    }

    $afterRetentionFiles = Collect-TargetFiles -ResolvedRunnerDir $resolvedRunnerDir -RelativeDirs $resolvedRelativeDirs
    $afterRetentionBytes = Get-TotalBytes -Files $afterRetentionFiles

    if ($MaxTotalSizeMB -gt 0) {
        $maxBytes = [int64]$MaxTotalSizeMB * 1MB
        if ($afterRetentionBytes -gt $maxBytes) {
            $sizeCandidates = $afterRetentionFiles | Sort-Object LastWriteTimeUtc, FullName
            $runningBytes = $afterRetentionBytes

            foreach ($candidate in $sizeCandidates) {
                if ($runningBytes -le $maxBytes) {
                    break
                }
                $removeResult = Remove-FileWithReport -File $candidate -Reason "size_cap" -DryRunMode:$DryRun.IsPresent
                if ($removeResult.Removed) {
                    $sizeDeletedFiles++
                    $sizeDeletedBytes += [int64]$removeResult.Bytes
                    $runningBytes -= [int64]$removeResult.Bytes
                }
                elseif ($null -ne $removeResult.Error) {
                    $deleteErrors++
                }
            }
        }
    }
    else {
        Write-Host "size_cleanup_disabled: MaxTotalSizeMB=0"
    }

    $finalFiles = Collect-TargetFiles -ResolvedRunnerDir $resolvedRunnerDir -RelativeDirs $resolvedRelativeDirs
    $finalBytes = Get-TotalBytes -Files $finalFiles

    Write-Host ("deleted_retention_files={0} deleted_retention_bytes={1}" -f $retentionDeletedFiles, $retentionDeletedBytes)
    Write-Host ("deleted_size_files={0} deleted_size_bytes={1}" -f $sizeDeletedFiles, $sizeDeletedBytes)
    Write-Host ("after_total_files={0} after_total_bytes={1}" -f @($finalFiles).Count, $finalBytes)

    if ($deleteErrors -gt 0) {
        Write-Error ("cleanup completed with delete_errors={0}" -f $deleteErrors)
        exit 1
    }

    exit 0
}
catch {
    Write-Error ("runner log cleanup failed: {0}" -f $_.Exception.Message)
    exit 1
}
