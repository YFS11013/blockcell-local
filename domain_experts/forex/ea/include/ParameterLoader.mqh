//+------------------------------------------------------------------+
//|                                            ParameterLoader.mqh   |
//|                        MT4 Forex Strategy Executor - Param Loader|
//|                                                                  |
//| 描述：参数加载器模块                                              |
//| 功能：                                                            |
//|   - 从 JSON 文件读取策略参数                                     |
//|   - 校验参数完整性和有效性                                        |
//|   - 管理参数生命周期和优先级                                      |
//|   - 处理参数备份和恢复                                           |
//+------------------------------------------------------------------+
#property copyright "MT4 Forex Strategy Executor"
#property strict

#ifndef PARAMETER_LOADER_MQH
#define PARAMETER_LOADER_MQH

#include "Logger.mqh"

//+------------------------------------------------------------------+
//| 数据结构定义                                                      |
//+------------------------------------------------------------------+

// 新闻禁开仓窗口
struct NewsBlackout {
    datetime start;      // 窗口开始时间（UTC）
    datetime end;        // 窗口结束时间（UTC）
    string reason;       // 事件原因说明
};

// 交易时段过滤
struct SessionFilter {
    bool enabled;                // 是否启用时段过滤
    int allowed_hours_utc[24];   // 允许交易的 UTC 小时数组
    int allowed_count;           // 允许小时的数量
};

// 参数包结构
struct ParameterPack {
    // 基本信息
    string version;              // 参数包版本号
    string symbol;               // 交易品种
    string timeframe;            // 时间周期
    string bias;                 // 交易方向
    datetime valid_from;         // 参数生效时间（UTC）
    datetime valid_to;           // 参数过期时间（UTC）
    
    // 入场参数
    double entry_zone_min;       // 入场区间下限
    double entry_zone_max;       // 入场区间上限
    double invalid_above;        // 失效价格
    
    // 止盈参数
    double tp_levels[10];        // 止盈价格数组
    double tp_ratios[10];        // 止盈手数比例数组
    int tp_count;                // 止盈级别数量
    
    // 技术指标参数
    int ema_fast;                // 快速 EMA 周期
    int ema_trend;               // 趋势 EMA 周期
    int lookback_period;         // 回看周期
    double touch_tolerance;      // 回踩容差（点数）
    
    // 形态参数
    string patterns[10];         // 允许的形态类型数组
    int pattern_count;           // 形态类型数量
    
    // 风险管理参数
    double risk_per_trade;       // 单笔风险百分比
    double risk_daily_max_loss;  // 单日最大亏损百分比
    int risk_consecutive_loss_limit;  // 连续亏损笔数限制
    
    // 执行参数
    double max_spread_points;    // 最大允许点差
    double max_slippage_points;  // 最大允许滑点
    
    // 可选参数
    NewsBlackout news_blackouts[20];  // 新闻禁开仓窗口数组
    int blackout_count;          // 新闻窗口数量
    SessionFilter session_filter;     // 交易时段过滤
    string comment;              // 备注信息
    
    // 内部状态
    bool is_valid;               // 参数是否有效
    string error_message;        // 错误信息
};

//+------------------------------------------------------------------+
//| 全局变量                                                          |
//+------------------------------------------------------------------+
ParameterPack g_CurrentParams;   // 当前参数包
ParameterPack g_BackupParams;    // 备份参数包
bool g_HasBackup = false;        // 是否有备份参数

//+------------------------------------------------------------------+
//| 初始化参数包结构                                                  |
//+------------------------------------------------------------------+
void InitParameterPack(ParameterPack &params)
{
    params.version = "";
    params.symbol = "";
    params.timeframe = "";
    params.bias = "";
    params.valid_from = 0;
    params.valid_to = 0;
    
    params.entry_zone_min = 0;
    params.entry_zone_max = 0;
    params.invalid_above = 0;
    
    params.tp_count = 0;
    params.ema_fast = 0;
    params.ema_trend = 0;
    params.lookback_period = 0;
    params.touch_tolerance = 0;
    
    params.pattern_count = 0;
    
    params.risk_per_trade = 0;
    params.risk_daily_max_loss = 0;
    params.risk_consecutive_loss_limit = 0;
    
    params.max_spread_points = 0;
    params.max_slippage_points = 0;
    
    params.blackout_count = 0;
    params.session_filter.enabled = false;
    params.session_filter.allowed_count = 0;
    params.comment = "";
    
    params.is_valid = false;
    params.error_message = "";
}

//+------------------------------------------------------------------+
//| JSON 辅助函数                                                     |
//+------------------------------------------------------------------+

// 从 JSON 字符串中提取字符串值
string ExtractJSONString(string json, string key)
{
    string search_key = "\"" + key + "\"";
    int pos = StringFind(json, search_key);
    if(pos < 0) return "";
    
    // 找到冒号后的引号
    pos = StringFind(json, ":", pos);
    if(pos < 0) return "";
    
    pos = StringFind(json, "\"", pos);
    if(pos < 0) return "";
    
    int start = pos + 1;
    int end = StringFind(json, "\"", start);
    if(end < 0) return "";
    
    return StringSubstr(json, start, end - start);
}

// 从 JSON 字符串中提取数值
double ExtractJSONNumber(string json, string key)
{
    string search_key = "\"" + key + "\"";
    int pos = StringFind(json, search_key);
    if(pos < 0) return 0;
    
    // 找到冒号
    pos = StringFind(json, ":", pos);
    if(pos < 0) return 0;
    
    // 跳过空格
    pos++;
    while(pos < StringLen(json) && StringGetCharacter(json, pos) == ' ') pos++;
    
    // 提取数字
    string num_str = "";
    while(pos < StringLen(json)) {
        ushort ch = StringGetCharacter(json, pos);
        if((ch >= '0' && ch <= '9') || ch == '.' || ch == '-' || ch == 'e' || ch == 'E' || ch == '+') {
            num_str += CharToString((uchar)ch);
            pos++;
        } else {
            break;
        }
    }
    
    return StringToDouble(num_str);
}

// 从 JSON 字符串中提取布尔值
bool ExtractJSONBool(string json, string key)
{
    string search_key = "\"" + key + "\"";
    int pos = StringFind(json, search_key);
    if(pos < 0) return false;
    
    // 找到冒号
    pos = StringFind(json, ":", pos);
    if(pos < 0) return false;
    
    // 查找 true 或 false
    int true_pos = StringFind(json, "true", pos);
    int false_pos = StringFind(json, "false", pos);
    
    if(true_pos > pos && (false_pos < 0 || true_pos < false_pos)) {
        return true;
    }
    
    return false;
}

// 提取路径中的文件名
string ExtractFileNameFromPath(string full_path)
{
    string normalized = full_path;
    StringReplace(normalized, "\\", "/");
    
    string parts[];
    int count = StringSplit(normalized, '/', parts);
    if(count > 0) {
        return parts[count - 1];
    }
    
    return full_path;
}

// 将参数文件路径转换为 MT4 文件沙箱可用路径
string ResolveSandboxFilePath(string file_path)
{
    if(StringLen(file_path) == 0) {
        return "signal_pack.json";
    }
    
    if(StringFind(file_path, "\\") >= 0 || StringFind(file_path, "/") >= 0 || StringFind(file_path, ":") >= 0) {
        string file_name = ExtractFileNameFromPath(file_path);
        if(StringLen(file_name) > 0) {
            return file_name;
        }
    }
    
    return file_path;
}

//+------------------------------------------------------------------+
//| 从文件加载参数包                                                  |
//| 参数：                                                            |
//|   filePath - 参数包文件路径                                      |
//| 返回：                                                            |
//|   true - 加载成功，false - 加载失败                              |
//| 说明：                                                            |
//|   加载失败时不会修改 g_CurrentParams，保持当前参数不变            |
//+------------------------------------------------------------------+
bool LoadParameterPack(string filePath)
{
    LogInfo("ParamLoader", "开始加载参数包 - " + filePath);
    
    // 使用临时参数包，避免加载失败时清空当前参数
    ParameterPack temp_params;
    InitParameterPack(temp_params);
    
    // 打开文件（优先使用传入路径）
    string open_path = filePath;
    int file_handle = FileOpen(open_path, FILE_READ|FILE_TXT);
    
    // 若失败，且传入的是绝对路径或包含目录，则回退到文件沙箱相对路径再试一次
    if(file_handle == INVALID_HANDLE) {
        string sandbox_path = ResolveSandboxFilePath(filePath);
        if(sandbox_path != open_path) {
            file_handle = FileOpen(sandbox_path, FILE_READ|FILE_TXT);
            if(file_handle != INVALID_HANDLE) {
                LogWarn("ParamLoader", "绝对/目录路径打开失败，回退文件沙箱路径成功: " + sandbox_path);
                open_path = sandbox_path;
            }
        }
    }
    
    if(file_handle == INVALID_HANDLE) {
        string error_msg = "无法打开参数文件: " + filePath + ", 错误码: " + IntegerToString(GetLastError());
        LogError("ParamLoader", error_msg);
        LogParameterLoad("", "FAILED", error_msg);
        return false;
    }
    
    // 读取文件内容
    string json_content = "";
    while(!FileIsEnding(file_handle)) {
        json_content += FileReadString(file_handle);
    }
    FileClose(file_handle);
    
    if(StringLen(json_content) == 0) {
        LogError("ParamLoader", "参数文件为空");
        LogParameterLoad("", "FAILED", "参数文件为空");
        return false;
    }
    
    LogDebug("ParamLoader", "文件读取成功，长度: " + IntegerToString(StringLen(json_content)));
    
    // 解析 JSON 内容到临时参数包
    if(!ParseParameterJSON(json_content, temp_params)) {
        LogError("ParamLoader", "JSON 解析失败: " + temp_params.error_message);
        LogParameterLoad("", "FAILED", "JSON 解析失败: " + temp_params.error_message);
        return false;
    }
    
    // 校验临时参数包
    if(!ValidateParameters(temp_params)) {
        LogError("ParamLoader", "参数校验失败: " + temp_params.error_message);
        LogParameterLoad(temp_params.version, "FAILED", "参数校验失败: " + temp_params.error_message);
        return false;
    }
    
    // 校验通过，更新全局参数
    g_CurrentParams = temp_params;
    g_CurrentParams.is_valid = true;
    
    LogInfo("ParamLoader", "参数加载成功");
    LogInfo("ParamLoader", "  版本: " + g_CurrentParams.version);
    LogInfo("ParamLoader", "  品种: " + g_CurrentParams.symbol);
    LogInfo("ParamLoader", "  周期: " + g_CurrentParams.timeframe);
    LogInfo("ParamLoader", "  方向: " + g_CurrentParams.bias);
    LogInfo("ParamLoader", "  有效期: " + TimeToString(g_CurrentParams.valid_from) + " - " + TimeToString(g_CurrentParams.valid_to));
    
    // 记录参数加载成功
    LogParameterLoad(g_CurrentParams.version, "SUCCESS", "参数加载成功");
    
    return true;
}

//+------------------------------------------------------------------+
//| 解析 JSON 内容到参数包                                            |
//+------------------------------------------------------------------+
bool ParseParameterJSON(string json, ParameterPack &params)
{
    LogDebug("ParamLoader", "开始解析 JSON");
    
    // 解析基本字段
    params.version = ExtractJSONString(json, "version");
    params.symbol = ExtractJSONString(json, "symbol");
    params.timeframe = ExtractJSONString(json, "timeframe");
    params.bias = ExtractJSONString(json, "bias");
    
    // 解析时间字段
    string valid_from_str = ExtractJSONString(json, "valid_from");
    string valid_to_str = ExtractJSONString(json, "valid_to");
    
    params.valid_from = ParseISO8601(valid_from_str);
    params.valid_to = ParseISO8601(valid_to_str);
    
    // 解析入场参数
    // 注意：entry_zone 是嵌套对象，需要特殊处理
    int entry_zone_pos = StringFind(json, "\"entry_zone\"");
    if(entry_zone_pos >= 0) {
        int brace_start = StringFind(json, "{", entry_zone_pos);
        int brace_end = StringFind(json, "}", brace_start);
        if(brace_start >= 0 && brace_end > brace_start) {
            string entry_zone_json = StringSubstr(json, brace_start, brace_end - brace_start + 1);
            params.entry_zone_min = ExtractJSONNumber(entry_zone_json, "min");
            params.entry_zone_max = ExtractJSONNumber(entry_zone_json, "max");
        }
    }
    
    params.invalid_above = ExtractJSONNumber(json, "invalid_above");
    
    // 解析技术指标参数
    params.ema_fast = (int)ExtractJSONNumber(json, "ema_fast");
    params.ema_trend = (int)ExtractJSONNumber(json, "ema_trend");
    params.lookback_period = (int)ExtractJSONNumber(json, "lookback_period");
    params.touch_tolerance = ExtractJSONNumber(json, "touch_tolerance");
    
    // 解析风险参数（嵌套在 risk 对象中）
    int risk_pos = StringFind(json, "\"risk\"");
    if(risk_pos >= 0) {
        int risk_brace_start = StringFind(json, "{", risk_pos);
        int risk_brace_end = StringFind(json, "}", risk_brace_start);
        if(risk_brace_start >= 0 && risk_brace_end > risk_brace_start) {
            string risk_json = StringSubstr(json, risk_brace_start, risk_brace_end - risk_brace_start + 1);
            params.risk_per_trade = ExtractJSONNumber(risk_json, "per_trade");
            params.risk_daily_max_loss = ExtractJSONNumber(risk_json, "daily_max_loss");
            params.risk_consecutive_loss_limit = (int)ExtractJSONNumber(risk_json, "consecutive_loss_limit");
        }
    }
    
    // 解析执行参数
    params.max_spread_points = ExtractJSONNumber(json, "max_spread_points");
    params.max_slippage_points = ExtractJSONNumber(json, "max_slippage_points");
    
    // 解析可选字段
    params.comment = ExtractJSONString(json, "comment");
    
    // 解析数组字段
    if(!ParseTPLevelsAndRatios(json, params)) {
        LogError("ParamLoader", "tp_levels/tp_ratios 解析失败: " + params.error_message);
        return false;
    }
    ParsePatterns(json, params);
    
    // 解析 news_blackout 数组
    if(!ParseNewsBlackout(json, params)) {
        LogError("ParamLoader", "news_blackout 解析失败: " + params.error_message);
        return false;
    }
    
    // 解析 session_filter 对象
    if(!ParseSessionFilter(json, params)) {
        LogError("ParamLoader", "session_filter 解析失败: " + params.error_message);
        return false;
    }
    
    LogDebug("ParamLoader", "JSON 解析完成");
    return true;
}

//+------------------------------------------------------------------+
//| 解析止盈数组（tp_levels 和 tp_ratios）                            |
//| 返回：true - 解析成功，false - 长度不一致                         |
//+------------------------------------------------------------------+
bool ParseTPLevelsAndRatios(string json, ParameterPack &params)
{
    int tp_count = 0;
    int ratio_count = 0;
    
    // 查找 tp_levels 数组
    int tp_levels_pos = StringFind(json, "\"tp_levels\"");
    if(tp_levels_pos >= 0) {
        int bracket_start = StringFind(json, "[", tp_levels_pos);
        int bracket_end = StringFind(json, "]", bracket_start);
        if(bracket_start >= 0 && bracket_end > bracket_start) {
            string tp_levels_str = StringSubstr(json, bracket_start + 1, bracket_end - bracket_start - 1);
            
            // 分割数组元素
            string tp_parts[];
            tp_count = StringSplit(tp_levels_str, ',', tp_parts);
            
            params.tp_count = MathMin(tp_count, 10);  // 最多 10 个
            for(int i = 0; i < params.tp_count; i++) {
                params.tp_levels[i] = StringToDouble(tp_parts[i]);
            }
            
            LogDebug("ParamLoader", "解析 tp_levels: 数量=" + IntegerToString(tp_count));
        }
    }
    
    // 查找 tp_ratios 数组
    int tp_ratios_pos = StringFind(json, "\"tp_ratios\"");
    if(tp_ratios_pos >= 0) {
        int bracket_start = StringFind(json, "[", tp_ratios_pos);
        int bracket_end = StringFind(json, "]", bracket_start);
        if(bracket_start >= 0 && bracket_end > bracket_start) {
            string tp_ratios_str = StringSubstr(json, bracket_start + 1, bracket_end - bracket_start - 1);
            
            // 分割数组元素
            string ratio_parts[];
            ratio_count = StringSplit(tp_ratios_str, ',', ratio_parts);
            
            // 检查长度一致性（硬失败）
            if(ratio_count != tp_count) {
                LogError("ParamLoader", "tp_ratios 长度(" + IntegerToString(ratio_count) + ") 与 tp_levels 长度(" + IntegerToString(tp_count) + ") 不一致");
                params.error_message = "tp_levels 和 tp_ratios 长度不一致，tp_levels=" + IntegerToString(tp_count) + ", tp_ratios=" + IntegerToString(ratio_count);
                return false;
            }
            
            // 长度一致，解析数据
            for(int i = 0; i < params.tp_count; i++) {
                params.tp_ratios[i] = StringToDouble(ratio_parts[i]);
            }
            
            LogDebug("ParamLoader", "解析 tp_ratios: 数量=" + IntegerToString(ratio_count));
        }
    }
    
    // 最终检查：两个数组都必须存在且长度一致
    if(tp_count == 0 || ratio_count == 0) {
        LogError("ParamLoader", "tp_levels 或 tp_ratios 数组为空");
        params.error_message = "tp_levels 或 tp_ratios 数组为空";
        return false;
    }
    
    if(tp_count != ratio_count) {
        LogError("ParamLoader", "tp_levels 和 tp_ratios 长度不一致");
        params.error_message = "tp_levels 和 tp_ratios 长度不一致";
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 解析形态数组（pattern）                                           |
//+------------------------------------------------------------------+
void ParsePatterns(string json, ParameterPack &params)
{
    // 查找 pattern 数组
    int pattern_pos = StringFind(json, "\"pattern\"");
    if(pattern_pos >= 0) {
        int bracket_start = StringFind(json, "[", pattern_pos);
        int bracket_end = StringFind(json, "]", bracket_start);
        if(bracket_start >= 0 && bracket_end > bracket_start) {
            string pattern_str = StringSubstr(json, bracket_start + 1, bracket_end - bracket_start - 1);
            
            // 移除引号和空格
            StringReplace(pattern_str, "\"", "");
            StringReplace(pattern_str, " ", "");
            
            // 分割数组元素
            string pattern_parts[];
            int pattern_count = StringSplit(pattern_str, ',', pattern_parts);
            
            params.pattern_count = MathMin(pattern_count, 10);  // 最多 10 个
            for(int i = 0; i < params.pattern_count; i++) {
                params.patterns[i] = pattern_parts[i];
            }
            
            LogDebug("ParamLoader", "解析 pattern: 数量=" + IntegerToString(params.pattern_count));
            for(int i = 0; i < params.pattern_count; i++) {
                LogDebug("ParamLoader", "  pattern[" + IntegerToString(i) + "]=" + params.patterns[i]);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 解析新闻禁开仓窗口数组（news_blackout）                           |
//| 返回：true - 解析成功或字段不存在，false - 字段存在但解析失败     |
//+------------------------------------------------------------------+
bool ParseNewsBlackout(string json, ParameterPack &params)
{
    // 初始化为 0
    params.blackout_count = 0;
    
    // 查找 news_blackout 数组
    int blackout_pos = StringFind(json, "\"news_blackout\"");
    if(blackout_pos < 0) {
        // 字段不存在，这是允许的（可选字段）
        LogDebug("ParamLoader", "news_blackout 字段不存在（可选）");
        return true;
    }
    
    // 字段存在，必须正确解析
    int bracket_start = StringFind(json, "[", blackout_pos);
    int bracket_end = StringFind(json, "]", bracket_start);
    
    if(bracket_start < 0 || bracket_end <= bracket_start) {
        params.error_message = "news_blackout 字段格式错误：找不到数组边界";
        return false;
    }
    
    // 提取数组内容
    string blackout_array = StringSubstr(json, bracket_start, bracket_end - bracket_start + 1);
    
    // 简单解析：查找所有 { } 对象
    int obj_count = 0;
    int search_pos = 0;
    
    while(obj_count < 20) {  // 最多 20 个窗口
        int obj_start = StringFind(blackout_array, "{", search_pos);
        if(obj_start < 0) break;
        
        int obj_end = StringFind(blackout_array, "}", obj_start);
        if(obj_end < 0) {
            params.error_message = "news_blackout 对象格式错误：找不到结束括号";
            return false;
        }
        
        // 提取单个对象
        string obj_str = StringSubstr(blackout_array, obj_start, obj_end - obj_start + 1);
        
        // 解析字段
        string start_str = ExtractJSONString(obj_str, "start");
        string end_str = ExtractJSONString(obj_str, "end");
        string reason_str = ExtractJSONString(obj_str, "reason");
        
        if(StringLen(start_str) == 0 || StringLen(end_str) == 0) {
            params.error_message = "news_blackout 对象缺少 start 或 end 字段";
            return false;
        }
        
        // 解析时间
        params.news_blackouts[obj_count].start = ParseISO8601(start_str);
        params.news_blackouts[obj_count].end = ParseISO8601(end_str);
        params.news_blackouts[obj_count].reason = reason_str;
        
        if(params.news_blackouts[obj_count].start == 0 || params.news_blackouts[obj_count].end == 0) {
            params.error_message = "news_blackout 时间解析失败: start=" + start_str + ", end=" + end_str;
            return false;
        }
        
        // 校验时间窗口逻辑正确性：start 必须小于 end
        if(params.news_blackouts[obj_count].start >= params.news_blackouts[obj_count].end) {
            params.error_message = StringFormat("news_blackout 时间窗口无效: start=%s >= end=%s",
                    TimeToString(params.news_blackouts[obj_count].start),
                    TimeToString(params.news_blackouts[obj_count].end));
            return false;
        }
        
        LogDebug("ParamLoader", StringFormat("解析 news_blackout[%d]: start=%s, end=%s, reason=%s",
                obj_count, TimeToString(params.news_blackouts[obj_count].start),
                TimeToString(params.news_blackouts[obj_count].end),
                params.news_blackouts[obj_count].reason));
        
        obj_count++;
        search_pos = obj_end + 1;
    }
    
    params.blackout_count = obj_count;
    LogDebug("ParamLoader", "解析 news_blackout: 数量=" + IntegerToString(params.blackout_count));
    
    return true;
}

//+------------------------------------------------------------------+
//| 解析交易时段过滤（session_filter）                                |
//| 返回：true - 解析成功或字段不存在，false - 字段存在但解析失败     |
//+------------------------------------------------------------------+
bool ParseSessionFilter(string json, ParameterPack &params)
{
    // 初始化为禁用
    params.session_filter.enabled = false;
    params.session_filter.allowed_count = 0;
    
    // 查找 session_filter 对象
    int filter_pos = StringFind(json, "\"session_filter\"");
    if(filter_pos < 0) {
        // 字段不存在，这是允许的（可选字段）
        LogDebug("ParamLoader", "session_filter 字段不存在（可选）");
        return true;
    }
    
    // 字段存在，必须正确解析
    int brace_start = StringFind(json, "{", filter_pos);
    int brace_end = StringFind(json, "}", brace_start);
    
    if(brace_start < 0 || brace_end <= brace_start) {
        params.error_message = "session_filter 字段格式错误：找不到对象边界";
        return false;
    }
    
    // 提取对象内容
    string filter_obj = StringSubstr(json, brace_start, brace_end - brace_start + 1);
    
    // 解析 enabled 字段
    params.session_filter.enabled = ExtractJSONBool(filter_obj, "enabled");
    
    LogDebug("ParamLoader", "解析 session_filter.enabled: " + (params.session_filter.enabled ? "true" : "false"));
    
    // 如果未启用，不需要解析 allowed_hours_utc
    if(!params.session_filter.enabled) {
        LogDebug("ParamLoader", "session_filter 未启用，跳过 allowed_hours_utc 解析");
        return true;
    }
    
    // 解析 allowed_hours_utc 数组
    int hours_pos = StringFind(filter_obj, "\"allowed_hours_utc\"");
    if(hours_pos < 0) {
        params.error_message = "session_filter.enabled=true 但缺少 allowed_hours_utc 字段";
        return false;
    }
    
    int bracket_start = StringFind(filter_obj, "[", hours_pos);
    int bracket_end = StringFind(filter_obj, "]", bracket_start);
    
    if(bracket_start < 0 || bracket_end <= bracket_start) {
        params.error_message = "session_filter.allowed_hours_utc 格式错误：找不到数组边界";
        return false;
    }
    
    // 提取数组内容
    string hours_str = StringSubstr(filter_obj, bracket_start + 1, bracket_end - bracket_start - 1);
    
    // 移除空格
    StringReplace(hours_str, " ", "");
    
    // 分割数组元素
    string hour_parts[];
    int hour_count = StringSplit(hours_str, ',', hour_parts);
    
    if(hour_count == 0) {
        params.error_message = "session_filter.allowed_hours_utc 数组为空";
        return false;
    }
    
    params.session_filter.allowed_count = MathMin(hour_count, 24);  // 最多 24 个
    for(int i = 0; i < params.session_filter.allowed_count; i++) {
        params.session_filter.allowed_hours_utc[i] = (int)StringToInteger(hour_parts[i]);
        
        // 校验小时范围
        if(params.session_filter.allowed_hours_utc[i] < 0 || params.session_filter.allowed_hours_utc[i] > 23) {
            params.error_message = "session_filter.allowed_hours_utc 包含无效小时: " + IntegerToString(params.session_filter.allowed_hours_utc[i]);
            return false;
        }
    }
    
    LogDebug("ParamLoader", "解析 session_filter.allowed_hours_utc: 数量=" + IntegerToString(params.session_filter.allowed_count));
    
    return true;
}

//+------------------------------------------------------------------+
//| 校验参数包                                                        |
//+------------------------------------------------------------------+
bool ValidateParameters(ParameterPack &params)
{
    LogDebug("ParamLoader", "开始校验参数");
    
    // 校验必需字段存在
    if(StringLen(params.version) == 0) {
        params.error_message = "缺少必需字段: version";
        return false;
    }
    
    if(StringLen(params.symbol) == 0) {
        params.error_message = "缺少必需字段: symbol";
        return false;
    }
    
    if(StringLen(params.timeframe) == 0) {
        params.error_message = "缺少必需字段: timeframe";
        return false;
    }
    
    if(StringLen(params.bias) == 0) {
        params.error_message = "缺少必需字段: bias";
        return false;
    }
    
    // 校验 V1 固定值
    if(params.symbol != "EURUSD") {
        params.error_message = "symbol 必须为 EURUSD，当前值: " + params.symbol;
        return false;
    }
    
    if(params.timeframe != "H4") {
        params.error_message = "timeframe 必须为 H4，当前值: " + params.timeframe;
        return false;
    }
    
    if(params.bias != "short_only") {
        params.error_message = "bias 必须为 short_only，当前值: " + params.bias;
        return false;
    }
    
    // 校验时间字段
    if(params.valid_from == 0) {
        params.error_message = "valid_from 解析失败或为空";
        return false;
    }
    
    if(params.valid_to == 0) {
        params.error_message = "valid_to 解析失败或为空";
        return false;
    }
    
    if(params.valid_from >= params.valid_to) {
        params.error_message = "valid_from 必须早于 valid_to";
        return false;
    }
    
    // 校验入场参数
    if(params.entry_zone_min >= params.entry_zone_max) {
        params.error_message = "entry_zone.min 必须小于 entry_zone.max";
        return false;
    }
    
    if(params.invalid_above <= 0) {
        params.error_message = "invalid_above 必须大于 0";
        return false;
    }
    
    // 校验技术指标参数
    if(params.ema_fast <= 0) {
        params.error_message = "ema_fast 必须大于 0";
        return false;
    }
    
    if(params.ema_trend <= 0) {
        params.error_message = "ema_trend 必须大于 0";
        return false;
    }
    
    if(params.lookback_period <= 0) {
        params.error_message = "lookback_period 必须大于 0";
        return false;
    }
    
    if(params.touch_tolerance <= 0) {
        params.error_message = "touch_tolerance 必须大于 0";
        return false;
    }
    
    // 校验风险参数
    if(params.risk_per_trade <= 0 || params.risk_per_trade > 0.1) {
        params.error_message = "risk.per_trade 必须在 (0, 0.1] 范围内";
        return false;
    }
    
    if(params.risk_daily_max_loss <= 0 || params.risk_daily_max_loss > 0.2) {
        params.error_message = "risk.daily_max_loss 必须在 (0, 0.2] 范围内";
        return false;
    }
    
    if(params.risk_consecutive_loss_limit <= 0) {
        params.error_message = "risk.consecutive_loss_limit 必须大于 0";
        return false;
    }
    
    // 校验执行参数
    if(params.max_spread_points <= 0) {
        params.error_message = "max_spread_points 必须大于 0";
        return false;
    }
    
    if(params.max_slippage_points <= 0) {
        params.error_message = "max_slippage_points 必须大于 0";
        return false;
    }
    
    // 校验 tp_levels 和 tp_ratios
    if(params.tp_count <= 0) {
        params.error_message = "tp_levels 数组为空";
        return false;
    }
    
    // 注意：长度一致性已在 ParseTPLevelsAndRatios() 中检查
    // 这里只需校验 tp_ratios 总和
    
    // 计算 tp_ratios 总和
    double ratio_sum = 0;
    for(int i = 0; i < params.tp_count; i++) {
        ratio_sum += params.tp_ratios[i];
    }
    
    // 校验总和是否为 1.0（允许浮点精度误差）
    if(MathAbs(ratio_sum - 1.0) > 1e-6) {
        params.error_message = "tp_ratios 总和必须为 1.0，当前值: " + DoubleToString(ratio_sum, 6);
        return false;
    }
    
    // 校验 pattern 数组
    if(params.pattern_count <= 0) {
        params.error_message = "pattern 数组为空";
        return false;
    }
    
    LogDebug("ParamLoader", "参数校验通过");
    return true;
}

//+------------------------------------------------------------------+
//| 获取当前参数包                                                    |
//+------------------------------------------------------------------+
ParameterPack GetCurrentParameters()
{
    return g_CurrentParams;
}

//+------------------------------------------------------------------+
//| 检查参数是否有效                                                  |
//+------------------------------------------------------------------+
bool IsParameterValid()
{
    if(!g_CurrentParams.is_valid) {
        return false;
    }
    
    // 检查参数是否在有效期内
    datetime current_utc = GetCurrentUTC();
    
    if(current_utc < g_CurrentParams.valid_from) {
        LogWarn("ParamLoader", "参数尚未生效，当前时间: " + TimeToString(current_utc) + 
              ", 生效时间: " + TimeToString(g_CurrentParams.valid_from));
        return false;
    }
    
    if(current_utc > g_CurrentParams.valid_to) {
        LogWarn("ParamLoader", "参数已过期，当前时间: " + TimeToString(current_utc) + 
              ", 过期时间: " + TimeToString(g_CurrentParams.valid_to));
        LogParameterLoad(g_CurrentParams.version, "EXPIRED", "参数已过期");
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 获取参数状态                                                      |
//+------------------------------------------------------------------+
string GetParameterStatus()
{
    if(!g_CurrentParams.is_valid) {
        return "invalid";
    }
    
    datetime current_utc = GetCurrentUTC();
    
    if(current_utc < g_CurrentParams.valid_from) {
        return "not_effective";
    }
    
    if(current_utc > g_CurrentParams.valid_to) {
        return "expired";
    }
    
    return "valid";
}

//+------------------------------------------------------------------+

#endif // PARAMETER_LOADER_MQH
