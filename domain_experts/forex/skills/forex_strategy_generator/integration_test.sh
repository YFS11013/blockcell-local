#!/usr/bin/env bash
# MT4 Forex Strategy Executor - Task 13 系统集成测试脚本
#
# 覆盖范围（对应 tasks.md 的 Task 13）：
# 1) Blockcell 能成功生成参数包
# 2) EA 能成功加载参数包（契约级校验，对齐 ParameterLoader 规则）
# 3) 参数刷新机制正常工作（定时检查 + 文件刷新）

set -u
set -o pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

GATEWAY_URL="${BLOCKCELL_GATEWAY_URL:-http://localhost:18790}"
SKILL_NAME="${SKILL_NAME:-forex_strategy_generator}"
RUN_LIVE_TESTS="${RUN_LIVE_TESTS:-1}"      # 1: 调用 Gateway 真实触发；0: 跳过在线触发
STRICT_MODE="${STRICT_MODE:-1}"            # 1: 只要有 skipped 就返回失败；0: 允许 skipped
TEST_TIMEOUT_SEC="${TEST_TIMEOUT_SEC:-45}"
API_TOKEN="${BLOCKCELL_GATEWAY_TOKEN:-${BLOCKCELL_API_TOKEN:-}}"

SKILL_FILE="${REPO_ROOT}/domain_experts/forex/skills/forex_strategy_generator/SKILL.rhai"
EA_FILE="${REPO_ROOT}/domain_experts/forex/ea/ForexStrategyExecutor.mq4"
LOADER_FILE="${REPO_ROOT}/domain_experts/forex/ea/include/ParameterLoader.mqh"

REPO_PARAM_FILE="${REPO_ROOT}/domain_experts/forex/ea/signal_pack.json"
GATEWAY_PARAM_FILE="${HOME}/.blockcell/workspace/domain_experts/forex/ea/signal_pack.json"

if [ -n "${PARAM_FILE:-}" ]; then
    PARAM_FILE="${PARAM_FILE}"
elif [ "$RUN_LIVE_TESTS" = "1" ]; then
    PARAM_FILE="${GATEWAY_PARAM_FILE}"
else
    PARAM_FILE="${REPO_PARAM_FILE}"
fi

GATEWAY_SKILL_FILE="${HOME}/.blockcell/workspace/skills/${SKILL_NAME}/SKILL.rhai"

if [ -z "$API_TOKEN" ]; then
    local_cfg="${HOME}/.blockcell/config.json5"
    if [ -f "$local_cfg" ]; then
        API_TOKEN=$(sed -n 's/.*"apiToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$local_cfg" | head -n1)
    fi
fi

AUTH_ARGS=()
if [ -n "$API_TOKEN" ]; then
    AUTH_ARGS=(-H "Authorization: Bearer ${API_TOKEN}")
fi

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_fail "缺少依赖命令: ${cmd}"
        return 1
    fi
    return 0
}

check_prerequisites() {
    print_info "检查依赖命令..."

    local required=("curl" "python" "grep" "sed" "date")
    local ok=true
    local cmd
    for cmd in "${required[@]}"; do
        if require_command "$cmd"; then
            print_info "  已找到: $cmd"
        else
            ok=false
        fi
    done

    if [ "$ok" = false ]; then
        return 1
    fi

    return 0
}

gateway_reachable() {
    local tries=3
    local i=1
    while [ "$i" -le "$tries" ]; do
        if curl -s -f "${AUTH_ARGS[@]}" "${GATEWAY_URL}/v1/health" >/dev/null 2>&1; then
            return 0
        fi
        if curl -s -f "${AUTH_ARGS[@]}" "${GATEWAY_URL}/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

ensure_param_target_ready() {
    local dir
    dir=$(dirname "$PARAM_FILE")
    mkdir -p "$dir"
    if [ ! -f "$PARAM_FILE" ]; then
        : > "$PARAM_FILE"
    fi
}

stat_mtime() {
    local file="$1"
    stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null
}

iso_to_epoch() {
    local iso="$1"
    python - "$iso" <<'PY'
import datetime
import re
import sys

s = sys.argv[1]
if not re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$', s):
    sys.exit(1)

try:
    dt = datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))
except ValueError:
    sys.exit(1)

print(int(dt.timestamp()))
PY
}

is_iso8601_utc() {
    local iso="$1"
    iso_to_epoch "$iso" >/dev/null 2>&1
}

read_param_field() {
    local file="$1"
    local field="$2"
    python - "$file" "$field" <<'PY'
import json
import sys

path = sys.argv[1]
field = sys.argv[2]

with open(path, 'r', encoding='utf-8-sig') as f:
    data = json.load(f)

value = data.get(field, "")
if value is None:
    value = ""

if isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

trigger_skill_once() {
    local now_ms
    now_ms=$(( $(date +%s) * 1000 + 3000 ))

    local job_name="forex_param_generator_task13_$(date +%s)"
    local payload
    payload=$(cat <<EOF
{
  "name": "${job_name}",
  "message": "Task 13 integration test generate parameter pack",
  "at_ms": ${now_ms},
  "skill_name": "${SKILL_NAME}",
  "delete_after_run": true,
  "deliver": false
}
EOF
)

    local response
    if ! response=$(curl -sS -w "\n%{http_code}" -X POST "${GATEWAY_URL}/v1/cron" \
        "${AUTH_ARGS[@]}" \
        -H "Content-Type: application/json" \
        -d "$payload"); then
        print_fail "调用 Gateway 失败: ${GATEWAY_URL}/v1/cron"
        return 1
    fi

    local http_code body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        print_fail "创建一次性 Cron 任务失败 (HTTP ${http_code})"
        echo "$body"
        return 1
    fi

    print_info "一次性 Cron 任务创建成功，等待执行..."
    return 0
}

wait_for_param_file_update() {
    local previous_mtime="${1:-}"
    local timeout="${2:-30}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        if [ -f "$PARAM_FILE" ]; then
            local current_mtime
            current_mtime=$(stat_mtime "$PARAM_FILE")

            if [ -z "$previous_mtime" ]; then
                return 0
            fi

            if [ -n "$current_mtime" ] && [ "$current_mtime" -gt "$previous_mtime" ]; then
                return 0
            fi
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    return 1
}

assert_parameter_contract() {
    local file="$1"

    if [ ! -f "$file" ]; then
        print_fail "参数文件不存在: $file"
        return 1
    fi

    local validation_output
    if ! validation_output=$(python - "$file" <<'PY'
import datetime
import json
import math
import re
import sys

path = sys.argv[1]

def fail(msg: str):
    print(msg)
    sys.exit(1)

def parse_iso8601_utc(value: str):
    if not isinstance(value, str):
        return None
    if not re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$', value):
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        return None

try:
    with open(path, "r", encoding="utf-8-sig") as f:
        data = json.load(f)
except Exception as e:
    fail(f"JSON 格式无效: {e}")

required_fields = [
    "version", "symbol", "timeframe", "bias", "valid_from", "valid_to",
    "entry_zone", "invalid_above", "tp_levels", "tp_ratios",
    "ema_fast", "ema_trend", "lookback_period", "touch_tolerance",
    "pattern", "risk", "max_spread_points", "max_slippage_points",
]
for field in required_fields:
    if field not in data:
        fail(f"参数缺少必需字段: {field}")

if data["symbol"] != "EURUSD":
    fail(f"symbol 非法: {data['symbol']} (期望 EURUSD)")
if data["timeframe"] != "H4":
    fail(f"timeframe 非法: {data['timeframe']} (期望 H4)")
if data["bias"] != "short_only":
    fail(f"bias 非法: {data['bias']} (期望 short_only)")

version = data["version"]
if not isinstance(version, str) or not re.match(r'^\d{8}-\d{4}$', version):
    fail(f"version 格式非法: {version} (期望 YYYYMMDD-HHMM)")

valid_from = parse_iso8601_utc(data["valid_from"])
valid_to = parse_iso8601_utc(data["valid_to"])
if valid_from is None:
    fail(f"valid_from 非法: {data['valid_from']}")
if valid_to is None:
    fail(f"valid_to 非法: {data['valid_to']}")
if valid_from >= valid_to:
    fail(f"valid_from 必须早于 valid_to: {data['valid_from']} >= {data['valid_to']}")

entry_zone = data["entry_zone"]
if not isinstance(entry_zone, dict):
    fail("entry_zone 必须是对象")
if entry_zone.get("min") is None or entry_zone.get("max") is None:
    fail("entry_zone 缺少 min 或 max")
if entry_zone["min"] >= entry_zone["max"]:
    fail("entry_zone 校验失败: min 必须小于 max")

if data["invalid_above"] <= 0:
    fail("invalid_above 必须大于 0")

if data["ema_fast"] <= 0 or data["ema_trend"] <= 0 or data["lookback_period"] <= 0 or data["touch_tolerance"] <= 0:
    fail("技术指标参数存在非法值（应全部 > 0）")

risk = data["risk"]
if not isinstance(risk, dict):
    fail("risk 必须是对象")
if not (risk.get("per_trade") and risk.get("daily_max_loss") and risk.get("consecutive_loss_limit")):
    fail("risk 字段缺失")
if not (0 < risk["per_trade"] <= 0.1):
    fail("risk.per_trade 超出范围 (0, 0.1]")
if not (0 < risk["daily_max_loss"] <= 0.2):
    fail("risk.daily_max_loss 超出范围 (0, 0.2]")
if risk["consecutive_loss_limit"] <= 0:
    fail("risk.consecutive_loss_limit 必须大于 0")

if data["max_spread_points"] <= 0 or data["max_slippage_points"] <= 0:
    fail("执行参数非法（max_spread_points/max_slippage_points 必须 > 0）")

tp_levels = data["tp_levels"]
tp_ratios = data["tp_ratios"]
if not isinstance(tp_levels, list) or not isinstance(tp_ratios, list):
    fail("tp_levels/tp_ratios 必须是数组")
if len(tp_levels) <= 0 or len(tp_ratios) <= 0:
    fail("tp_levels/tp_ratios 不能为空")
if len(tp_levels) != len(tp_ratios):
    fail(f"tp_levels/tp_ratios 长度非法: tp_levels={len(tp_levels)}, tp_ratios={len(tp_ratios)}")

ratio_sum = float(sum(tp_ratios))
if math.fabs(ratio_sum - 1.0) > 1e-6:
    fail(f"tp_ratios 总和必须为 1.0，当前值: {ratio_sum}")

patterns = data["pattern"]
if not isinstance(patterns, list) or len(patterns) <= 0:
    fail("pattern 数组不能为空")

news_blackout = data.get("news_blackout")
if news_blackout is not None:
    if not isinstance(news_blackout, list):
        fail("news_blackout 必须是数组")
    for i, item in enumerate(news_blackout):
        if not isinstance(item, dict):
            fail(f"news_blackout[{i}] 必须是对象")
        start = item.get("start")
        end = item.get("end")
        if not start or not end:
            fail(f"news_blackout[{i}] 缺少 start 或 end")
        start_dt = parse_iso8601_utc(start)
        end_dt = parse_iso8601_utc(end)
        if start_dt is None or end_dt is None:
            fail(f"news_blackout[{i}] 时间格式非法: start={start}, end={end}")
        if start_dt >= end_dt:
            fail(f"news_blackout[{i}] 时间窗口非法: start >= end")

session_filter = data.get("session_filter")
if session_filter is not None:
    if not isinstance(session_filter, dict):
        fail("session_filter 必须是对象")
    enabled = bool(session_filter.get("enabled", False))
    if enabled:
        allowed = session_filter.get("allowed_hours_utc")
        if not isinstance(allowed, list) or len(allowed) == 0:
            fail("session_filter.enabled=true 但 allowed_hours_utc 为空")
        for hour in allowed:
            if not isinstance(hour, int):
                fail("session_filter.allowed_hours_utc 包含非整数")
            if hour < 0 or hour > 23:
                fail("session_filter.allowed_hours_utc 包含非法小时（必须为 0-23 的整数）")

print("OK")
PY
); then
        print_fail "$validation_output"
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# 测试 1：Blockcell 参数生成
# -----------------------------------------------------------------------------
test_blockcell_param_generation() {
    print_header "测试 1: Blockcell 参数生成"

    if [ ! -f "$SKILL_FILE" ]; then
        print_fail "SKILL 文件不存在: ${SKILL_FILE}"
        return 1
    fi
    print_info "已找到 Skill 文件: ${SKILL_FILE}"

    local before_mtime=""
    ensure_param_target_ready
    if [ -f "$PARAM_FILE" ]; then
        before_mtime=$(stat_mtime "$PARAM_FILE")
    fi

    if [ "$RUN_LIVE_TESTS" = "1" ]; then
        if [ ! -f "$GATEWAY_SKILL_FILE" ]; then
            print_fail "Gateway 侧 skill 未安装: ${GATEWAY_SKILL_FILE}"
            print_fail "请先将 skill 同步到 ~/.blockcell/workspace/skills/${SKILL_NAME}/"
            return 1
        fi

        if ! gateway_reachable; then
            print_fail "无法连接 Gateway: ${GATEWAY_URL}"
            print_fail "请先启动 Blockcell，或设置 RUN_LIVE_TESTS=0 仅做离线契约校验"
            return 1
        fi

        if ! trigger_skill_once; then
            return 1
        fi

        if ! wait_for_param_file_update "$before_mtime" "$TEST_TIMEOUT_SEC"; then
            print_fail "等待参数文件刷新超时 (${TEST_TIMEOUT_SEC}s): ${PARAM_FILE}"
            return 1
        fi
        print_info "检测到参数文件已刷新"
    else
        print_warn "RUN_LIVE_TESTS=0，跳过在线生成触发"
        if [ ! -f "$PARAM_FILE" ]; then
            print_warn "本地参数文件不存在，无法离线校验"
            return 2
        fi
    fi

    if [ ! -f "$PARAM_FILE" ]; then
        print_fail "参数文件不存在: ${PARAM_FILE}"
        return 1
    fi

    if ! assert_parameter_contract "$PARAM_FILE"; then
        return 1
    fi

    print_pass "Blockcell 参数生成验证通过"
    return 0
}

# -----------------------------------------------------------------------------
# 测试 2：EA 参数加载契约（对齐 ParameterLoader）
# -----------------------------------------------------------------------------
test_ea_param_loading_contract() {
    print_header "测试 2: EA 参数加载契约校验"

    if [ ! -f "$EA_FILE" ]; then
        print_fail "EA 文件不存在: ${EA_FILE}"
        return 1
    fi
    if [ ! -f "$LOADER_FILE" ]; then
        print_fail "ParameterLoader 文件不存在: ${LOADER_FILE}"
        return 1
    fi

    local required_functions=(
        "LoadParameterPack"
        "ParseParameterJSON"
        "ValidateParameters"
        "ParseISO8601"
        "ParseNewsBlackout"
        "ParseSessionFilter"
    )

    local func
    for func in "${required_functions[@]}"; do
        if ! grep -q "$func" "$LOADER_FILE"; then
            print_fail "ParameterLoader 缺少函数: ${func}"
            return 1
        fi
    done
    print_info "ParameterLoader 关键函数齐全"

    if ! grep -q "signal_pack.json" "$EA_FILE"; then
        print_fail "EA 未引用 signal_pack.json"
        return 1
    fi

    if ! grep -q "ParamFilePath" "$EA_FILE"; then
        print_fail "EA 缺少 ParamFilePath 输入参数，无法手动指定参数文件路径"
        return 1
    fi
    print_info "EA 路径配置检查通过（支持 ParamFilePath 覆盖默认路径）"

    if [ ! -f "$PARAM_FILE" ]; then
        print_fail "参数文件不存在，无法验证 EA 加载契约: ${PARAM_FILE}"
        return 1
    fi

    if ! assert_parameter_contract "$PARAM_FILE"; then
        return 1
    fi

    print_info "若在 MT4 中运行，请将 EA 输入参数 ParamFilePath 设置为："
    print_info "  ${PARAM_FILE}"
    print_pass "EA 参数加载契约校验通过"
    return 0
}

# -----------------------------------------------------------------------------
# 测试 3：参数刷新机制
# -----------------------------------------------------------------------------
test_param_refresh_mechanism() {
    print_header "测试 3: 参数刷新机制"

    if ! grep -q "ParamCheckInterval" "$EA_FILE"; then
        print_fail "EA 缺少 ParamCheckInterval 配置"
        return 1
    fi
    if ! grep -q "CheckParameterUpdate" "$EA_FILE"; then
        print_fail "EA 缺少 CheckParameterUpdate 调用/实现"
        return 1
    fi
    if ! grep -q "STATE_SAFE_MODE" "$EA_FILE"; then
        print_fail "EA 缺少 STATE_SAFE_MODE 状态"
        return 1
    fi
    if ! grep -q "TryRecoverFromSafeMode" "$EA_FILE"; then
        print_fail "EA 缺少 TryRecoverFromSafeMode 恢复逻辑"
        return 1
    fi
    print_info "EA 刷新状态机静态检查通过"

    if [ "$RUN_LIVE_TESTS" != "1" ]; then
        print_warn "RUN_LIVE_TESTS=0，跳过在线刷新验证"
        return 2
    fi

    if ! gateway_reachable; then
        print_fail "无法连接 Gateway，无法执行在线刷新验证: ${GATEWAY_URL}"
        return 1
    fi

    local baseline_mtime=""
    ensure_param_target_ready
    if [ -f "$PARAM_FILE" ]; then
        baseline_mtime=$(stat_mtime "$PARAM_FILE")
    fi

    print_info "触发第 1 次参数生成..."
    if ! trigger_skill_once; then
        return 1
    fi
    if ! wait_for_param_file_update "$baseline_mtime" "$TEST_TIMEOUT_SEC"; then
        print_fail "第 1 次刷新超时"
        return 1
    fi

    local mtime1 version1 valid_from1
    mtime1=$(stat_mtime "$PARAM_FILE")
    version1=$(read_param_field "$PARAM_FILE" "version")
    valid_from1=$(read_param_field "$PARAM_FILE" "valid_from")

    sleep 2

    print_info "触发第 2 次参数生成..."
    if ! trigger_skill_once; then
        return 1
    fi
    if ! wait_for_param_file_update "$mtime1" "$TEST_TIMEOUT_SEC"; then
        print_fail "第 2 次刷新超时"
        return 1
    fi

    local mtime2 version2 valid_from2
    mtime2=$(stat_mtime "$PARAM_FILE")
    version2=$(read_param_field "$PARAM_FILE" "version")
    valid_from2=$(read_param_field "$PARAM_FILE" "valid_from")

    if [ "$mtime2" -le "$mtime1" ]; then
        print_fail "参数文件 mtime 未前进: mtime1=${mtime1}, mtime2=${mtime2}"
        return 1
    fi

    local t1 t2
    t1=$(iso_to_epoch "$valid_from1")
    t2=$(iso_to_epoch "$valid_from2")
    if [ -z "$t1" ] || [ -z "$t2" ] || [ "$t2" -lt "$t1" ]; then
        print_fail "valid_from 未保持前进或持平: ${valid_from1} -> ${valid_from2}"
        return 1
    fi

    if [ "$version1" = "$version2" ]; then
        print_warn "version 未变化（版本粒度为分钟，短时间重复触发可能相同）: ${version1}"
    else
        print_info "version 已变化: ${version1} -> ${version2}"
    fi

    if ! assert_parameter_contract "$PARAM_FILE"; then
        return 1
    fi

    print_pass "参数刷新机制验证通过"
    return 0
}

run_test() {
    local test_fn="$1"

    echo ""
    "$test_fn"
    local rc=$?

    if [ "$rc" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    elif [ "$rc" -eq 2 ]; then
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

main() {
    echo ""
    print_header "MT4 Forex Strategy Executor - Task 13 集成测试"
    echo "目标：验证参数生成、EA 加载契约、参数刷新三项闭环"
    echo "Gateway: ${GATEWAY_URL}"
    echo "Param file: ${PARAM_FILE}"
    if [ -n "$API_TOKEN" ]; then
        echo "API token: configured"
    else
        echo "API token: not configured"
    fi
    echo "RUN_LIVE_TESTS=${RUN_LIVE_TESTS}, STRICT_MODE=${STRICT_MODE}"

    if ! check_prerequisites; then
        print_fail "依赖检查失败，无法继续"
        exit 1
    fi

    local tests=(
        "test_blockcell_param_generation"
        "test_ea_param_loading_contract"
        "test_param_refresh_mechanism"
    )

    local t
    for t in "${tests[@]}"; do
        run_test "$t"
    done

    echo ""
    print_header "测试结果汇总"
    echo -e "${GREEN}通过: ${TESTS_PASSED}${NC}"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "${RED}失败: ${TESTS_FAILED}${NC}"
    else
        echo -e "${GREEN}失败: ${TESTS_FAILED}${NC}"
    fi
    if [ "$TESTS_SKIPPED" -gt 0 ]; then
        echo -e "${YELLOW}跳过: ${TESTS_SKIPPED}${NC}"
    else
        echo -e "${GREEN}跳过: ${TESTS_SKIPPED}${NC}"
    fi

    if [ "$TESTS_FAILED" -gt 0 ]; then
        print_fail "Task 13 集成测试未通过"
        exit 1
    fi

    if [ "$STRICT_MODE" = "1" ] && [ "$TESTS_SKIPPED" -gt 0 ]; then
        print_fail "存在跳过项且 STRICT_MODE=1，判定为未通过"
        exit 1
    fi

    print_pass "Task 13 集成测试通过"
    exit 0
}

main "$@"
