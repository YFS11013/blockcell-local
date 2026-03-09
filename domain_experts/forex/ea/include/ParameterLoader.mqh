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

//+------------------------------------------------------------------+
//| 从文件加载参数包                                                  |
//| 参数：                                                            |
//|   filePath - 参数包文件路径                                      |
//| 返回：                                                            |
//|   true - 加载成功，false - 加载失败                              |
//+------------------------------------------------------------------+
bool LoadParameterPack(string filePath)
{
    Print("LoadParameterPack: 开始加载参数包 - ", filePath);
    
    // 初始化参数包
    InitParameterPack(g_CurrentParams);
    
    // 打开文件
    int file_handle = FileOpen(filePath, FILE_READ|FILE_TXT);
    if(file_handle == INVALID_HANDLE) {
        Print("ERROR: 无法打开参数文件: ", filePath, ", 错误码: ", GetLastError());
        g_CurrentParams.error_message = "文件打开失败";
        return false;
    }
    
    // 读取文件内容
    string json_content = "";
    while(!FileIsEnding(file_handle)) {
        json_content += FileReadString(file_handle);
    }
    FileClose(file_handle);
    
    if(StringLen(json_content) == 0) {
        Print("ERROR: 参数文件为空");
        g_CurrentParams.error_message = "文件内容为空";
        return false;
    }
    
    Print("LoadParameterPack: 文件读取成功，长度: ", StringLen(json_content));
    
    // 解析 JSON 内容
    if(!ParseParameterJSON(json_content, g_CurrentParams)) {
        Print("ERROR: JSON 解析失败");
        return false;
    }
    
    // 校验参数
    if(!ValidateParameters(g_CurrentParams)) {
        Print("ERROR: 参数校验失败: ", g_CurrentParams.error_message);
        return false;
    }
    
    Print("LoadParameterPack: 参数加载成功");
    Print("  版本: ", g_CurrentParams.version);
    Print("  品种: ", g_CurrentParams.symbol);
    Print("  周期: ", g_CurrentParams.timeframe);
    Print("  方向: ", g_CurrentParams.bias);
    Print("  有效期: ", TimeToString(g_CurrentParams.valid_from), " - ", TimeToString(g_CurrentParams.valid_to));
    
    g_CurrentParams.is_valid = true;
    return true;
}

//+------------------------------------------------------------------+
//| 解析 JSON 内容到参数包                                            |
//+------------------------------------------------------------------+
bool ParseParameterJSON(string json, ParameterPack &params)
{
    Print("ParseParameterJSON: 开始解析 JSON");
    
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
    
    // TODO: 解析数组字段（tp_levels, tp_ratios, pattern, news_blackout, session_filter）
    // 这些字段需要更复杂的解析逻辑，暂时使用占位实现
    params.tp_count = 0;
    params.pattern_count = 0;
    params.blackout_count = 0;
    params.session_filter.enabled = false;
    
    Print("ParseParameterJSON: JSON 解析完成");
    return true;
}

//+------------------------------------------------------------------+
//| 校验参数包                                                        |
//+------------------------------------------------------------------+
bool ValidateParameters(ParameterPack &params)
{
    Print("ValidateParameters: 开始校验参数");
    
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
    
    // TODO: 校验 tp_levels 和 tp_ratios 长度相同
    // TODO: 校验 tp_ratios 总和为 1.0
    
    Print("ValidateParameters: 参数校验通过");
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
        Print("WARN: 参数尚未生效，当前时间: ", TimeToString(current_utc), 
              ", 生效时间: ", TimeToString(g_CurrentParams.valid_from));
        return false;
    }
    
    if(current_utc > g_CurrentParams.valid_to) {
        Print("WARN: 参数已过期，当前时间: ", TimeToString(current_utc), 
              ", 过期时间: ", TimeToString(g_CurrentParams.valid_to));
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
