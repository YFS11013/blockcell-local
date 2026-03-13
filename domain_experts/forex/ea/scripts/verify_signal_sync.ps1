[CmdletBinding()]
param(
    [string]$SourceSignalPackPath = "",
    [string]$RunnerDir = "",
    [ValidateRange(1, 86400)]
    [int]$MaxMtimeDiffSeconds = 300,
    [ValidateRange(0, 10080)]
    [int]$MaxAgeMinutes = 0,
    [switch]$RequireCurrentValidWindow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$eaRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

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

function Try-ParseUtc {
    param([string]$Value)

    $result = [ordered]@{
        ok = $false
        value = [datetime]::MinValue
    }
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [pscustomobject]$result
    }

    $dto = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse(
            $Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$dto)) {
        $result.ok = $true
        $result.value = $dto.UtcDateTime
    }
    return [pscustomobject]$result
}

function Get-SignalPackMeta {
    param(
        [string]$Role,
        [string]$Path
    )

    $meta = [ordered]@{
        role = $Role
        path = $Path
        exists = $false
        hash = ""
        size = 0
        last_write_utc = [datetime]::MinValue
        version = ""
        valid_from_raw = ""
        valid_to_raw = ""
        valid_from_utc = [datetime]::MinValue
        valid_to_utc = [datetime]::MinValue
        valid_from_ok = $false
        valid_to_ok = $false
        parse_error = ""
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$meta
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $meta.exists = $true
    $meta.size = [int64]$item.Length
    $meta.last_write_utc = $item.LastWriteTimeUtc
    $meta.hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash

    try {
        $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $obj.version) {
            $meta.version = [string]$obj.version
        }
        if ($null -ne $obj.valid_from) {
            $meta.valid_from_raw = [string]$obj.valid_from
            $vf = Try-ParseUtc -Value $meta.valid_from_raw
            $meta.valid_from_ok = $vf.ok
            if ($vf.ok) {
                $meta.valid_from_utc = $vf.value
            }
        }
        if ($null -ne $obj.valid_to) {
            $meta.valid_to_raw = [string]$obj.valid_to
            $vt = Try-ParseUtc -Value $meta.valid_to_raw
            $meta.valid_to_ok = $vt.ok
            if ($vt.ok) {
                $meta.valid_to_utc = $vt.value
            }
        }
    }
    catch {
        $meta.parse_error = $_.Exception.Message
    }

    return [pscustomobject]$meta
}

function Add-Issue {
    param(
        [System.Collections.Generic.List[string]]$Issues,
        [string]$Message
    )
    $Issues.Add($Message) | Out-Null
}

function Add-Warn {
    param(
        [System.Collections.Generic.List[string]]$Warnings,
        [string]$Message
    )
    $Warnings.Add($Message) | Out-Null
}

function Get-HashPrefix {
    param([string]$Hash)

    if ([string]::IsNullOrWhiteSpace($Hash)) {
        return "<empty>"
    }
    $len = [Math]::Min(12, $Hash.Length)
    return $Hash.Substring(0, $len)
}

$utcNow = (Get-Date).ToUniversalTime()
$sourcePath = Resolve-SourceSignalPackPath -InputPath $SourceSignalPackPath
$resolvedRunnerDir = Resolve-RunnerDir -InputPath $RunnerDir

$livePath = Join-Path $resolvedRunnerDir "MQL4\Files\signal_pack.json"
$testerPath = Join-Path $resolvedRunnerDir "tester\files\signal_pack.json"

$metas = @(
    (Get-SignalPackMeta -Role "source" -Path $sourcePath),
    (Get-SignalPackMeta -Role "live_target" -Path $livePath),
    (Get-SignalPackMeta -Role "tester_target" -Path $testerPath)
)

$issues = New-Object 'System.Collections.Generic.List[string]'
$warnings = New-Object 'System.Collections.Generic.List[string]'

foreach ($m in $metas) {
    if (-not $m.exists) {
        Add-Issue -Issues $issues -Message ("{0} 文件不存在: {1}" -f $m.role, $m.path)
        continue
    }
    if (-not [string]::IsNullOrWhiteSpace($m.parse_error)) {
        Add-Issue -Issues $issues -Message ("{0} JSON 解析失败: {1}" -f $m.role, $m.parse_error)
    }
    if ([string]::IsNullOrWhiteSpace($m.version)) {
        Add-Issue -Issues $issues -Message ("{0} 缺少 version 字段: {1}" -f $m.role, $m.path)
    }
}

$missingMetas = @($metas | Where-Object { -not $_.exists })
$allExist = $missingMetas.Count -eq 0
if ($allExist) {
    $hashes = @($metas | ForEach-Object { $_.hash } | Select-Object -Unique)
    if ($hashes.Count -ne 1) {
        $hashDetail = ($metas | ForEach-Object {
                "{0}={1}" -f $_.role, (Get-HashPrefix -Hash $_.hash)
            }) -join ", "
        Add-Issue -Issues $issues -Message ("source/live/tester 文件哈希不一致: {0}" -f $hashDetail)
    }

    $versions = @($metas | ForEach-Object { $_.version } | Select-Object -Unique)
    if ($versions.Count -ne 1) {
        Add-Issue -Issues $issues -Message ("source/live/tester 参数版本不一致: {0}" -f (($versions -join ", ")))
    }

    $sourceMeta = $metas | Where-Object { $_.role -eq "source" } | Select-Object -First 1
    foreach ($targetMeta in ($metas | Where-Object { $_.role -ne "source" })) {
        $deltaSec = [Math]::Abs(($targetMeta.last_write_utc - $sourceMeta.last_write_utc).TotalSeconds)
        if ($deltaSec -gt $MaxMtimeDiffSeconds) {
            Add-Issue -Issues $issues -Message ("{0} 与 source 更新时间差过大: {1:N0}s > {2}s" -f $targetMeta.role, $deltaSec, $MaxMtimeDiffSeconds)
        }
    }
}

if ($MaxAgeMinutes -gt 0) {
    foreach ($m in $metas | Where-Object { $_.exists }) {
        $ageMinutes = ($utcNow - $m.last_write_utc).TotalMinutes
        if ($ageMinutes -gt $MaxAgeMinutes) {
            Add-Issue -Issues $issues -Message ("{0} 文件超过新鲜度阈值: {1:N1}m > {2}m" -f $m.role, $ageMinutes, $MaxAgeMinutes)
        }
    }
}

if ($RequireCurrentValidWindow) {
    foreach ($m in $metas | Where-Object { $_.exists }) {
        if (-not $m.valid_from_ok -or -not $m.valid_to_ok) {
            Add-Issue -Issues $issues -Message ("{0} valid_from/valid_to 解析失败: from={1}, to={2}" -f $m.role, $m.valid_from_raw, $m.valid_to_raw)
            continue
        }
        if ($utcNow -lt $m.valid_from_utc) {
            Add-Issue -Issues $issues -Message ("{0} 参数尚未生效: now={1}, valid_from={2}" -f $m.role, $utcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"), $m.valid_from_utc.ToString("yyyy-MM-ddTHH:mm:ssZ"))
        }
        if ($utcNow -gt $m.valid_to_utc) {
            Add-Issue -Issues $issues -Message ("{0} 参数已过期: now={1}, valid_to={2}" -f $m.role, $utcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"), $m.valid_to_utc.ToString("yyyy-MM-ddTHH:mm:ssZ"))
        }
    }
}
else {
    foreach ($m in $metas | Where-Object { $_.exists -and $_.valid_to_ok }) {
        if ($utcNow -gt $m.valid_to_utc) {
            Add-Warn -Warnings $warnings -Message ("{0} 参数已过期（仅告警，未开启 -RequireCurrentValidWindow）: valid_to={1}" -f $m.role, $m.valid_to_utc.ToString("yyyy-MM-ddTHH:mm:ssZ"))
        }
    }
}

Write-Host "==== Signal Sync Verify ===="
Write-Host ("utc_now={0}" -f $utcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"))
Write-Host ("source={0}" -f $sourcePath)
Write-Host ("runner={0}" -f $resolvedRunnerDir)
Write-Host ("max_mtime_diff_seconds={0}" -f $MaxMtimeDiffSeconds)
Write-Host ("max_age_minutes={0}" -f $MaxAgeMinutes)
Write-Host ("require_current_valid_window={0}" -f $RequireCurrentValidWindow.IsPresent)

foreach ($m in $metas) {
    if (-not $m.exists) {
        Write-Host ("[{0}] exists=false path={1}" -f $m.role, $m.path)
        continue
    }
    $lastWriteUtcText = $m.last_write_utc.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Host ("[{0}] exists=true version={1} hash={2} last_write_utc={3}" -f $m.role, $m.version, $m.hash.Substring(0, 12), $lastWriteUtcText)
}

if ($warnings.Count -gt 0) {
    Write-Host "WARNINGS:"
    foreach ($w in $warnings) {
        Write-Host ("- {0}" -f $w)
    }
}

if ($issues.Count -gt 0) {
    Write-Host "RESULT=FAILED"
    foreach ($issue in $issues) {
        Write-Host ("- {0}" -f $issue)
    }
    exit 2
}

Write-Host "RESULT=OK"
exit 0
