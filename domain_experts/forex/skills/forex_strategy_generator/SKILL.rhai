// forex_strategy_generator skill — 生成EUR/USD H4空头策略参数包
// 通过AI分析市场并生成完整的策略参数JSON文件

let input = ctx.user_input;

// ============================================================================
// 辅助函数：获取当前UTC时间
// ============================================================================
fn now_utc() {
    // V1实现：要求Blockcell运行在UTC时区环境
    // 部署时必须确保系统时区为UTC或通过TZ=UTC环境变量启动
    return timestamp();
}

// ============================================================================
// 辅助函数：将timestamp转换为ISO 8601格式字符串
// ============================================================================
fn format_iso8601(ts) {
    // 格式：YYYY-MM-DDTHH:MM:SSZ
    // 使用 chrono 库的标准格式化（通过 timestamp() 函数返回的是 Unix 时间戳）
    
    // 计算基本时间组件
    let total_seconds = ts;
    let seconds_in_day = 86400;
    let seconds_in_hour = 3600;
    let seconds_in_minute = 60;
    
    // 计算自 1970-01-01 以来的天数
    let days_since_epoch = total_seconds / seconds_in_day;
    let seconds_today = total_seconds % seconds_in_day;
    
    // 计算时分秒
    let hours = seconds_today / seconds_in_hour;
    let minutes = (seconds_today % seconds_in_hour) / seconds_in_minute;
    let seconds = seconds_today % seconds_in_minute;
    
    // 计算年月日（考虑闰年）
    let year = 1970;
    let remaining_days = days_since_epoch;
    
    // 逐年计算
    loop {
        let days_in_year = if is_leap_year(year) { 366 } else { 365 };
        if remaining_days < days_in_year {
            break;
        }
        remaining_days -= days_in_year;
        year += 1;
    }
    
    // 计算月份和日期
    let days_in_months = if is_leap_year(year) {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    
    let month = 1;
    let day_of_month = remaining_days + 1;
    
    for days_in_month in days_in_months {
        if day_of_month <= days_in_month {
            break;
        }
        day_of_month -= days_in_month;
        month += 1;
    }
    
    // 格式化为字符串
    let year_str = year.to_string();
    let month_str = if month < 10 { "0" + month.to_string() } else { month.to_string() };
    let day_str = if day_of_month < 10 { "0" + day_of_month.to_string() } else { day_of_month.to_string() };
    let hour_str = if hours < 10 { "0" + hours.to_string() } else { hours.to_string() };
    let min_str = if minutes < 10 { "0" + minutes.to_string() } else { minutes.to_string() };
    let sec_str = if seconds < 10 { "0" + seconds.to_string() } else { seconds.to_string() };
    
    return year_str + "-" + month_str + "-" + day_str + "T" + 
           hour_str + ":" + min_str + ":" + sec_str + "Z";
}

// 辅助函数：判断是否为闰年
fn is_leap_year(year) {
    if year % 400 == 0 {
        return true;
    }
    if year % 100 == 0 {
        return false;
    }
    if year % 4 == 0 {
        return true;
    }
    return false;
}

// ============================================================================
// 辅助函数：生成版本号（格式：YYYYMMDD-HHMM）
// ============================================================================
fn generate_version(ts) {
    let total_seconds = ts;
    let seconds_in_day = 86400;
    let seconds_in_hour = 3600;
    let seconds_in_minute = 60;
    
    let days_since_epoch = total_seconds / seconds_in_day;
    let seconds_today = total_seconds % seconds_in_day;
    
    let hours = seconds_today / seconds_in_hour;
    let minutes = (seconds_today % seconds_in_hour) / seconds_in_minute;
    
    // 计算年月日（考虑闰年）
    let year = 1970;
    let remaining_days = days_since_epoch;
    
    loop {
        let days_in_year = if is_leap_year(year) { 366 } else { 365 };
        if remaining_days < days_in_year {
            break;
        }
        remaining_days -= days_in_year;
        year += 1;
    }
    
    let days_in_months = if is_leap_year(year) {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    
    let month = 1;
    let day_of_month = remaining_days + 1;
    
    for days_in_month in days_in_months {
        if day_of_month <= days_in_month {
            break;
        }
        day_of_month -= days_in_month;
        month += 1;
    }
    
    let year_str = year.to_string();
    let month_str = if month < 10 { "0" + month.to_string() } else { month.to_string() };
    let day_str = if day_of_month < 10 { "0" + day_of_month.to_string() } else { day_of_month.to_string() };
    let hour_str = if hours < 10 { "0" + hours.to_string() } else { hours.to_string() };
    let min_str = if minutes < 10 { "0" + minutes.to_string() } else { minutes.to_string() };
    
    return year_str + month_str + day_str + "-" + hour_str + min_str;
}

// ============================================================================
// 主逻辑：生成策略参数包
// ============================================================================

// ============================================================================
// 1. AI技能调用（V1版本：占位符）
// ============================================================================

// V1 实现说明：
// forex_news、forex_analysis、forex_strategy 技能尚未实现
// call_skill 函数在当前 Skill 运行时环境中不可用
// V2 版本将实现完整的 AI 分析功能

let ai_analysis_available = false;
print("[forex_strategy_generator] V1版本：使用默认参数（AI技能待实现）");

// 2. 获取当前UTC时间
let current_time = now_utc();
let valid_from_time = current_time;
let valid_to_time = current_time + 86400; // 24小时后

// 3. 生成版本号
let version = generate_version(current_time);

// 4. 构建参数包
// 如果AI分析可用，使用AI建议的参数；否则使用默认参数
let entry_zone_min = 1.1650;
let entry_zone_max = 1.1700;
let invalid_above = 1.1720;
let tp_levels = [1.1550, 1.1500, 1.1350];
let news_blackout_list = [];
let comment_text = "EUR/USD bearish setup with EMA200 trend filter - Generated by Blockcell AI";

// V1 版本：AI 技能未实现，使用默认参数
// V2 版本将实现 AI 分析并动态生成参数
comment_text += " (default parameters)";
print("[forex_strategy_generator] ⚠️ 使用默认参数");

let param_pack = #{
    version: version,
    symbol: "EURUSD",
    timeframe: "H4",
    bias: "short_only",
    valid_from: format_iso8601(valid_from_time),
    valid_to: format_iso8601(valid_to_time),
    entry_zone: #{
        min: entry_zone_min,
        max: entry_zone_max
    },
    invalid_above: invalid_above,
    tp_levels: tp_levels,
    tp_ratios: [0.3, 0.4, 0.3],
    ema_fast: 50,
    ema_trend: 200,
    lookback_period: 10,
    touch_tolerance: 10,
    pattern: ["bearish_engulfing", "bearish_pin_bar"],
    risk: #{
        per_trade: 0.01,
        daily_max_loss: 0.02,
        consecutive_loss_limit: 3
    },
    max_spread_points: 20,
    max_slippage_points: 10,
    news_blackout: news_blackout_list,
    session_filter: #{
        enabled: true,
        allowed_hours_utc: [8, 9, 10, 11, 12, 13, 14, 15, 16]
    },
    comment: comment_text
};

// 5. 将参数包转换为JSON字符串
// 注意：Rhai没有内置的JSON序列化，我们需要手动构建JSON字符串
let json_str = "{\n";
json_str += "  \"version\": \"" + param_pack.version + "\",\n";
json_str += "  \"symbol\": \"" + param_pack.symbol + "\",\n";
json_str += "  \"timeframe\": \"" + param_pack.timeframe + "\",\n";
json_str += "  \"bias\": \"" + param_pack.bias + "\",\n";
json_str += "  \"valid_from\": \"" + param_pack.valid_from + "\",\n";
json_str += "  \"valid_to\": \"" + param_pack.valid_to + "\",\n";
json_str += "  \"entry_zone\": {\n";
json_str += "    \"min\": " + param_pack.entry_zone.min.to_string() + ",\n";
json_str += "    \"max\": " + param_pack.entry_zone.max.to_string() + "\n";
json_str += "  },\n";
json_str += "  \"invalid_above\": " + param_pack.invalid_above.to_string() + ",\n";
json_str += "  \"tp_levels\": [" + param_pack.tp_levels[0].to_string() + ", " + 
             param_pack.tp_levels[1].to_string() + ", " + 
             param_pack.tp_levels[2].to_string() + "],\n";
json_str += "  \"tp_ratios\": [" + param_pack.tp_ratios[0].to_string() + ", " + 
             param_pack.tp_ratios[1].to_string() + ", " + 
             param_pack.tp_ratios[2].to_string() + "],\n";
json_str += "  \"ema_fast\": " + param_pack.ema_fast.to_string() + ",\n";
json_str += "  \"ema_trend\": " + param_pack.ema_trend.to_string() + ",\n";
json_str += "  \"lookback_period\": " + param_pack.lookback_period.to_string() + ",\n";
json_str += "  \"touch_tolerance\": " + param_pack.touch_tolerance.to_string() + ",\n";
json_str += "  \"pattern\": [\"" + param_pack.pattern[0] + "\", \"" + param_pack.pattern[1] + "\"],\n";
json_str += "  \"risk\": {\n";
json_str += "    \"per_trade\": " + param_pack.risk.per_trade.to_string() + ",\n";
json_str += "    \"daily_max_loss\": " + param_pack.risk.daily_max_loss.to_string() + ",\n";
json_str += "    \"consecutive_loss_limit\": " + param_pack.risk.consecutive_loss_limit.to_string() + "\n";
json_str += "  },\n";
json_str += "  \"max_spread_points\": " + param_pack.max_spread_points.to_string() + ",\n";
json_str += "  \"max_slippage_points\": " + param_pack.max_slippage_points.to_string() + ",\n";
json_str += "  \"news_blackout\": [],\n";
json_str += "  \"session_filter\": {\n";
json_str += "    \"enabled\": true,\n";
json_str += "    \"allowed_hours_utc\": [8, 9, 10, 11, 12, 13, 14, 15, 16]\n";
json_str += "  },\n";
json_str += "  \"comment\": \"" + param_pack.comment + "\"\n";
json_str += "}\n";

// 5. 保存到文件
// 使用 write_file 工具保存 JSON 文件
let save_result = write_file("domain_experts/forex/ea/signal_pack.json", json_str);

if is_error(save_result) {
    return #{
        success: false,
        error: "无法保存参数包文件: " + save_result.to_string(),
        instruction: "告知用户参数包生成失败，无法写入文件。请检查文件权限和路径。"
    };
}

// 6. 返回成功结果
let instruction = "✅ 策略参数包生成成功！\n\n";
instruction += "📋 参数包信息\n";
instruction += "══════════════════════════════\n";
instruction += "版本号: " + param_pack.version + "\n";
instruction += "交易品种: " + param_pack.symbol + "\n";
instruction += "时间周期: " + param_pack.timeframe + "\n";
instruction += "交易方向: " + param_pack.bias + "\n";
instruction += "有效期: " + param_pack.valid_from + " ~ " + param_pack.valid_to + "\n";
instruction += "入场区间: " + param_pack.entry_zone.min.to_string() + " - " + param_pack.entry_zone.max.to_string() + "\n";
instruction += "失效价格: " + param_pack.invalid_above.to_string() + "\n";
instruction += "止盈价格: " + param_pack.tp_levels[0].to_string() + ", " + 
               param_pack.tp_levels[1].to_string() + ", " + 
               param_pack.tp_levels[2].to_string() + "\n";
instruction += "止盈比例: " + param_pack.tp_ratios[0].to_string() + ", " + 
               param_pack.tp_ratios[1].to_string() + ", " + 
               param_pack.tp_ratios[2].to_string() + "\n\n";
instruction += "💾 文件已保存至: domain_experts/forex/ea/signal_pack.json\n\n";
instruction += "⚠️ 注意事项：\n";
instruction += "1. 当前参数包使用默认值，建议根据实际市场情况调整\n";
instruction += "2. 确保MT4 EA已配置正确的参数文件路径\n";
instruction += "3. EA将在下次检查周期自动加载新参数\n";
instruction += "4. 建议在重大新闻事件前配置news_blackout时间窗口\n\n";
instruction += "📊 下一步操作：\n";
instruction += "- 在MT4中启动EA，EA将自动读取此参数包\n";
instruction += "- 可以手动编辑signal_pack.json调整参数\n";
instruction += "- 建议先在Dry Run模式下测试策略逻辑\n";

return #{
    success: true,
    version: param_pack.version,
    file_path: "domain_experts/forex/ea/signal_pack.json",
    param_pack: param_pack,
    instruction: instruction
};
