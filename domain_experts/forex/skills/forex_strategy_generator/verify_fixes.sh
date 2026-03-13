#!/bin/bash
# Forex Strategy Generator - 静态审查修复验证脚本
# 
# 此脚本验证所有 5 个静态审查问题是否已修复

# 不使用 set -e，因为我们需要继续运行所有测试

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_pass() {
    echo -e "${GREEN}✓ PASS${NC} $1"
}

print_fail() {
    echo -e "${RED}✗ FAIL${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

# 验证 1：检查 SKILL.rhai 中是否移除了 call_skill
verify_no_call_skill() {
    print_header "验证 1：检查是否移除了 call_skill"
    
    # 检查是否存在实际的 call_skill 函数调用（不包括注释）
    if grep -v "^[[:space:]]*\/\/" SKILL.rhai | grep -q "call_skill("; then
        print_fail "SKILL.rhai 中仍然存在 call_skill 调用"
        return 1
    else
        print_pass "SKILL.rhai 中已移除所有 call_skill 调用"
        
        # 检查是否有说明注释
        if grep -q "call_skill 函数在当前 Skill 运行时环境中不可用" SKILL.rhai; then
            print_info "已添加 V1 限制说明注释"
        fi
        return 0
    fi
}

# 验证 2：检查 SKILL.rhai 中是否使用了 write_file
verify_write_file() {
    print_header "验证 2：检查是否使用了 write_file"
    
    if grep -q "write_file" SKILL.rhai; then
        print_pass "SKILL.rhai 中使用了 write_file 函数"
        
        # 确保没有使用 file_ops write
        if grep -q 'action.*:.*"write"' SKILL.rhai; then
            print_fail "SKILL.rhai 中仍然存在 file_ops write 调用"
            return 1
        else
            print_pass "SKILL.rhai 中已移除 file_ops write 调用"
            return 0
        fi
    else
        print_fail "SKILL.rhai 中未找到 write_file 函数"
        return 1
    fi
}

# 验证 3：检查 setup_cron.sh 中的 API 格式
verify_cron_api() {
    print_header "验证 3：检查 Cron API 格式"
    
    # 检查是否使用了正确的字段
    if grep -q '"name":' setup_cron.sh && \
       grep -q '"message":' setup_cron.sh && \
       grep -q '"cron_expr":' setup_cron.sh && \
       grep -q '"skill_name":' setup_cron.sh; then
        print_pass "setup_cron.sh 使用了正确的 API 字段"
        
        # 检查是否移除了错误的字段
        if grep -q '"id":' setup_cron.sh || \
           grep -q '"schedule":' setup_cron.sh || \
           grep -q '"action":' setup_cron.sh; then
            print_fail "setup_cron.sh 中仍然存在错误的 API 字段"
            return 1
        else
            print_pass "setup_cron.sh 中已移除错误的 API 字段"
            return 0
        fi
    else
        print_fail "setup_cron.sh 中缺少必需的 API 字段"
        return 1
    fi
}

# 验证 4：检查手动触发机制
verify_manual_trigger() {
    print_header "验证 4：检查手动触发机制"
    
    # 检查 setup_cron.sh 是否使用了一次性 Cron 任务
    if grep -q "at_ms" setup_cron.sh && \
       grep -q "delete_after_run" setup_cron.sh; then
        print_pass "setup_cron.sh 使用了一次性 Cron 任务机制"
    else
        print_fail "setup_cron.sh 未使用一次性 Cron 任务机制"
        return 1
    fi
    
    # 检查 test_example.sh 是否也使用了相同机制
    if grep -q "at_ms" test_example.sh && \
       grep -q "delete_after_run" test_example.sh; then
        print_pass "test_example.sh 使用了一次性 Cron 任务机制"
        return 0
    else
        print_fail "test_example.sh 未使用一次性 Cron 任务机制"
        return 1
    fi
}

# 验证 5：检查时间格式化算法
verify_time_formatting() {
    print_header "验证 5：检查时间格式化算法"
    
    # 检查是否实现了闰年判断
    if grep -q "is_leap_year" SKILL.rhai; then
        print_pass "SKILL.rhai 中实现了 is_leap_year 函数"
    else
        print_fail "SKILL.rhai 中未找到 is_leap_year 函数"
        return 1
    fi
    
    # 检查是否使用了实际的每月天数
    if grep -q "\[31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31\]" SKILL.rhai && \
       grep -q "\[31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31\]" SKILL.rhai; then
        print_pass "SKILL.rhai 中使用了实际的每月天数数组"
        return 0
    else
        print_fail "SKILL.rhai 中未找到正确的每月天数数组"
        return 1
    fi
}

# 主函数
main() {
    echo ""
    print_header "Forex Strategy Generator - 静态审查修复验证"
    echo ""
    
    passed=0
    failed=0
    
    tests=(
        "verify_no_call_skill"
        "verify_write_file"
        "verify_cron_api"
        "verify_manual_trigger"
        "verify_time_formatting"
    )
    
    for test in "${tests[@]}"; do
        echo ""
        if $test; then
            ((passed++))
        else
            ((failed++))
        fi
    done
    
    echo ""
    print_header "验证结果"
    echo ""
    echo -e "${GREEN}通过：$passed${NC}"
    if [ $failed -gt 0 ]; then
        echo -e "${RED}失败：$failed${NC}"
    else
        echo -e "${GREEN}失败：$failed${NC}"
    fi
    echo ""
    
    if [ $failed -eq 0 ]; then
        echo -e "${GREEN}✓ 所有静态审查问题已修复！${NC}"
        exit 0
    else
        echo -e "${RED}✗ 部分问题仍未修复${NC}"
        exit 1
    fi
}

main
