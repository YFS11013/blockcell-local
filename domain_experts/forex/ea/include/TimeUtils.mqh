//+------------------------------------------------------------------+
//|                                                    TimeUtils.mqh |
//|                        MT4 Forex Strategy Executor - Time Utils  |
//|                                                                  |
//| 描述：时间处理工具模块                                            |
//| 功能：                                                            |
//|   - UTC 时间转换                                                 |
//|   - ISO 8601 时间解析                                            |
//|   - 时间格式化                                                   |
//+------------------------------------------------------------------+
#property copyright "MT4 Forex Strategy Executor"
#property strict

//+------------------------------------------------------------------+
//| 将 MT4 服务器时间转换为 UTC 时间                                  |
//| 参数：                                                            |
//|   server_time - MT4 服务器时间                                   |
//| 返回：                                                            |
//|   UTC 时间                                                       |
//| 说明：                                                            |
//|   使用全局输入参数 ServerUTCOffset 进行转换                       |
//|   转换公式：utc_time = server_time - ServerUTCOffset * 3600      |
//+------------------------------------------------------------------+
datetime ConvertToUTC(datetime server_time)
{
    // 转换为 UTC
    datetime utc_time = server_time - ServerUTCOffset * 3600;
    
    return utc_time;
}

//+------------------------------------------------------------------+
//| 解析 ISO 8601 时间字符串（YYYY-MM-DDTHH:MM:SSZ）                 |
//| 参数：                                                            |
//|   iso_str - ISO 8601 格式的时间字符串                            |
//| 返回：                                                            |
//|   datetime 类型的时间，解析失败返回 0                            |
//| 说明：                                                            |
//|   支持格式：YYYY-MM-DDTHH:MM:SSZ                                 |
//|   Z 后缀表示 UTC 时区                                            |
//+------------------------------------------------------------------+
datetime ParseISO8601(string iso_str)
{
    // 移除 T 和 Z 字符，转换为标准格式
    string clean_str = iso_str;
    StringReplace(clean_str, "T", " ");
    StringReplace(clean_str, "Z", "");
    
    // 分割日期和时间部分
    string parts[];
    int part_count = StringSplit(clean_str, ' ', parts);
    
    if(part_count != 2) {
        Print("ERROR: ParseISO8601 - 无效的时间格式: ", iso_str);
        return 0;
    }
    
    // 解析日期部分 YYYY-MM-DD
    string date_parts[];
    int date_count = StringSplit(parts[0], '-', date_parts);
    
    if(date_count != 3) {
        Print("ERROR: ParseISO8601 - 无效的日期格式: ", parts[0]);
        return 0;
    }
    
    // 解析时间部分 HH:MM:SS
    string time_parts[];
    int time_count = StringSplit(parts[1], ':', time_parts);
    
    if(time_count != 3) {
        Print("ERROR: ParseISO8601 - 无效的时间格式: ", parts[1]);
        return 0;
    }
    
    // 构建 MqlDateTime 结构体
    MqlDateTime dt;
    dt.year = (int)StringToInteger(date_parts[0]);
    dt.mon = (int)StringToInteger(date_parts[1]);
    dt.day = (int)StringToInteger(date_parts[2]);
    dt.hour = (int)StringToInteger(time_parts[0]);
    dt.min = (int)StringToInteger(time_parts[1]);
    dt.sec = (int)StringToInteger(time_parts[2]);
    dt.day_of_week = 0;  // 将由 StructToTime 自动计算
    dt.day_of_year = 0;  // 将由 StructToTime 自动计算
    
    // 转换为 datetime
    datetime result = StructToTime(dt);
    
    if(result == 0) {
        Print("ERROR: ParseISO8601 - StructToTime 转换失败");
        return 0;
    }
    
    return result;
}

//+------------------------------------------------------------------+
//| 将 datetime 格式化为 ISO 8601 字符串（YYYY-MM-DDTHH:MM:SSZ）     |
//| 参数：                                                            |
//|   dt - datetime 类型的时间                                       |
//| 返回：                                                            |
//|   ISO 8601 格式的字符串                                          |
//+------------------------------------------------------------------+
string FormatISO8601(datetime dt)
{
    MqlDateTime mdt;
    TimeToStruct(dt, mdt);
    
    string result = StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
                                  mdt.year, mdt.mon, mdt.day,
                                  mdt.hour, mdt.min, mdt.sec);
    
    return result;
}

//+------------------------------------------------------------------+
//| 获取当前 UTC 时间                                                 |
//| 返回：                                                            |
//|   当前 UTC 时间                                                  |
//+------------------------------------------------------------------+
datetime GetCurrentUTC()
{
    return ConvertToUTC(TimeCurrent());
}

//+------------------------------------------------------------------+
//| 获取当前 UTC 日期（YYYYMMDD 格式）                                |
//| 返回：                                                            |
//|   YYYYMMDD 格式的整数                                            |
//+------------------------------------------------------------------+
int GetCurrentUTCDate()
{
    datetime utc_now = GetCurrentUTC();
    
    int year = TimeYear(utc_now);
    int month = TimeMonth(utc_now);
    int day = TimeDay(utc_now);
    
    return year * 10000 + month * 100 + day;
}

//+------------------------------------------------------------------+
//| 测试时间工具函数                                                  |
//+------------------------------------------------------------------+
void TestTimeUtils()
{
    Print("========== TimeUtils 测试 ==========");
    
    // 测试 ConvertToUTC
    datetime server_time = TimeCurrent();
    datetime utc_time = ConvertToUTC(server_time);
    Print("服务器时间: ", TimeToString(server_time, TIME_DATE|TIME_SECONDS));
    Print("UTC 时间: ", TimeToString(utc_time, TIME_DATE|TIME_SECONDS));
    
    // 测试 ParseISO8601
    string iso_str = "2025-03-09T08:00:00Z";
    datetime parsed = ParseISO8601(iso_str);
    Print("ISO 8601 字符串: ", iso_str);
    Print("解析结果: ", TimeToString(parsed, TIME_DATE|TIME_SECONDS));
    
    // 测试 FormatISO8601
    string formatted = FormatISO8601(parsed);
    Print("格式化结果: ", formatted);
    
    // 测试 GetCurrentUTC
    datetime current_utc = GetCurrentUTC();
    Print("当前 UTC 时间: ", TimeToString(current_utc, TIME_DATE|TIME_SECONDS));
    
    // 测试 GetCurrentUTCDate
    int current_date = GetCurrentUTCDate();
    Print("当前 UTC 日期: ", IntegerToString(current_date));
    
    Print("========== 测试完成 ==========");
}

//+------------------------------------------------------------------+
