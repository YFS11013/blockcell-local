//+------------------------------------------------------------------+
//|                                      ForexStrategyExecutor.mq4   |
//|                        MT4 Forex Strategy Executor System V1.1   |
//|                                                                  |
//| 描述：AI 决策建议 + EA 确定性执行的外汇交易自动化方案             |
//| 版本：V1.1.1                                                     |
//| 策略：EUR/USD H4 空头策略（EMA 趋势过滤 + 回踩确认 + 形态触发）   |
//+------------------------------------------------------------------+
#property copyright "MT4 Forex Strategy Executor"
#property version   "1.11"
#property strict

#define EA_VERSION "1.1.1"

//+------------------------------------------------------------------+
//| 引入模块                                                          |
//+------------------------------------------------------------------+
#include "include/TimeUtils.mqh"
#include "include/Logger.mqh"
#include "include/ParameterLoader.mqh"
#include "include/StrategyEngine.mqh"
#include "include/RiskManager.mqh"
#include "include/OrderExecutor.mqh"
#include "include/TimeFilter.mqh"
#include "include/PositionManager.mqh"

//+------------------------------------------------------------------+
//| 输入参数                                                          |
//+------------------------------------------------------------------+
input string ParamFilePath = "";              // 参数包文件路径（空则使用 MQL4/Files/signal_pack.json）
input bool DryRun = false;                    // Dry Run 模式（不下真实订单）
input string LogLevel = "INFO";               // 日志级别：DEBUG, INFO, WARN, ERROR
input int ParamCheckInterval = 300;           // 参数检查间隔（秒）
input bool AutoDetectUTCOffset = true;        // 自动探测服务器 UTC 偏移（失败回退手工值）
input int ServerUTCOffset = 2;                // 服务器时区偏移（小时），例如：+2 表示 UTC+2

//+------------------------------------------------------------------+
//| 回测模式专用参数                                                  |
//+------------------------------------------------------------------+
input string BacktestParamJSON = "";          // 回测模式：内嵌参数 JSON（留空则从文件加载）
input datetime BacktestStartDate = 0;         // 回测开始日期（0=使用默认）
input datetime BacktestEndDate = 0;           // 回测结束日期（0=使用默认）

//+------------------------------------------------------------------+
//| 全局变量                                                          |
//+------------------------------------------------------------------+

// EA 状态
enum EAState {
    STATE_INITIALIZING,      // 初始化中
    STATE_LOADING_PARAMS,    // 加载参数中
    STATE_RUNNING,           // 正常运行
    STATE_SAFE_MODE          // 安全模式
};

EAState g_CurrentState = STATE_INITIALIZING;

// 回测模式标记
bool g_IsBacktestMode = false;

// 参数检查
datetime g_LastParamCheck = 0;
datetime g_LastParamLoadUtc = 0;
string g_SourcePathMode = "default";

// K 线跟踪
datetime g_LastBarTime = 0;

// Signal_K 缓存（评估后只消费缓存，不重复评估）
bool g_PendingSignal = false;
SignalResult g_CachedSignal;
datetime g_CachedSignalCreatedAt = 0;

// 前置声明
string StateToString(EAState state);
void EvaluateAndExecuteSignal();
string ResolveSourcePathMode();
void MarkParameterLoadSuccess();
string GetLastParamLoadUtcText();

//+------------------------------------------------------------------+
//| 解析参数文件路径（MT4 文件沙箱相对路径优先）                      |
//+------------------------------------------------------------------+
string ResolveParameterFilePath()
{
    if(StringLen(ParamFilePath) == 0) {
        return "signal_pack.json";
    }
    return ParamFilePath;
}

//+------------------------------------------------------------------+
//| 重置信号缓存结构                                                  |
//+------------------------------------------------------------------+
void ResetSignalResult(SignalResult &signal)
{
    signal.is_valid = false;
    signal.reject_reason = "";
    signal.entry_price = 0;
    signal.stop_loss = 0;
    signal.tp_count = 0;
    signal.pattern = PATTERN_NONE;
    signal.signal_time = 0;
    signal.trend_ok = false;
    signal.zone_ok = false;
    signal.retracement_ok = false;
    signal.pattern_ok = false;
    
    for(int i = 0; i < 10; i++) {
        signal.tp_levels[i] = 0;
        signal.tp_ratios[i] = 0;
    }
}

//+------------------------------------------------------------------+
//| 复制信号缓存结构                                                  |
//+------------------------------------------------------------------+
void CopySignalResult(const SignalResult &src, SignalResult &dst)
{
    dst.is_valid = src.is_valid;
    dst.reject_reason = src.reject_reason;
    dst.entry_price = src.entry_price;
    dst.stop_loss = src.stop_loss;
    dst.tp_count = src.tp_count;
    dst.pattern = src.pattern;
    dst.signal_time = src.signal_time;
    dst.trend_ok = src.trend_ok;
    dst.zone_ok = src.zone_ok;
    dst.retracement_ok = src.retracement_ok;
    dst.pattern_ok = src.pattern_ok;
    
    for(int i = 0; i < 10; i++) {
        dst.tp_levels[i] = src.tp_levels[i];
        dst.tp_ratios[i] = src.tp_ratios[i];
    }
}

//+------------------------------------------------------------------+
//| 清理待执行信号缓存                                                |
//+------------------------------------------------------------------+
void ClearPendingSignalCache(string reason)
{
    if(g_PendingSignal) {
        LogDebug("EA", "清理信号缓存: " + reason);
    }
    
    g_PendingSignal = false;
    g_CachedSignalCreatedAt = 0;
    ResetSignalResult(g_CachedSignal);
}

//+------------------------------------------------------------------+
//| 记录 UTC 偏移诊断信息                                             |
//+------------------------------------------------------------------+
void LogUTCOffsetDiagnostics()
{
    int manual_offset_seconds = GetManualUTCOffsetSeconds();
    int auto_offset_seconds = 0;
    bool auto_detected = AutoDetectUTCOffset && TryDetectServerUTCOffsetSeconds(auto_offset_seconds);
    int effective_offset_seconds = GetEffectiveUTCOffsetSeconds();
    string effective_mode = auto_detected ? "AUTO" : "MANUAL_FALLBACK";
    
    LogInfo("EA", "UTC 偏移模式: " + (AutoDetectUTCOffset ? "自动探测+手工回退" : "仅手工配置"));
    LogInfo("EA", "  - 手工偏移: " + FormatUTCOffsetSeconds(manual_offset_seconds));
    
    if(auto_detected) {
        LogInfo("EA", "  - 自动探测偏移: " + FormatUTCOffsetSeconds(auto_offset_seconds));
        
        if(MathAbs((double)(auto_offset_seconds - manual_offset_seconds)) >= 3600.0) {
            LogWarn("EA", StringFormat("自动偏移与手工偏移差异较大: auto=%s, manual=%s",
                    FormatUTCOffsetSeconds(auto_offset_seconds),
                    FormatUTCOffsetSeconds(manual_offset_seconds)));
        }
    } else if(AutoDetectUTCOffset) {
        LogWarn("EA", "  - 自动探测失败，回退手工偏移");
    }
    
    LogInfo("EA", "  - 生效偏移: " + FormatUTCOffsetSeconds(effective_offset_seconds) + " (" + effective_mode + ")");
}

//+------------------------------------------------------------------+
//| 记录参数加载元信息（用于面板与诊断日志）                          |
//+------------------------------------------------------------------+
string ResolveSourcePathMode()
{
    if(g_IsBacktestMode && StringLen(BacktestParamJSON) > 0) {
        return "embedded";
    }
    if(StringLen(ParamFilePath) == 0) {
        return "default";
    }
    return "custom";
}

void MarkParameterLoadSuccess()
{
    g_LastParamLoadUtc = GetCurrentUTC();
    g_SourcePathMode = ResolveSourcePathMode();
}

string GetLastParamLoadUtcText()
{
    if(g_LastParamLoadUtc <= 0) {
        return "N/A";
    }
    return FormatISO8601(g_LastParamLoadUtc);
}

//+------------------------------------------------------------------+
//| 更新图表状态面板（显示版本号）                                    |
//+------------------------------------------------------------------+
void UpdateStatusPanel()
{
    string param_version = g_CurrentParams.is_valid ? g_CurrentParams.version : "N/A";
    string param_status = GetParameterStatus();
    
    int effective_offset_seconds = GetEffectiveUTCOffsetSeconds();
    int auto_offset_seconds = 0;
    bool auto_detected = AutoDetectUTCOffset && TryDetectServerUTCOffsetSeconds(auto_offset_seconds);
    string offset_mode = auto_detected ? "AUTO" : "MANUAL";
    
    string panel = "";
    panel += "ForexStrategyExecutor v" + EA_VERSION + "\n";
    panel += "State: " + StateToString(g_CurrentState) + (DryRun ? " / DRY RUN" : "") + "\n";
    panel += "param_version: " + param_version + " (" + param_status + ")\n";
    panel += "last_param_load_utc: " + GetLastParamLoadUtcText() + "\n";
    panel += "source_path_mode: " + g_SourcePathMode + "\n";
    panel += "UTC Offset: " + FormatUTCOffsetSeconds(effective_offset_seconds) + " [" + offset_mode + "]";
    
    if(g_PendingSignal) {
        panel += "\nSignal Cache: pending @" + TimeToString(g_CachedSignal.signal_time, TIME_DATE|TIME_MINUTES);
    } else {
        panel += "\nSignal Cache: none";
    }
    
    Comment(panel);
}

//+------------------------------------------------------------------+
//| 检测是否在回测模式                                                |
//+------------------------------------------------------------------+
bool IsBacktestMode()
{
    // MT4 在回测模式下会设置这个隐藏参数
    // 也可以通过检查 MQL4 内部状态来判断
    return IsTesting() || IsOptimization();
}

//+------------------------------------------------------------------+
//| 检查是否在回测日期窗口内                                           |
//+------------------------------------------------------------------+
bool IsWithinBacktestDateRange(datetime bar_time)
{
    if(!g_IsBacktestMode) {
        return true;
    }
    
    if(BacktestStartDate > 0 && bar_time < BacktestStartDate) {
        return false;
    }
    
    if(BacktestEndDate > 0 && bar_time > BacktestEndDate) {
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 加载内嵌参数（回测模式使用）                                      |
//+------------------------------------------------------------------+
bool LoadEmbeddedParameters(string json_content)
{
    LogInfo("EA", "加载内嵌参数（回测模式）");
    
    // 使用临时参数包
    ParameterPack temp_params;
    InitParameterPack(temp_params);
    
    // 解析 JSON 内容
    if(!ParseParameterJSON(json_content, temp_params)) {
        LogError("EA", "内嵌参数 JSON 解析失败: " + temp_params.error_message);
        return false;
    }
    
    // 校验参数
    if(!ValidateParameters(temp_params)) {
        LogError("EA", "内嵌参数校验失败: " + temp_params.error_message);
        return false;
    }
    
    // 更新全局参数
    g_CurrentParams = temp_params;
    g_CurrentParams.is_valid = true;
    
    LogInfo("EA", "内嵌参数加载成功");
    LogInfo("EA", "  版本: " + g_CurrentParams.version);
    LogInfo("EA", "  有效期: " + TimeToString(g_CurrentParams.valid_from) + " - " + TimeToString(g_CurrentParams.valid_to));
    
    return true;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("========================================");
    Print("ForexStrategyExecutor V" + EA_VERSION + " 启动中...");
    Print("========================================");
    
    ResetSignalResult(g_CachedSignal);
    g_PendingSignal = false;
    g_CachedSignalCreatedAt = 0;
    
    // 检测回测模式
    g_IsBacktestMode = IsBacktestMode();
    
    // 验证输入参数
    if(!ValidateInputParameters()) {
        Print("ERROR: 输入参数验证失败");
        return INIT_PARAMETERS_INCORRECT;
    }
    
    // 确定参数文件路径（MT4 文件沙箱）
    string param_file_path = ResolveParameterFilePath();
    if(StringLen(ParamFilePath) == 0) {
        Print("使用默认参数路径: MQL4/Files/" + param_file_path);
    }
    
    // 初始化日志系统
    InitLogger(LogLevel);
    
    // 记录回测模式状态
    if(g_IsBacktestMode) {
        LogInfo("EA", "========== 回测模式 ==========");
    }
    LogInfo("EA", "EA 初始化开始");
    LogInfo("EA", "EA 版本: " + EA_VERSION);
    
    // 初始化持仓管理器
    InitPositionManager();
    
    // 初始化风险管理器
    InitRiskState();
    
    // 记录配置信息
    LogInfo("EA", "配置信息:");
    LogInfo("EA", "  - 回测模式: " + (g_IsBacktestMode ? "是" : "否"));
    LogInfo("EA", "  - 参数文件路径: " + param_file_path);
    LogInfo("EA", "  - Dry Run 模式: " + (DryRun ? "启用" : "禁用"));
    LogInfo("EA", "  - 日志级别: " + LogLevel);
    LogInfo("EA", "  - 参数检查间隔: " + IntegerToString(ParamCheckInterval) + " 秒");
    LogInfo("EA", "  - UTC 偏移自动探测: " + (AutoDetectUTCOffset ? "启用" : "禁用"));
    LogInfo("EA", "  - 服务器 UTC 偏移: " + IntegerToString(ServerUTCOffset) + " 小时");
    LogUTCOffsetDiagnostics();
    if(g_IsBacktestMode) {
        LogInfo("EA", "  - 回测参数源: " + (StringLen(BacktestParamJSON) > 0 ? "BacktestParamJSON（内嵌）" : "参数文件"));
        LogInfo("EA", "  - 回测日期窗口: " + 
                (BacktestStartDate > 0 ? TimeToString(BacktestStartDate) : "未设置") + " ~ " +
                (BacktestEndDate > 0 ? TimeToString(BacktestEndDate) : "未设置"));
    }
    
    // 初始化 K 线跟踪
    g_LastBarTime = Time[0];
    LogInfo("EA", "初始 K 线时间: " + TimeToString(g_LastBarTime));
    
    // V1 固定品种和周期校验
    if(Symbol() != "EURUSD") {
        LogError("EA", "当前图表品种为 " + Symbol() + "，V1 仅支持 EURUSD");
        return INIT_FAILED;
    }
    
    if(Period() != PERIOD_H4) {
        LogError("EA", "当前图表周期为 " + IntegerToString(Period()) + " 分钟，V1 仅支持 H4 (240 分钟)");
        return INIT_FAILED;
    }
    
    LogInfo("EA", "品种和周期校验通过: EURUSD H4");
    
    // 加载参数包
    g_CurrentState = STATE_LOADING_PARAMS;
    
    bool params_loaded = false;
    
    if(g_IsBacktestMode) {
        // 回测模式：优先使用内嵌参数
        if(StringLen(BacktestParamJSON) > 0) {
            LogInfo("EA", "使用内嵌参数（BacktestParamJSON）");
            params_loaded = LoadEmbeddedParameters(BacktestParamJSON);
        } else {
            LogInfo("EA", "内嵌参数为空，将从文件加载参数");
            params_loaded = LoadParameterPack(param_file_path);
        }
    } else {
        // 实盘模式：从文件加载参数
        params_loaded = LoadParameterPack(param_file_path);
    }
    
    if(!params_loaded) {
        LogError("EA", "参数包加载失败，进入 Safe Mode");
        g_CurrentState = STATE_SAFE_MODE;
    } else {
        MarkParameterLoadSuccess();
        LogInfo("EA", "参数包加载成功，进入运行状态");
        g_CurrentState = STATE_RUNNING;
    }
    
    if(g_IsBacktestMode) {
        LogInfo("EA", "========== 回测模式初始化完成 ==========");
    }
    
    LogInfo("EA", "EA 初始化完成，当前状态: " + StateToString(g_CurrentState));
    UpdateStatusPanel();
    Print("========================================");
    Print("ForexStrategyExecutor 初始化完成");
    Print("当前状态: " + StateToString(g_CurrentState));
    Print("========================================");
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("========================================");
    Print("ForexStrategyExecutor 停止中...");
    Print("停止原因: " + DeInitReasonToString(reason));
    Print("========================================");
    
    LogInfo("EA", "EA 停止，原因: " + DeInitReasonToString(reason));
    ClearPendingSignalCache("EA 停止");
    
    // 保存状态（如果需要）
    SaveEAState();
    
    // 清理持仓管理器
    CleanupPositionManager();
    
    // 清理资源
    CleanupResources();
    
    // 写入停机末条日志
    LogInfo("EA", "EA 已停止");
    
    // 最后关闭日志系统
    CloseLogger();
    Comment("");
    
    Print("ForexStrategyExecutor 已停止");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
    // 检测新 K 线
    bool isNewBar = false;
    if(Time[0] != g_LastBarTime) {
        isNewBar = true;
        g_LastBarTime = Time[0];
        LogDebug("EA", "检测到新 K 线: " + TimeToString(g_LastBarTime));
    }
    
    // 定期检查参数更新
    if(TimeCurrent() - g_LastParamCheck >= ParamCheckInterval) {
        LogDebug("EA", "定期检查参数更新...");
        CheckParameterUpdate();
        g_LastParamCheck = TimeCurrent();
    }
    
    // 根据状态执行相应逻辑
    switch(g_CurrentState) {
        case STATE_RUNNING:
            // 正常运行状态
            
            if(isNewBar) {
                // 新 K 线首 tick：评估刚收盘的 K 线（Time[1]），如果满足条件则立即执行
                LogDebug("EA", "K 线收盘，评估入场信号...");
                EvaluateAndExecuteSignal();
            }
            
            // 检查持仓状态
            CheckPositionsWrapper();
            break;
            
        case STATE_SAFE_MODE:
            // 安全模式：只管理持仓，不开新仓
            LogDebug("EA", "Safe Mode: 只管理持仓");
            CheckPositionsWrapper();
            
            // 定期尝试恢复
            if(isNewBar) {
                TryRecoverFromSafeMode();
            }
            break;
            
        case STATE_LOADING_PARAMS:
        case STATE_INITIALIZING:
            // 这些状态不应该在 OnTick 中出现
            LogWarn("EA", "OnTick 中检测到异常状态: " + StateToString(g_CurrentState));
            break;
    }
    
    UpdateStatusPanel();
}

//+------------------------------------------------------------------+
//| 验证输入参数                                                      |
//+------------------------------------------------------------------+
bool ValidateInputParameters()
{
    // 验证日志级别
    if(LogLevel != "DEBUG" && LogLevel != "INFO" && 
       LogLevel != "WARN" && LogLevel != "ERROR") {
        Print("ERROR: 无效的日志级别: " + LogLevel);
        return false;
    }
    
    // 验证参数检查间隔
    if(ParamCheckInterval < 60) {
        Print("ERROR: 参数检查间隔过小（最小 60 秒）: " + IntegerToString(ParamCheckInterval));
        return false;
    }
    
    // 验证服务器 UTC 偏移
    if(ServerUTCOffset < -14 || ServerUTCOffset > 14) {
        Print("ERROR: 无效的服务器 UTC 偏移: " + IntegerToString(ServerUTCOffset));
        return false;
    }
    
    // 验证回测日期窗口
    if(g_IsBacktestMode &&
       BacktestStartDate > 0 &&
       BacktestEndDate > 0 &&
       BacktestStartDate >= BacktestEndDate) {
        Print("ERROR: 回测日期窗口无效: BacktestStartDate 必须早于 BacktestEndDate");
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| 状态转换为字符串                                                  |
//+------------------------------------------------------------------+
string StateToString(EAState state)
{
    switch(state) {
        case STATE_INITIALIZING:   return "INITIALIZING";
        case STATE_LOADING_PARAMS: return "LOADING_PARAMS";
        case STATE_RUNNING:        return "RUNNING";
        case STATE_SAFE_MODE:      return "SAFE_MODE";
        default:                   return "UNKNOWN";
    }
}

//+------------------------------------------------------------------+
//| 获取回测模式状态（供外部调用）                                    |
//+------------------------------------------------------------------+
bool IsBacktestModeEnabled()
{
    return g_IsBacktestMode;
}

//+------------------------------------------------------------------+
//| 停止原因转换为字符串                                              |
//+------------------------------------------------------------------+
string DeInitReasonToString(int reason)
{
    switch(reason) {
        case REASON_PROGRAM:     return "程序正常停止";
        case REASON_REMOVE:      return "EA 被移除";
        case REASON_RECOMPILE:   return "EA 被重新编译";
        case REASON_CHARTCHANGE: return "图表周期或品种改变";
        case REASON_CHARTCLOSE:  return "图表关闭";
        case REASON_PARAMETERS:  return "输入参数改变";
        case REASON_ACCOUNT:     return "账户改变";
        case REASON_TEMPLATE:    return "应用新模板";
        case REASON_INITFAILED:  return "初始化失败";
        case REASON_CLOSE:       return "终端关闭";
        default:                 return "未知原因 (" + IntegerToString(reason) + ")";
    }
}

//+------------------------------------------------------------------+
//| 占位函数 - 将在后续模块中实现                                     |
//+------------------------------------------------------------------+

// 参数更新检查
void CheckParameterUpdate() { 
    LogDebug("EA", "CheckParameterUpdate: 定期检查参数更新");
    
    // 回测内嵌参数模式下，禁止文件热更新覆盖内嵌参数
    if(g_IsBacktestMode && StringLen(BacktestParamJSON) > 0) {
        LogDebug("EA", "回测内嵌参数模式：跳过文件参数热更新");
        return;
    }
    
    // 确定参数文件路径（MT4 文件沙箱）
    string param_file_path = ResolveParameterFilePath();
    
    // 重新加载参数包
    if(LoadParameterPack(param_file_path)) {
        MarkParameterLoadSuccess();
        LogInfo("EA", "参数包已更新");
        ClearPendingSignalCache("参数包已更新");
        
        // 检查参数有效性
        if(!IsParameterValid()) {
            LogWarn("EA", "新参数包无效或已过期，切换到 Safe Mode");
            ClearPendingSignalCache("新参数无效");
            g_CurrentState = STATE_SAFE_MODE;
        }
    } else {
        // 加载失败，检查当前参数是否仍然有效
        if(!IsParameterValid()) {
            LogWarn("EA", "参数加载失败且当前参数已过期，切换到 Safe Mode");
            ClearPendingSignalCache("参数过期");
            g_CurrentState = STATE_SAFE_MODE;
        }
    }
}

//+------------------------------------------------------------------+
//| 在新 K 线首 tick 评估并缓存 Signal_K 信号                          |
//+------------------------------------------------------------------+
bool CacheSignalSnapshot(ParameterPack &params)
{
    if(g_PendingSignal) {
        LogWarn("EA", "检测到未消费的旧缓存信号，先清理后重新评估");
        ClearPendingSignalCache("覆盖旧缓存");
    }
    
    SignalResult evaluated_signal = EvaluateEntrySignal(params);
    
    if(!evaluated_signal.is_valid) {
        LogInfo("EA", "信号评估: 拒绝 - " + evaluated_signal.reject_reason);
        return false;
    }
    
    CopySignalResult(evaluated_signal, g_CachedSignal);
    g_PendingSignal = true;
    g_CachedSignalCreatedAt = TimeCurrent();
    
    LogInfo("EA", "Signal_K 信号已缓存");
    LogDebug("EA", StringFormat("缓存数据: signal_time=%s, entry(close)=%.5f, sl=%.5f, pattern=%s",
            TimeToString(g_CachedSignal.signal_time),
            g_CachedSignal.entry_price,
            g_CachedSignal.stop_loss,
            PatternTypeToString(g_CachedSignal.pattern)));
    
    return true;
}

//+------------------------------------------------------------------+
//| 仅使用缓存信号执行开仓（不得重新评估 Signal_K）                    |
//+------------------------------------------------------------------+
bool ExecutePendingSignal(ParameterPack &params)
{
    if(!g_PendingSignal) {
        return false;
    }
    
    SignalResult signal;
    CopySignalResult(g_CachedSignal, signal);
    
    LogInfo("EA", "使用缓存信号执行开仓（不重新评估 Signal_K）");
    LogDebug("EA", StringFormat("执行缓存: signal_time=%s, cached_at=%s, entry(close)=%.5f, sl=%.5f",
            TimeToString(signal.signal_time),
            TimeToString(g_CachedSignalCreatedAt),
            signal.entry_price,
            signal.stop_loss));
    
    // 检查风控条件
    if(!CanOpenNewPosition(params.risk_daily_max_loss, 
                          params.risk_consecutive_loss_limit, 
                          params.max_spread_points)) {
        LogWarn("EA", "风控检查失败，取消开仓");
        ClearPendingSignalCache("风控拒绝");
        return false;
    }
    
    // 检查时间过滤
    if(IsInNewsBlackout(params.news_blackouts, params.blackout_count)) {
        LogWarn("EA", "当前在新闻窗口内，取消开仓");
        ClearPendingSignalCache("新闻窗口拒绝");
        return false;
    }
    
    if(!IsInTradingSession(params.session_filter)) {
        LogWarn("EA", "当前不在交易时段内，取消开仓");
        ClearPendingSignalCache("时段过滤拒绝");
        return false;
    }
    
    if(signal.tp_count <= 0 || signal.tp_count > 10) {
        LogError("EA", "缓存信号 tp_count 无效，取消开仓");
        ClearPendingSignalCache("缓存数据异常");
        return false;
    }
    
    // 使用缓存 entry_price/stop_loss 计算仓位
    double total_lots = CalculatePositionSize(signal.entry_price, signal.stop_loss, params.risk_per_trade);
    if(total_lots <= 0) {
        LogError("EA", "计算手数失败或手数为 0，取消开仓");
        ClearPendingSignalCache("仓位计算失败");
        return false;
    }
    
    LogInfo("EA", StringFormat("计算总手数: %.2f", total_lots));
    
    // 拆分手数（使用缓存信号中的 TP 数据）
    LotSplit splits[];
    int tp_count = signal.tp_count;
    if(!SplitLots(total_lots, signal.tp_ratios, signal.tp_levels, tp_count, splits)) {
        LogError("EA", "拆单失败，取消开仓");
        ClearPendingSignalCache("拆单失败");
        return false;
    }
    
    // Dry Run：仅记录，不下单
    if(DryRun) {
        LogInfo("EA", "========== DRY RUN 模式 ==========");
        LogInfo("EA", StringFormat("模拟开仓: 品种=%s, 缓存入场(close)=%.5f, 止损=%.5f, 总手数=%.2f",
                Symbol(), signal.entry_price, signal.stop_loss, total_lots));
        
        for(int i = 0; i < tp_count; i++) {
            LogInfo("EA", StringFormat("  订单 %d: 手数=%.2f, 止盈=%.5f", 
                    i + 1, splits[i].lots, splits[i].tp_price));
        }
        
        LogInfo("EA", "========== DRY RUN 模式结束 ==========");
        ClearPendingSignalCache("DryRun 已消费");
        return true;
    }
    
    // 执行真实开仓（OrderSend 实际成交价由经纪商当前报价决定）
    int tickets[];
    ArrayResize(tickets, tp_count);
    
    int success_count = OpenMultiplePositions(splits, tp_count, signal.entry_price, signal.stop_loss, 
                                              (int)params.max_slippage_points, tickets);
    
    if(success_count == tp_count) {
        LogInfo("EA", StringFormat("成功开仓 %d 个订单（全部成功）", tp_count));
        for(int i = 0; i < tp_count; i++) {
            LogInfo("EA", StringFormat("  订单 %d: Ticket=%d, 手数=%.2f, 止盈=%.5f", 
                    i + 1, tickets[i], splits[i].lots, splits[i].tp_price));
        }
    } else if(success_count > 0) {
        LogWarn("EA", StringFormat("部分开仓成功: %d/%d 订单", success_count, tp_count));
        for(int i = 0; i < tp_count; i++) {
            if(tickets[i] > 0) {
                LogInfo("EA", StringFormat("  订单 %d: Ticket=%d, 手数=%.2f, 止盈=%.5f", 
                        i + 1, tickets[i], splits[i].lots, splits[i].tp_price));
            } else {
                LogError("EA", StringFormat("  订单 %d: 开仓失败", i + 1));
            }
        }
    } else {
        LogError("EA", "所有订单开仓失败");
    }
    
    ClearPendingSignalCache("执行完成");
    return (success_count > 0);
}

//+------------------------------------------------------------------+
//| 新 K 首 tick：评估并缓存 Signal_K，然后消费缓存执行                |
//+------------------------------------------------------------------+
void EvaluateAndExecuteSignal()
{
    // 检查参数有效期
    if(!IsParameterValid()) {
        LogWarn("EA", "参数无效或已过期，切换到 Safe Mode");
        ClearPendingSignalCache("参数失效");
        g_CurrentState = STATE_SAFE_MODE;
        return;
    }
    
    // 回测模式可选日期窗口过滤：仅限制开仓评估，不影响持仓管理
    datetime signal_bar_time = Time[1];
    if(!IsWithinBacktestDateRange(signal_bar_time)) {
        LogDebug("EA", "信号 K 线不在回测日期窗口内，跳过开仓评估: " + TimeToString(signal_bar_time));
        return;
    }
    
    ParameterPack params = GetCurrentParameters();
    
    if(!CacheSignalSnapshot(params)) {
        return;
    }
    
    ExecutePendingSignal(params);
}

// 持仓管理（包装函数）
void CheckPositionsWrapper() { 
    // 调用持仓管理器的检查函数
    CheckPositions();
}

// 状态管理
void TryRecoverFromSafeMode() { 
    LogDebug("EA", "TryRecoverFromSafeMode: 尝试从 Safe Mode 恢复");
    
    // 回测内嵌参数模式下，只允许从内嵌参数恢复，避免切换到文件参数
    if(g_IsBacktestMode && StringLen(BacktestParamJSON) > 0) {
        if(LoadEmbeddedParameters(BacktestParamJSON) && IsParameterValid()) {
            MarkParameterLoadSuccess();
            LogInfo("EA", "Safe Mode -> RUNNING 恢复成功，原因: embedded_params_reloaded_and_valid, version=" +
                    g_CurrentParams.version + ", source_path_mode=" + g_SourcePathMode +
                    ", last_param_load_utc=" + GetLastParamLoadUtcText());
            ClearPendingSignalCache("Safe Mode 恢复");
            g_CurrentState = STATE_RUNNING;
        } else {
            LogDebug("EA", "内嵌参数仍无效，保持 Safe Mode");
        }
        return;
    }
    
    // 确定参数文件路径（MT4 文件沙箱）
    string param_file_path = ResolveParameterFilePath();
    
    // 尝试重新加载参数
    if(LoadParameterPack(param_file_path)) {
        // 检查参数是否有效
        if(IsParameterValid()) {
            MarkParameterLoadSuccess();
            LogInfo("EA", "Safe Mode -> RUNNING 恢复成功，原因: file_params_reloaded_and_valid, version=" +
                    g_CurrentParams.version + ", source_path_mode=" + g_SourcePathMode +
                    ", last_param_load_utc=" + GetLastParamLoadUtcText());
            ClearPendingSignalCache("Safe Mode 恢复");
            g_CurrentState = STATE_RUNNING;
        } else {
            LogDebug("EA", "参数仍然无效，保持 Safe Mode");
        }
    } else {
        LogDebug("EA", "参数加载失败，保持 Safe Mode");
    }
}

void SaveEAState() { 
    LogDebug("EA", "SaveEAState: 保存 EA 状态");
    
    // 使用 GlobalVariable 保存风险状态
    GlobalVariableSet("FSE_DailyProfit", g_risk_state.daily_profit);
    GlobalVariableSet("FSE_ConsecutiveLosses", g_risk_state.consecutive_losses);
    GlobalVariableSet("FSE_CircuitBreakerUntil", (double)g_risk_state.circuit_breaker_until);
    GlobalVariableSet("FSE_LastResetDate", g_risk_state.last_reset_date);
    
    LogDebug("EA", "风险状态已保存到 GlobalVariable");
}

void CleanupResources() { 
    LogDebug("EA", "CleanupResources: 清理资源");
    
    // 清理全局变量（如果需要）
    // GlobalVariableDel("FSE_DailyProfit");
    // GlobalVariableDel("FSE_ConsecutiveLosses");
    // GlobalVariableDel("FSE_CircuitBreakerUntil");
    // GlobalVariableDel("FSE_LastResetDate");
    
    // 注意：通常不删除 GlobalVariable，以便 EA 重启后恢复状态
    
    LogDebug("EA", "资源清理完成");
}

//+------------------------------------------------------------------+
