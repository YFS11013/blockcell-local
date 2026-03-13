#!/bin/bash
# Forex Strategy Generator - 测试示例脚本
# 
# 此脚本演示如何测试 forex_strategy_generator Skill

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Blockcell Gateway API 地址
GATEWAY_URL="${BLOCKCELL_GATEWAY_URL:-http://localhost:18790}"

# 测试 1：检查 Blockcell Gateway 连接
test_gateway_connection() {
    print_header "测试 1：检查 Blockcell Gateway 连接"
    
    if curl -s -f "${GATEWAY_URL}/health" > /dev/null 2>&1; then
        print_info "✓ Blockcell Gateway 连接正常"
        return 0
    else
        print_error "✗ 无法连接到 Blockcell Gateway: ${GATEWAY_URL}"
        return 1
    fi
}

# 测试 2：检查时区配置
test_timezone() {
    print_header "测试 2：检查时区配置"
    
    current_tz=$(date +%Z)
    print_info "当前时区: $current_tz"
    
    if [ "$current_tz" = "UTC" ]; then
        print_info "✓ 时区配置正确"
        return 0
    else
        print_warn "✗ 时区不是 UTC，建议设置 TZ=UTC"
        return 1
    fi
}

# 测试 3：手动触发 Skill
test_skill_execution() {
    print_header "测试 3：手动触发 Skill"
    
    print_info "正在执行 forex_strategy_generator Skill..."
    
    # 注意：Gateway 不支持直接调用 Skill 的 API
    # 我们需要创建一个一次性的 Cron 任务来执行
    
    # 计算当前时间 + 5秒（给任务创建留出时间）
    now_ms=$(($(date +%s) * 1000 + 5000))
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${GATEWAY_URL}/v1/cron" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"forex_param_generator_test_$(date +%s)\",
            \"message\": \"测试生成外汇策略参数包\",
            \"at_ms\": $now_ms,
            \"skill_name\": \"forex_strategy_generator\",
            \"delete_after_run\": true,
            \"deliver\": false
        }")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        print_info "✓ 测试任务已创建，将在5秒后执行"
        echo "$body" | jq '.' 2>/dev/null || echo "$body"
        
        print_info "等待任务执行..."
        sleep 10
        
        return 0
    else
        print_error "✗ 创建测试任务失败 (HTTP $http_code)"
        echo "$body"
        return 1
    fi
}

# 测试 4：验证参数包文件
test_param_pack_file() {
    print_header "测试 4：验证参数包文件"
    
    file_path="domain_experts/forex/ea/signal_pack.json"
    
    # 检查文件是否存在
    if [ ! -f "$file_path" ]; then
        print_error "✗ 参数包文件不存在: $file_path"
        return 1
    fi
    print_info "✓ 参数包文件存在"
    
    # 检查文件大小
    file_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    print_info "文件大小: $file_size bytes"
    
    if [ "$file_size" -lt 100 ]; then
        print_error "✗ 文件大小异常（小于100字节）"
        return 1
    fi
    print_info "✓ 文件大小正常"
    
    # 验证 JSON 格式
    if command -v jq > /dev/null 2>&1; then
        if jq . "$file_path" > /dev/null 2>&1; then
            print_info "✓ JSON 格式验证通过"
        else
            print_error "✗ JSON 格式验证失败"
            return 1
        fi
    else
        print_warn "⚠ jq 未安装，跳过 JSON 格式验证"
    fi
    
    return 0
}

# 测试 5：验证参数包内容
test_param_pack_content() {
    print_header "测试 5：验证参数包内容"
    
    file_path="domain_experts/forex/ea/signal_pack.json"
    
    if [ ! -f "$file_path" ]; then
        print_error "✗ 参数包文件不存在"
        return 1
    fi
    
    if ! command -v jq > /dev/null 2>&1; then
        print_warn "⚠ jq 未安装，跳过内容验证"
        return 0
    fi
    
    # 验证必需字段
    required_fields=(
        "version"
        "symbol"
        "timeframe"
        "bias"
        "valid_from"
        "valid_to"
        "entry_zone"
        "invalid_above"
        "tp_levels"
        "tp_ratios"
        "ema_fast"
        "ema_trend"
        "lookback_period"
        "touch_tolerance"
        "pattern"
        "risk"
        "max_spread_points"
        "max_slippage_points"
        "news_blackout"
        "session_filter"
        "comment"
    )
    
    all_fields_present=true
    for field in "${required_fields[@]}"; do
        if jq -e ".$field" "$file_path" > /dev/null 2>&1; then
            print_info "✓ 字段存在: $field"
        else
            print_error "✗ 字段缺失: $field"
            all_fields_present=false
        fi
    done
    
    if [ "$all_fields_present" = true ]; then
        print_info "✓ 所有必需字段都存在"
        return 0
    else
        print_error "✗ 部分必需字段缺失"
        return 1
    fi
}

# 测试 6：验证固定值
test_fixed_values() {
    print_header "测试 6：验证固定值"
    
    file_path="domain_experts/forex/ea/signal_pack.json"
    
    if [ ! -f "$file_path" ]; then
        print_error "✗ 参数包文件不存在"
        return 1
    fi
    
    if ! command -v jq > /dev/null 2>&1; then
        print_warn "⚠ jq 未安装，跳过固定值验证"
        return 0
    fi
    
    # 验证 symbol
    symbol=$(jq -r '.symbol' "$file_path")
    if [ "$symbol" = "EURUSD" ]; then
        print_info "✓ symbol = EURUSD"
    else
        print_error "✗ symbol = $symbol (期望: EURUSD)"
        return 1
    fi
    
    # 验证 timeframe
    timeframe=$(jq -r '.timeframe' "$file_path")
    if [ "$timeframe" = "H4" ]; then
        print_info "✓ timeframe = H4"
    else
        print_error "✗ timeframe = $timeframe (期望: H4)"
        return 1
    fi
    
    # 验证 bias
    bias=$(jq -r '.bias' "$file_path")
    if [ "$bias" = "short_only" ]; then
        print_info "✓ bias = short_only"
    else
        print_error "✗ bias = $bias (期望: short_only)"
        return 1
    fi
    
    print_info "✓ 所有固定值验证通过"
    return 0
}

# 测试 7：显示参数包内容
test_display_content() {
    print_header "测试 7：显示参数包内容"
    
    file_path="domain_experts/forex/ea/signal_pack.json"
    
    if [ ! -f "$file_path" ]; then
        print_error "✗ 参数包文件不存在"
        return 1
    fi
    
    if command -v jq > /dev/null 2>&1; then
        jq '.' "$file_path"
    else
        cat "$file_path"
    fi
    
    return 0
}

# 主函数
main() {
    echo ""
    print_header "Forex Strategy Generator - 测试套件"
    echo ""
    
    # 运行所有测试
    tests=(
        "test_gateway_connection"
        "test_timezone"
        "test_skill_execution"
        "test_param_pack_file"
        "test_param_pack_content"
        "test_fixed_values"
        "test_display_content"
    )
    
    passed=0
    failed=0
    
    for test in "${tests[@]}"; do
        echo ""
        if $test; then
            ((passed++))
        else
            ((failed++))
        fi
    done
    
    # 显示测试结果
    echo ""
    print_header "测试结果"
    echo ""
    print_info "通过: $passed"
    if [ $failed -gt 0 ]; then
        print_error "失败: $failed"
    else
        print_info "失败: $failed"
    fi
    echo ""
    
    if [ $failed -eq 0 ]; then
        print_info "✓ 所有测试通过！"
        exit 0
    else
        print_error "✗ 部分测试失败"
        exit 1
    fi
}

# 执行主函数
main
