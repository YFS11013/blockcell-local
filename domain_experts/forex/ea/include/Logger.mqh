//+------------------------------------------------------------------+
//|                                                       Logger.mqh |
//|                        MT4 Forex Strategy Executor System V1.0   |
//|                                                                  |
//| 模块：日志记录器                                                  |
//| 功能：统一日志记录、格式化、级别过滤、字段校验                     |
//| 需求：5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 3.7                    |
//+------------------------------------------------------------------+
#property strict

#ifndef LOGGER_MQH
#define LOGGER_MQH

#include "TimeUtils.mqh"

//+------------------------------------------------------------------+
//| 日志级别枚举                                                      |
//+------------------------------------------------------------------+
enum LogLevelEnum {
    LOG_LEVEL_DEBUG = 0,
    LOG_LEVEL_INFO = 1,
    LOG_LEVEL_WARN = 2,
    LOG_LEVEL_ERROR = 3
};

//+------------------------------------------------------------------+
//| 全局日志配置                                                      |
//+------------------------------------------------------------------+
LogLevelEnum g_LogLevel = LOG_LEVEL_INFO;  // 默认日志级别
int g_LogFileHandle = INVALID_HANDLE;      // 日志文件句柄
string g_LogFileName = "";                 // 日志文件名

//+------------------------------------------------------------------+
//| 初始化日志系统                                                    |
//+------------------------------------------------------------------+
void InitLogger(string level = "INFO")
{
    // 设置日志级别
    if(level == "DEBUG") g_LogLevel = LOG_LEVEL_DEBUG;
    else if(level == "INFO") g_LogLevel = LOG_LEVEL_INFO;
    else if(level == "WARN") g_LogLevel = LOG_LEVEL_WARN;
    else if(level == "ERROR") g_LogLevel = LOG_LEVEL_ERROR;
    else g_LogLevel = LOG_LEVEL_INFO;
    
    // 创建日志文件
    datetime now = TimeCurrent();
    string date_str = TimeToString(now, TIME_DATE);
    StringReplace(date_str, ".", "");  // 移除日期中的点
    g_LogFileName = "EA_" + date_str + ".log";
    
    // 打开日志文件（追加模式）
    g_LogFileHandle = FileOpen(g_LogFileName, FILE_WRITE|FILE_TXT|FILE_ANSI, '\n');
    
    if(g_LogFileHandle == INVALID_HANDLE) {
        Print("[ERROR] 无法创建日志文件: ", g_LogFileName, ", 错误码: ", GetLastError());
    } else {
        // 写入日志头
        FileSeek(g_LogFileHandle, 0, SEEK_END);
        FileWrite(g_LogFileHandle, "========================================");
        FileWrite(g_LogFileHandle, "日志会话开始: " + TimeToString(now, TIME_DATE|TIME_SECONDS));
        FileWrite(g_LogFileHandle, "日志级别: " + level);
        FileWrite(g_LogFileHandle, "========================================");
        FileFlush(g_LogFileHandle);
    }
}

//+------------------------------------------------------------------+
//| 关闭日志系统                                                      |
//+------------------------------------------------------------------+
void CloseLogger()
{
    if(g_LogFileHandle != INVALID_HANDLE) {
        FileWrite(g_LogFileHandle, "========================================");
        FileWrite(g_LogFileHandle, "日志会话结束: " + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
        FileWrite(g_LogFileHandle, "========================================");
        FileClose(g_LogFileHandle);
        g_LogFileHandle = INVALID_HANDLE;
    }
}

//+------------------------------------------------------------------+
//| 日志级别转字符串                                                  |
//+------------------------------------------------------------------+
string LogLevelToString(LogLevelEnum level)
{
    switch(level) {
        case LOG_LEVEL_DEBUG: return "DEBUG";
        case LOG_LEVEL_INFO:  return "INFO";
        case LOG_LEVEL_WARN:  return "WARN";
        case LOG_LEVEL_ERROR: return "ERROR";
        default:              return "UNKNOWN";
    }
}

//+------------------------------------------------------------------+
//| 写入日志（内部函数）                                              |
//+------------------------------------------------------------------+
void WriteLog(LogLevelEnum level, string component, string message,
              string symbol = "", string rule_hit = "", 
              string param_version = "", string decision = "")
{
    // 级别过滤
    if(level < g_LogLevel) return;
    
    // 获取 UTC 时间戳
    datetime utc_time = ConvertToUTC(TimeCurrent());
    string timestamp = FormatISO8601(utc_time);
    
    // 构建日志消息（统一 Schema）
    string log_msg = "[" + timestamp + "]";
    log_msg += " [" + LogLevelToString(level) + "]";
    log_msg += " [" + component + "]";
    
    // 添加可选字段
    if(StringLen(symbol) > 0) {
        log_msg += " [symbol=" + symbol + "]";
    }
    if(StringLen(rule_hit) > 0) {
        log_msg += " [rule=" + rule_hit + "]";
    }
    if(StringLen(param_version) > 0) {
        log_msg += " [version=" + param_version + "]";
    }
    if(StringLen(decision) > 0) {
        log_msg += " [decision=" + decision + "]";
    }
    
    log_msg += " " + message;
    
    // 输出到 MT4 日志窗口
    Print(log_msg);
    
    // 输出到文件
    if(g_LogFileHandle != INVALID_HANDLE) {
        FileWrite(g_LogFileHandle, log_msg);
        FileFlush(g_LogFileHandle);
    }
}

//+------------------------------------------------------------------+
//| 基础日志函数                                                      |
//+------------------------------------------------------------------+
void LogDebug(string component, string message)
{
    WriteLog(LOG_LEVEL_DEBUG, component, message);
}

void LogInfo(string component, string message)
{
    WriteLog(LOG_LEVEL_INFO, component, message);
}

void LogWarn(string component, string message)
{
    WriteLog(LOG_LEVEL_WARN, component, message);
}

void LogError(string component, string message)
{
    WriteLog(LOG_LEVEL_ERROR, component, message);
}

//+------------------------------------------------------------------+
//| 记录参数加载                                                      |
//| 需求：5.1                                                        |
//+------------------------------------------------------------------+
void LogParameterLoad(string param_version, string status, string message = "")
{
    string decision = "";
    if(status == "SUCCESS") {
        decision = "LOADED";
    } else if(status == "FAILED") {
        decision = "REJECTED";
    } else if(status == "EXPIRED") {
        decision = "EXPIRED";
    } else {
        decision = status;
    }
    
    string full_message = "参数加载 " + status;
    if(StringLen(message) > 0) {
        full_message += ": " + message;
    }
    
    if(status == "SUCCESS") {
        WriteLog(LOG_LEVEL_INFO, "ParamLoader", full_message, 
                 "", "", param_version, decision);
    } else {
        WriteLog(LOG_LEVEL_ERROR, "ParamLoader", full_message, 
                 "", "", param_version, decision);
    }
}

//+------------------------------------------------------------------+
//| 记录信号评估                                                      |
//| 需求：5.2                                                        |
//+------------------------------------------------------------------+
void LogSignalEvaluation(string symbol, string rule_hit, string param_version, 
                         string decision, string message)
{
    // 字段强校验
    if(StringLen(symbol) == 0 || StringLen(rule_hit) == 0 || 
       StringLen(param_version) == 0 || StringLen(decision) == 0) {
        LogError("Logger", "LogSignalEvaluation: 缺少必需字段");
        return;
    }
    
    LogLevelEnum level = (decision == "OPEN") ? LOG_LEVEL_INFO : LOG_LEVEL_INFO;
    WriteLog(level, "Strategy", message, symbol, rule_hit, param_version, decision);
}

//+------------------------------------------------------------------+
//| 记录开仓                                                          |
//| 需求：5.3                                                        |
//+------------------------------------------------------------------+
void LogOrderOpen(int ticket, string symbol, double lots, double entry, 
                  double stop_loss, double take_profit, string param_version, 
                  string decision, double actual_slippage = 0)
{
    // 字段强校验
    if(StringLen(symbol) == 0 || StringLen(param_version) == 0 || 
       StringLen(decision) == 0) {
        LogError("Logger", "LogOrderOpen: 缺少必需字段");
        return;
    }
    
    string message = "开仓成功 #" + IntegerToString(ticket);
    message += " lots=" + DoubleToString(lots, 2);
    message += " entry=" + DoubleToString(entry, 5);
    message += " sl=" + DoubleToString(stop_loss, 5);
    message += " tp=" + DoubleToString(take_profit, 5);
    
    if(actual_slippage > 0) {
        message += " slippage=" + DoubleToString(actual_slippage, 1) + "pts";
    }
    
    WriteLog(LOG_LEVEL_INFO, "OrderExec", message, symbol, "", param_version, decision);
}

//+------------------------------------------------------------------+
//| 记录拒单                                                          |
//| 需求：5.4                                                        |
//+------------------------------------------------------------------+
void LogOrderReject(string symbol, string rule_hit, string param_version, 
                    string decision, string reason)
{
    // 字段强校验
    if(StringLen(symbol) == 0 || StringLen(rule_hit) == 0 || 
       StringLen(param_version) == 0 || StringLen(decision) == 0) {
        LogError("Logger", "LogOrderReject: 缺少必需字段");
        return;
    }
    
    string message = "拒单: " + reason;
    WriteLog(LOG_LEVEL_WARN, "Strategy", message, symbol, rule_hit, param_version, decision);
}

//+------------------------------------------------------------------+
//| 记录熔断                                                          |
//| 需求：5.5, 3.7                                                   |
//+------------------------------------------------------------------+
void LogCircuitBreaker(string circuit_type, double trigger_value, 
                       datetime recover_at_utc, string reason, 
                       string rule_hit, string decision)
{
    // 字段强校验（熔断日志的必填字段）
    if(StringLen(circuit_type) == 0 || StringLen(reason) == 0 || 
       StringLen(rule_hit) == 0 || StringLen(decision) == 0) {
        LogError("Logger", "LogCircuitBreaker: 缺少必需字段");
        return;
    }
    
    string message = "熔断触发 [" + circuit_type + "]";
    message += " trigger=" + DoubleToString(trigger_value, 2);
    message += " recover_at=" + FormatISO8601(recover_at_utc);
    message += " reason=" + reason;
    
    WriteLog(LOG_LEVEL_ERROR, "RiskMgr", message, "", rule_hit, "", decision);
}

//+------------------------------------------------------------------+
//| 记录平仓                                                          |
//| 需求：5.6                                                        |
//+------------------------------------------------------------------+
void LogOrderClose(int ticket, string symbol, double profit, string decision)
{
    // 字段强校验
    if(StringLen(symbol) == 0 || StringLen(decision) == 0) {
        LogError("Logger", "LogOrderClose: 缺少必需字段");
        return;
    }
    
    string message = "平仓 #" + IntegerToString(ticket);
    message += " profit=" + DoubleToString(profit, 2);
    
    LogLevelEnum level = (profit >= 0) ? LOG_LEVEL_INFO : LOG_LEVEL_WARN;
    WriteLog(level, "OrderExec", message, symbol, "", "", decision);
}

//+------------------------------------------------------------------+
//| 记录订单错误                                                      |
//+------------------------------------------------------------------+
void LogOrderError(string symbol, int error_code, string error_msg, 
                   string param_version, string decision)
{
    string message = "订单错误 [" + IntegerToString(error_code) + "]: " + error_msg;
    WriteLog(LOG_LEVEL_ERROR, "OrderExec", message, symbol, "", param_version, decision);
}

//+------------------------------------------------------------------+
//| 记录滑点警告                                                      |
//+------------------------------------------------------------------+
void LogSlippageWarning(string symbol, double actual_slippage, 
                        double max_slippage, string param_version)
{
    string message = "滑点超限: actual=" + DoubleToString(actual_slippage, 1) + 
                     "pts > max=" + DoubleToString(max_slippage, 1) + "pts";
    WriteLog(LOG_LEVEL_WARN, "OrderExec", message, symbol, "", param_version, "SLIPPAGE_EXCEEDED");
}

//+------------------------------------------------------------------+
//| 记录点差警告                                                      |
//+------------------------------------------------------------------+
void LogSpreadWarning(string symbol, double current_spread, 
                      double max_spread, string param_version)
{
    string message = "点差超限: current=" + DoubleToString(current_spread, 1) + 
                     "pts > max=" + DoubleToString(max_spread, 1) + "pts";
    WriteLog(LOG_LEVEL_WARN, "RiskMgr", message, symbol, "SPREAD_CHECK", param_version, "REJECTED");
}

//+------------------------------------------------------------------+
//| 记录时间过滤                                                      |
//+------------------------------------------------------------------+
void LogTimeFilter(string filter_type, string reason, string param_version)
{
    string message = "时间过滤触发 [" + filter_type + "]: " + reason;
    WriteLog(LOG_LEVEL_INFO, "TimeFilter", message, "", filter_type, param_version, "FILTERED");
}

//+------------------------------------------------------------------+
//| 记录 Safe Mode 切换                                              |
//+------------------------------------------------------------------+
void LogSafeModeTransition(string reason, string param_version)
{
    string message = "切换到 Safe Mode: " + reason;
    WriteLog(LOG_LEVEL_ERROR, "EA", message, "", "SAFE_MODE", param_version, "SAFE_MODE_ENTERED");
}

//+------------------------------------------------------------------+
//| 记录状态恢复                                                      |
//+------------------------------------------------------------------+
void LogStateRecovery(string from_state, string to_state, string reason)
{
    string message = "状态恢复: " + from_state + " -> " + to_state + ", " + reason;
    WriteLog(LOG_LEVEL_INFO, "EA", message, "", "STATE_RECOVERY", "", "RECOVERED");
}

//+------------------------------------------------------------------+

#endif // LOGGER_MQH
