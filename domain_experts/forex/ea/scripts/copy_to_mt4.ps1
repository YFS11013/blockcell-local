[CmdletBinding()]
param(
    [string]$ExpertsTarget = "C:\Users\ireke\AppData\Roaming\MetaQuotes\Terminal\5E8579BD74E8CDBE63A2CAC44C30C9BE\MQL4\Experts",
    [string]$IncludeTarget = "C:\Users\ireke\AppData\Roaming\MetaQuotes\Terminal\5E8579BD74E8CDBE63A2CAC44C30C9BE\MQL4\Include"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$eaRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$sourceEaFile = Join-Path $eaRoot "ForexStrategyExecutor.mq4"
$sourceIncludeDir = Join-Path $eaRoot "include"
$expertsIncludeDir = Join-Path $ExpertsTarget "include"

if (-not (Test-Path -LiteralPath $sourceEaFile -PathType Leaf)) {
    throw "找不到 EA 主文件: $sourceEaFile"
}

if (-not (Test-Path -LiteralPath $sourceIncludeDir -PathType Container)) {
    throw "找不到 include 目录: $sourceIncludeDir"
}

foreach ($dir in @($ExpertsTarget, $IncludeTarget, $expertsIncludeDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$destEaFile = Join-Path $ExpertsTarget (Split-Path $sourceEaFile -Leaf)
Copy-Item -LiteralPath $sourceEaFile -Destination $destEaFile -Force

$includeFiles = Get-ChildItem -Path $sourceIncludeDir -File -Filter "*.mqh"
if ($includeFiles.Count -eq 0) {
    throw "include 目录下未找到 .mqh 文件: $sourceIncludeDir"
}

foreach ($file in $includeFiles) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $IncludeTarget $file.Name) -Force
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $expertsIncludeDir $file.Name) -Force
}

Write-Host "复制完成:"
Write-Host "  EA 文件 -> $destEaFile"
Write-Host "  头文件 -> $IncludeTarget"
Write-Host "  头文件 -> $expertsIncludeDir"
