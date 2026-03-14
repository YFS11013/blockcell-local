<#
.SYNOPSIS
    将仓库中的 skill 同步到 blockcell workspace（~/.blockcell/workspace/skills/）。

.DESCRIPTION
    扫描 domain_experts/forex/skills/ 下的所有子目录，
    将每个 skill 的运行时文件（SKILL.rhai / SKILL.md / meta.yaml / meta.json）
    复制到 blockcell workspace。

.PARAMETER WorkspaceDir
    blockcell workspace 路径。默认：~/.blockcell/workspace

.PARAMETER SkillsSourceDir
    仓库中 skill 源码根目录。默认：脚本所在目录（即 domain_experts/forex/skills/）

.PARAMETER DryRun
    只打印将要执行的操作，不实际复制。

.EXAMPLE
    # 部署所有 skill（默认 workspace）
    .\deploy_skills.ps1

    # 预览，不实际写入
    .\deploy_skills.ps1 -DryRun

    # 指定自定义 workspace
    .\deploy_skills.ps1 -WorkspaceDir "D:\blockcell\workspace"
#>
[CmdletBinding()]
param(
    [string]$WorkspaceDir    = "",
    [string]$SkillsSourceDir = "",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 路径解析 ──────────────────────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($WorkspaceDir)) {
    $WorkspaceDir = Join-Path $env:USERPROFILE ".blockcell\workspace"
}
if ([string]::IsNullOrWhiteSpace($SkillsSourceDir)) {
    $SkillsSourceDir = $PSScriptRoot   # 脚本放在 skills/ 目录下
}

$destSkillsRoot = Join-Path $WorkspaceDir "skills"

Write-Host "[INFO] 源目录:    $SkillsSourceDir"
Write-Host "[INFO] 目标目录:  $destSkillsRoot"
if ($DryRun) { Write-Host "[INFO] DryRun 模式，不实际写入。" }

# blockcell 加载的运行时文件
$runtimeFiles = @("SKILL.rhai", "SKILL.py", "SKILL.md", "meta.yaml", "meta.json")

# ── 扫描并部署 ────────────────────────────────────────────────────────────────

$deployed = 0
$skipped  = 0

Get-ChildItem -Path $SkillsSourceDir -Directory | ForEach-Object {
    $skillName = $_.Name
    $skillSrc  = $_.FullName
    $skillDst  = Join-Path $destSkillsRoot $skillName

    # 检查是否有至少一个运行时文件
    $hasRuntime = $runtimeFiles | Where-Object { Test-Path (Join-Path $skillSrc $_) }
    if (-not $hasRuntime) {
        Write-Host "[SKIP] $skillName — 无运行时文件（SKILL.rhai/SKILL.py/SKILL.md）"
        $skipped++
        return
    }

    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $skillDst -Force | Out-Null
    }

    foreach ($file in $runtimeFiles) {
        $src = Join-Path $skillSrc $file
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }

        $dst = Join-Path $skillDst $file
        if ($DryRun) {
            Write-Host "[DRY]  $src  →  $dst"
        } else {
            Copy-Item -LiteralPath $src -Destination $dst -Force
            Write-Host "[COPY] $skillName/$file"
        }
    }
    $deployed++
}

Write-Host ""
Write-Host "==== deploy_skills 完成 ===="
Write-Host "已部署: $deployed  跳过: $skipped"
if (-not $DryRun) {
    Write-Host "目标:   $destSkillsRoot"
}
