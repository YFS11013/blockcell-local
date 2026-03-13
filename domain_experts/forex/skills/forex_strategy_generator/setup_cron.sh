#!/bin/bash
# Forex Strategy Generator - Cron 任务快速配置脚本
# 
# 使用方法：
#   ./setup_cron.sh [daily|hourly|test]
#
# 参数：
#   daily  - 配置每天 UTC 06:00 执行（默认）
#   hourly - 配置每小时执行（测试用）
#   test   - 立即执行一次测试

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Blockcell Gateway API 地址
GATEWAY_URL="${BLOCKCELL_GATEWAY_URL:-http://localhost:18790}"

# 打印带颜色的消息
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 Blockcell Gateway 是否运行
check_gateway() {
    print_info "检查 Blockcell Gateway 连接..."
    if ! curl -s -f "${GATEWAY_URL}/health" > /dev/null 2>&1; then
        print_error "无法连接到 Blockcell Gateway: ${GATEWAY_URL}"
        print_error "请确保 Blockcell 正在运行，或设置 BLOCKCELL_GATEWAY_URL 环境变量"
        exit 1
    fi
    print_info "✓ Blockcell Gateway 连接正常"
}

# 检查时区配置
check_timezone() {
    print_info "检查时区配置..."
    current_tz=$(date +%Z)
    if [ "$current_tz" != "UTC" ]; then
        print_warn "当前时区不是 UTC: $current_tz"
        print_warn "建议设置 TZ=UTC 环境变量"
        print_warn "或使用 'export TZ=UTC' 命令"
    else
        print_info "✓ 时区配置正确: UTC"
    fi
}

# 创建每日任务
create_daily_cron() {
    print_info "创建每日 Cron 任务（UTC 06:00）..."
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${GATEWAY_URL}/v1/cron" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "forex_param_generator_daily",
            "message": "生成外汇策略参数包",
            "cron_expr": "0 0 6 * * *",
            "skill_name": "forex_strategy_generator",
            "deliver": false
        }')
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        print_info "✓ 每日 Cron 任务创建成功"
        echo "$body" | jq '.' 2>/dev/null || echo "$body"
    else
        print_error "创建 Cron 任务失败 (HTTP $http_code)"
        echo "$body"
        exit 1
    fi
}

# 创建每小时任务（测试用）
create_hourly_cron() {
    print_info "创建每小时 Cron 任务（测试用）..."
    
    response=$(curl -s -w "\n%{http_code}" -X POST "${GATEWAY_URL}/v1/cron" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "forex_param_generator_hourly_test",
            "message": "生成外汇策略参数包（测试）",
            "cron_expr": "0 0 * * * *",
            "skill_name": "forex_strategy_generator",
            "deliver": false
        }')
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        print_info "✓ 每小时 Cron 任务创建成功"
        print_warn "注意：这是测试任务，请在测试完成后删除"
        echo "$body" | jq '.' 2>/dev/null || echo "$body"
    else
        print_error "创建 Cron 任务失败 (HTTP $http_code)"
        echo "$body"
        exit 1
    fi
}

# 立即执行一次测试
run_test() {
    print_info "立即执行 forex_strategy_generator 技能..."
    
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
        
        # 检查文件是否生成
        if [ -f "domain_experts/forex/ea/signal_pack.json" ]; then
            print_info "✓ 参数包文件已生成"
            print_info "文件路径: domain_experts/forex/ea/signal_pack.json"
            
            # 验证 JSON 格式
            if command -v jq > /dev/null 2>&1; then
                if jq . domain_experts/forex/ea/signal_pack.json > /dev/null 2>&1; then
                    print_info "✓ JSON 格式验证通过"
                else
                    print_error "JSON 格式验证失败"
                fi
            fi
        else
            print_warn "参数包文件未找到，请检查技能执行日志"
        fi
    else
        print_error "创建测试任务失败 (HTTP $http_code)"
        echo "$body"
        exit 1
    fi
}

# 列出所有 Cron 任务
list_crons() {
    print_info "当前 Cron 任务列表："
    curl -s "${GATEWAY_URL}/v1/cron" | jq '.' 2>/dev/null || echo "无法获取 Cron 任务列表"
}

# 主函数
main() {
    local mode="${1:-daily}"
    
    echo "=========================================="
    echo "Forex Strategy Generator - Cron 配置工具"
    echo "=========================================="
    echo ""
    
    # 检查依赖
    check_gateway
    check_timezone
    echo ""
    
    # 根据模式执行
    case "$mode" in
        daily)
            create_daily_cron
            ;;
        hourly)
            create_hourly_cron
            ;;
        test)
            run_test
            ;;
        list)
            list_crons
            ;;
        *)
            print_error "未知模式: $mode"
            echo "使用方法: $0 [daily|hourly|test|list]"
            exit 1
            ;;
    esac
    
    echo ""
    print_info "配置完成！"
    echo ""
    echo "下一步操作："
    echo "  1. 查看 Cron 任务: curl ${GATEWAY_URL}/v1/cron"
    echo "  2. 查看参数包: cat domain_experts/forex/ea/signal_pack.json"
    echo "  3. 查看详细文档: cat domain_experts/forex/skills/forex_strategy_generator/CRON_SETUP.md"
    echo ""
    echo "注意：手动触发需要使用任务的 UUID，可通过步骤 1 获取"
    echo ""
}

# 执行主函数
main "$@"
