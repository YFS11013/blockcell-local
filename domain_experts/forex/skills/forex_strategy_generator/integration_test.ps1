[CmdletBinding()]
param(
    [string]$GatewayUrl = $(if ($env:BLOCKCELL_GATEWAY_URL) { $env:BLOCKCELL_GATEWAY_URL } else { "http://localhost:18790" }),
    [string]$SkillName = $(if ($env:SKILL_NAME) { $env:SKILL_NAME } else { "forex_strategy_generator" }),
    [int]$RunLiveTests = $(if ($env:RUN_LIVE_TESTS) { [int]$env:RUN_LIVE_TESTS } else { 1 }),
    [int]$StrictMode = $(if ($env:STRICT_MODE) { [int]$env:STRICT_MODE } else { 1 }),
    [int]$TestTimeoutSec = $(if ($env:TEST_TIMEOUT_SEC) { [int]$env:TEST_TIMEOUT_SEC } else { 45 }),
    [string]$ParamFile = $env:PARAM_FILE,
    [string]$ApiToken = $(if ($env:BLOCKCELL_GATEWAY_TOKEN) { $env:BLOCKCELL_GATEWAY_TOKEN } elseif ($env:BLOCKCELL_API_TOKEN) { $env:BLOCKCELL_API_TOKEN } else { "" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0

function Write-Header([string]$Text) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Pass([string]$Text) {
    Write-Host "[PASS] $Text" -ForegroundColor Green
}

function Write-Fail([string]$Text) {
    Write-Host "[FAIL] $Text" -ForegroundColor Red
}

function Write-Warn([string]$Text) {
    Write-Host "[WARN] $Text" -ForegroundColor Yellow
}

function Write-Info([string]$Text) {
    Write-Host "[INFO] $Text" -ForegroundColor Blue
}

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path
}

function Ensure-ApiToken {
    if (-not [string]::IsNullOrWhiteSpace($ApiToken)) {
        return
    }

    $localConfig = Join-Path $HOME ".blockcell\config.json5"
    if (-not (Test-Path -LiteralPath $localConfig -PathType Leaf)) {
        return
    }

    $raw = Get-Content -LiteralPath $localConfig -Raw
    $match = [regex]::Match($raw, '"apiToken"\s*:\s*"([^"]+)"')
    if ($match.Success) {
        $script:ApiToken = $match.Groups[1].Value
    }
}

function Get-AuthHeaders {
    if ([string]::IsNullOrWhiteSpace($ApiToken)) {
        return @{}
    }
    return @{ Authorization = "Bearer $ApiToken" }
}

function Gateway-Reachable {
    $headers = Get-AuthHeaders
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "$GatewayUrl/v1/health" -Headers $headers -TimeoutSec 5
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
                return $true
            }
        } catch {
        }

        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "$GatewayUrl/health" -Headers $headers -TimeoutSec 5
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
                return $true
            }
        } catch {
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Ensure-ParamTargetReady([string]$Path) {
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Set-Content -LiteralPath $Path -Value "" -Encoding UTF8
    }
}

function Get-MtimeToken([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return [int64](Get-Item -LiteralPath $Path).LastWriteTimeUtc.ToFileTimeUtc()
}

function Wait-ParamFileUpdate([string]$Path, $PreviousMtime, [int]$TimeoutSec) {
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSec) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $current = [int64](Get-Item -LiteralPath $Path).LastWriteTimeUtc.ToFileTimeUtc()
            if ($null -eq $PreviousMtime -or $current -gt $PreviousMtime) {
                return $true
            }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Trigger-SkillOnce {
    $headers = Get-AuthHeaders
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 3000
    $jobName = "forex_param_generator_task13_$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
    $payload = @{
        name             = $jobName
        message          = "Task 13 integration test generate parameter pack"
        at_ms            = $nowMs
        skill_name       = $SkillName
        delete_after_run = $true
        deliver          = $false
    } | ConvertTo-Json -Compress

    $resp = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$GatewayUrl/v1/cron" -Headers $headers -ContentType "application/json" -Body $payload -TimeoutSec 10
    if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 300) {
        throw "创建一次性 Cron 任务失败: HTTP $($resp.StatusCode)"
    }
    Write-Info "一次性 Cron 任务创建成功，等待执行..."
}

function Parse-Iso8601Utc([string]$Value) {
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $result = [DateTimeOffset]::MinValue
    $ok = [DateTimeOffset]::TryParseExact($Value, "yyyy-MM-ddTHH:mm:ssZ", $culture, $styles, [ref]$result)
    if (-not $ok) {
        return $null
    }
    return $result.ToUniversalTime()
}

function Convert-ToIso8601UtcString([object]$Value) {
    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [string]) {
        return [string]$Value
    }

    if ($Value -is [DateTime]) {
        $dt = [DateTime]$Value
        if ($dt.Kind -eq [DateTimeKind]::Unspecified) {
            $dt = [DateTime]::SpecifyKind($dt, [DateTimeKind]::Local)
        }
        return $dt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    return [string]$Value
}

function Assert-ParameterContract([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "参数文件不存在: $Path"
    }

    try {
        $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "JSON 格式无效: $($_.Exception.Message)"
    }

    $requiredFields = @(
        "version", "symbol", "timeframe", "bias", "valid_from", "valid_to",
        "entry_zone", "invalid_above", "tp_levels", "tp_ratios",
        "ema_fast", "ema_trend", "lookback_period", "touch_tolerance",
        "pattern", "risk", "max_spread_points", "max_slippage_points"
    )

    foreach ($field in $requiredFields) {
        if ($null -eq $data.PSObject.Properties[$field]) {
            throw "参数缺少必需字段: $field"
        }
    }

    if ($data.symbol -ne "EURUSD") { throw "symbol 非法: $($data.symbol) (期望 EURUSD)" }
    if ($data.timeframe -ne "H4") { throw "timeframe 非法: $($data.timeframe) (期望 H4)" }
    if ($data.bias -ne "short_only") { throw "bias 非法: $($data.bias) (期望 short_only)" }

    if ($data.version -notmatch "^\d{8}-\d{4}$") {
        throw "version 格式非法: $($data.version) (期望 YYYYMMDD-HHMM)"
    }

    $validFromText = Convert-ToIso8601UtcString -Value $data.valid_from
    $validToText = Convert-ToIso8601UtcString -Value $data.valid_to
    $validFrom = Parse-Iso8601Utc -Value $validFromText
    $validTo = Parse-Iso8601Utc -Value $validToText
    if ($null -eq $validFrom) { throw "valid_from 非法: $validFromText" }
    if ($null -eq $validTo) { throw "valid_to 非法: $validToText" }
    if ($validFrom -ge $validTo) { throw "valid_from 必须早于 valid_to: $validFromText >= $validToText" }

    if ($null -eq $data.entry_zone -or $null -eq $data.entry_zone.min -or $null -eq $data.entry_zone.max) {
        throw "entry_zone 缺少 min 或 max"
    }
    if ([double]$data.entry_zone.min -ge [double]$data.entry_zone.max) {
        throw "entry_zone 校验失败: min 必须小于 max"
    }

    if ([double]$data.invalid_above -le 0) { throw "invalid_above 必须大于 0" }

    if ([double]$data.ema_fast -le 0 -or [double]$data.ema_trend -le 0 -or [double]$data.lookback_period -le 0 -or [double]$data.touch_tolerance -le 0) {
        throw "技术指标参数存在非法值（应全部 > 0）"
    }

    if ($null -eq $data.risk) { throw "risk 必须是对象" }
    if ($null -eq $data.risk.per_trade -or $null -eq $data.risk.daily_max_loss -or $null -eq $data.risk.consecutive_loss_limit) {
        throw "risk 字段缺失"
    }

    $perTrade = [double]$data.risk.per_trade
    $dailyMaxLoss = [double]$data.risk.daily_max_loss
    $consecutiveLoss = [int]$data.risk.consecutive_loss_limit

    if ($perTrade -le 0 -or $perTrade -gt 0.1) { throw "risk.per_trade 超出范围 (0, 0.1]" }
    if ($dailyMaxLoss -le 0 -or $dailyMaxLoss -gt 0.2) { throw "risk.daily_max_loss 超出范围 (0, 0.2]" }
    if ($consecutiveLoss -le 0) { throw "risk.consecutive_loss_limit 必须大于 0" }

    if ([double]$data.max_spread_points -le 0 -or [double]$data.max_slippage_points -le 0) {
        throw "执行参数非法（max_spread_points/max_slippage_points 必须 > 0）"
    }

    if (-not ($data.tp_levels -is [System.Array]) -or -not ($data.tp_ratios -is [System.Array])) {
        throw "tp_levels/tp_ratios 必须是数组"
    }
    if ($data.tp_levels.Count -le 0 -or $data.tp_ratios.Count -le 0) {
        throw "tp_levels/tp_ratios 不能为空"
    }
    if ($data.tp_levels.Count -ne $data.tp_ratios.Count) {
        throw "tp_levels/tp_ratios 长度非法: tp_levels=$($data.tp_levels.Count), tp_ratios=$($data.tp_ratios.Count)"
    }

    $ratioSum = 0.0
    foreach ($r in $data.tp_ratios) { $ratioSum += [double]$r }
    if ([Math]::Abs($ratioSum - 1.0) -gt 1e-6) {
        throw "tp_ratios 总和必须为 1.0，当前值: $ratioSum"
    }

    if (-not ($data.pattern -is [System.Array]) -or $data.pattern.Count -le 0) {
        throw "pattern 数组不能为空"
    }

    if ($null -ne $data.news_blackout) {
        if (-not ($data.news_blackout -is [System.Array])) {
            throw "news_blackout 必须是数组"
        }
        for ($i = 0; $i -lt $data.news_blackout.Count; $i++) {
            $item = $data.news_blackout[$i]
            if ($null -eq $item.start -or $null -eq $item.end) {
                throw "news_blackout[$i] 缺少 start 或 end"
            }
            $startText = Convert-ToIso8601UtcString -Value $item.start
            $endText = Convert-ToIso8601UtcString -Value $item.end
            $start = Parse-Iso8601Utc -Value $startText
            $end = Parse-Iso8601Utc -Value $endText
            if ($null -eq $start -or $null -eq $end) {
                throw "news_blackout[$i] 时间格式非法: start=$startText, end=$endText"
            }
            if ($start -ge $end) {
                throw "news_blackout[$i] 时间窗口非法: start >= end"
            }
        }
    }

    if ($null -ne $data.session_filter) {
        $enabled = [bool]$data.session_filter.enabled
        if ($enabled) {
            if (-not ($data.session_filter.allowed_hours_utc -is [System.Array]) -or $data.session_filter.allowed_hours_utc.Count -eq 0) {
                throw "session_filter.enabled=true 但 allowed_hours_utc 为空"
            }
            foreach ($hour in $data.session_filter.allowed_hours_utc) {
                if ($hour -isnot [ValueType]) { throw "session_filter.allowed_hours_utc 包含非整数" }
                $h = [double]$hour
                if ([Math]::Floor($h) -ne $h) { throw "session_filter.allowed_hours_utc 包含非整数" }
                if ($h -lt 0 -or $h -gt 23) { throw "session_filter.allowed_hours_utc 包含非法小时（必须为 0-23 的整数）" }
            }
        }
    }
}

function Test-BlockcellParamGeneration([string]$SkillFile, [string]$GatewaySkillFile, [string]$ParamPath) {
    Write-Header "测试 1: Blockcell 参数生成"

    if (-not (Test-Path -LiteralPath $SkillFile -PathType Leaf)) {
        Write-Fail "SKILL 文件不存在: $SkillFile"
        return 1
    }
    Write-Info "已找到 Skill 文件: $SkillFile"

    Ensure-ParamTargetReady -Path $ParamPath
    $beforeMtime = Get-MtimeToken -Path $ParamPath

    if ($RunLiveTests -eq 1) {
        if (-not (Test-Path -LiteralPath $GatewaySkillFile -PathType Leaf)) {
            Write-Fail "Gateway 侧 skill 未安装: $GatewaySkillFile"
            Write-Fail "请先将 skill 同步到 ~/.blockcell/workspace/skills/$SkillName/"
            return 1
        }

        if (-not (Gateway-Reachable)) {
            Write-Fail "无法连接 Gateway: $GatewayUrl"
            Write-Fail "请先启动 Blockcell，或设置 RUN_LIVE_TESTS=0 仅做离线契约校验"
            return 1
        }

        try {
            Trigger-SkillOnce
        } catch {
            Write-Fail "触发在线生成失败: $($_.Exception.Message)"
            return 1
        }

        if (-not (Wait-ParamFileUpdate -Path $ParamPath -PreviousMtime $beforeMtime -TimeoutSec $TestTimeoutSec)) {
            Write-Fail "等待参数文件刷新超时 (${TestTimeoutSec}s): $ParamPath"
            return 1
        }
        Write-Info "检测到参数文件已刷新"
    } else {
        Write-Warn "RUN_LIVE_TESTS=0，跳过在线生成触发"
        if (-not (Test-Path -LiteralPath $ParamPath -PathType Leaf)) {
            Write-Warn "本地参数文件不存在，无法离线校验"
            return 2
        }
    }

    try {
        Assert-ParameterContract -Path $ParamPath
        Write-Pass "Blockcell 参数生成验证通过"
        return 0
    } catch {
        Write-Fail $_.Exception.Message
        return 1
    }
}

function Test-EAParamLoadingContract([string]$EAFile, [string]$LoaderFile, [string]$ParamPath) {
    Write-Header "测试 2: EA 参数加载契约校验"

    if (-not (Test-Path -LiteralPath $EAFile -PathType Leaf)) {
        Write-Fail "EA 文件不存在: $EAFile"
        return 1
    }
    if (-not (Test-Path -LiteralPath $LoaderFile -PathType Leaf)) {
        Write-Fail "ParameterLoader 文件不存在: $LoaderFile"
        return 1
    }

    $requiredFunctions = @(
        "LoadParameterPack",
        "ParseParameterJSON",
        "ValidateParameters",
        "ParseISO8601",
        "ParseNewsBlackout",
        "ParseSessionFilter"
    )
    foreach ($func in $requiredFunctions) {
        if ($null -eq (Select-String -Path $LoaderFile -Pattern $func -SimpleMatch)) {
            Write-Fail "ParameterLoader 缺少函数: $func"
            return 1
        }
    }
    Write-Info "ParameterLoader 关键函数齐全"

    if ($null -eq (Select-String -Path $EAFile -Pattern "signal_pack.json" -SimpleMatch)) {
        Write-Fail "EA 未引用 signal_pack.json"
        return 1
    }
    if ($null -eq (Select-String -Path $EAFile -Pattern "ParamFilePath" -SimpleMatch)) {
        Write-Fail "EA 缺少 ParamFilePath 输入参数，无法手动指定参数文件路径"
        return 1
    }
    Write-Info "EA 路径配置检查通过（支持 ParamFilePath 覆盖默认路径）"

    if (-not (Test-Path -LiteralPath $ParamPath -PathType Leaf)) {
        Write-Fail "参数文件不存在，无法验证 EA 加载契约: $ParamPath"
        return 1
    }

    try {
        Assert-ParameterContract -Path $ParamPath
        Write-Info "若在 MT4 中运行，请将 EA 输入参数 ParamFilePath 设置为："
        Write-Info "  $ParamPath"
        Write-Pass "EA 参数加载契约校验通过"
        return 0
    } catch {
        Write-Fail $_.Exception.Message
        return 1
    }
}

function Test-ParamRefreshMechanism([string]$EAFile, [string]$ParamPath) {
    Write-Header "测试 3: 参数刷新机制"

    if ($null -eq (Select-String -Path $EAFile -Pattern "ParamCheckInterval" -SimpleMatch)) {
        Write-Fail "EA 缺少 ParamCheckInterval 配置"
        return 1
    }
    if ($null -eq (Select-String -Path $EAFile -Pattern "CheckParameterUpdate" -SimpleMatch)) {
        Write-Fail "EA 缺少 CheckParameterUpdate 调用/实现"
        return 1
    }
    if ($null -eq (Select-String -Path $EAFile -Pattern "STATE_SAFE_MODE" -SimpleMatch)) {
        Write-Fail "EA 缺少 STATE_SAFE_MODE 状态"
        return 1
    }
    if ($null -eq (Select-String -Path $EAFile -Pattern "TryRecoverFromSafeMode" -SimpleMatch)) {
        Write-Fail "EA 缺少 TryRecoverFromSafeMode 恢复逻辑"
        return 1
    }
    Write-Info "EA 刷新状态机静态检查通过"

    if ($RunLiveTests -ne 1) {
        Write-Warn "RUN_LIVE_TESTS=0，跳过在线刷新验证"
        return 2
    }

    if (-not (Gateway-Reachable)) {
        Write-Fail "无法连接 Gateway，无法执行在线刷新验证: $GatewayUrl"
        return 1
    }

    Ensure-ParamTargetReady -Path $ParamPath
    $baselineMtime = Get-MtimeToken -Path $ParamPath

    Write-Info "触发第 1 次参数生成..."
    try {
        Trigger-SkillOnce
    } catch {
        Write-Fail "第 1 次触发失败: $($_.Exception.Message)"
        return 1
    }
    if (-not (Wait-ParamFileUpdate -Path $ParamPath -PreviousMtime $baselineMtime -TimeoutSec $TestTimeoutSec)) {
        Write-Fail "第 1 次刷新超时"
        return 1
    }

    $mtime1 = Get-MtimeToken -Path $ParamPath
    $json1 = Get-Content -LiteralPath $ParamPath -Raw | ConvertFrom-Json
    $version1 = [string]$json1.version
    $validFrom1 = Parse-Iso8601Utc -Value (Convert-ToIso8601UtcString -Value $json1.valid_from)

    Start-Sleep -Seconds 2

    Write-Info "触发第 2 次参数生成..."
    try {
        Trigger-SkillOnce
    } catch {
        Write-Fail "第 2 次触发失败: $($_.Exception.Message)"
        return 1
    }
    if (-not (Wait-ParamFileUpdate -Path $ParamPath -PreviousMtime $mtime1 -TimeoutSec $TestTimeoutSec)) {
        Write-Fail "第 2 次刷新超时"
        return 1
    }

    $mtime2 = Get-MtimeToken -Path $ParamPath
    $json2 = Get-Content -LiteralPath $ParamPath -Raw | ConvertFrom-Json
    $version2 = [string]$json2.version
    $validFrom2 = Parse-Iso8601Utc -Value (Convert-ToIso8601UtcString -Value $json2.valid_from)

    if ($mtime2 -le $mtime1) {
        Write-Fail "参数文件 mtime 未前进: mtime1=$mtime1, mtime2=$mtime2"
        return 1
    }

    if ($null -eq $validFrom1 -or $null -eq $validFrom2 -or $validFrom2 -lt $validFrom1) {
        $vf1 = Convert-ToIso8601UtcString -Value $json1.valid_from
        $vf2 = Convert-ToIso8601UtcString -Value $json2.valid_from
        Write-Fail "valid_from 未保持前进或持平: $vf1 -> $vf2"
        return 1
    }

    if ($version1 -eq $version2) {
        Write-Warn "version 未变化（版本粒度为分钟，短时间重复触发可能相同）: $version1"
    } else {
        Write-Info "version 已变化: $version1 -> $version2"
    }

    try {
        Assert-ParameterContract -Path $ParamPath
        Write-Pass "参数刷新机制验证通过"
        return 0
    } catch {
        Write-Fail $_.Exception.Message
        return 1
    }
}

function Run-Test([scriptblock]$Fn) {
    $rc = & $Fn
    if ($rc -eq 0) {
        $script:TestsPassed++
    } elseif ($rc -eq 2) {
        $script:TestsSkipped++
    } else {
        $script:TestsFailed++
    }
}

function Main {
    Ensure-ApiToken
    $repoRoot = Get-RepoRoot
    $skillFile = Join-Path $repoRoot "domain_experts\forex\skills\forex_strategy_generator\SKILL.rhai"
    $eaFile = Join-Path $repoRoot "domain_experts\forex\ea\ForexStrategyExecutor.mq4"
    $loaderFile = Join-Path $repoRoot "domain_experts\forex\ea\include\ParameterLoader.mqh"

    $repoParamFile = Join-Path $repoRoot "domain_experts\forex\ea\signal_pack.json"
    $gatewayParamFile = Join-Path $HOME ".blockcell\workspace\domain_experts\forex\ea\signal_pack.json"
    if ([string]::IsNullOrWhiteSpace($ParamFile)) {
        if ($RunLiveTests -eq 1) { $ParamFile = $gatewayParamFile } else { $ParamFile = $repoParamFile }
    }
    $gatewaySkillFile = Join-Path $HOME ".blockcell\workspace\skills\$SkillName\SKILL.rhai"

    Write-Header "MT4 Forex Strategy Executor - Task 13 集成测试 (PowerShell)"
    Write-Host "目标：验证参数生成、EA 加载契约、参数刷新三项闭环"
    Write-Host "Gateway: $GatewayUrl"
    Write-Host "Param file: $ParamFile"
    if ([string]::IsNullOrWhiteSpace($ApiToken)) {
        Write-Host "API token: not configured"
    } else {
        Write-Host "API token: configured"
    }
    Write-Host "RUN_LIVE_TESTS=$RunLiveTests, STRICT_MODE=$StrictMode"

    Run-Test { Test-BlockcellParamGeneration -SkillFile $skillFile -GatewaySkillFile $gatewaySkillFile -ParamPath $ParamFile }
    Run-Test { Test-EAParamLoadingContract -EAFile $eaFile -LoaderFile $loaderFile -ParamPath $ParamFile }
    Run-Test { Test-ParamRefreshMechanism -EAFile $eaFile -ParamPath $ParamFile }

    Write-Header "测试结果汇总"
    Write-Host "通过: $script:TestsPassed" -ForegroundColor Green
    if ($script:TestsFailed -gt 0) {
        Write-Host "失败: $script:TestsFailed" -ForegroundColor Red
    } else {
        Write-Host "失败: $script:TestsFailed" -ForegroundColor Green
    }
    if ($script:TestsSkipped -gt 0) {
        Write-Host "跳过: $script:TestsSkipped" -ForegroundColor Yellow
    } else {
        Write-Host "跳过: $script:TestsSkipped" -ForegroundColor Green
    }

    if ($script:TestsFailed -gt 0) {
        Write-Fail "Task 13 集成测试未通过"
        exit 1
    }
    if ($StrictMode -eq 1 -and $script:TestsSkipped -gt 0) {
        Write-Fail "存在跳过项且 STRICT_MODE=1，判定为未通过"
        exit 1
    }

    Write-Pass "Task 13 集成测试通过"
    exit 0
}

Main
