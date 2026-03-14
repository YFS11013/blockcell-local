//+------------------------------------------------------------------+
//| FeatureWorker.mq4                                                |
//| P3 特征工程 EA — 配合 P0 文件协议                                  |
//|                                                                  |
//| 职责：                                                            |
//|   1. OnInit：读取 job.json，解析品种列表 + 特征列表               |
//|   2. OnTick：逐品种计算特征，写 heartbeat.json                    |
//|   3. OnDeinit：写 features.json + result.json                    |
//|                                                                  |
//| job.json 示例（job_type=feature）：                               |
//|   {                                                              |
//|     "job_id": "feature_20260314_120000_ab12",                    |
//|     "job_type": "feature",                                       |
//|     "symbols": ["EURUSD","USDJPY","GBPUSD"],                     |
//|     "features": ["RSI_H4","ATR_H4","MA_TREND","BB_POS",         |
//|                  "STOCH_H4","MARKET_STATE"],                     |
//|     "as_of_date": "2026-03-14"                                   |
//|   }                                                              |
//|                                                                  |
//| 输出 features.json 示例：                                         |
//|   {                                                              |
//|     "job_id": "...",                                             |
//|     "as_of_date": "2026-03-14",                                  |
//|     "features": {                                                |
//|       "EURUSD": {                                                |
//|         "RSI_H4": 58.3,                                          |
//|         "ATR_H4": 0.00082,                                       |
//|         "MA_TREND": "bullish",                                   |
//|         "BB_POS": 0.72,                                          |
//|         "STOCH_H4": 67.4,                                        |
//|         "MARKET_STATE": "trending_up"                            |
//|       }                                                          |
//|     }                                                            |
//|   }                                                              |
//+------------------------------------------------------------------+
#property strict
#property version   "1.0"
#property description "P3 特征工程 Worker EA"

//── 输入参数 ──────────────────────────────────────────────────────────────────
input string JobId          = "";          // 由 run_replay.ps1 通过 .set 注入
input string JobFilePath    = "job.json";  // 相对于 MQL4/Files/
input string ResultFilePath = "";          // 空则自动推导
input bool   DryRun         = true;

//── 全局状态 ──────────────────────────────────────────────────────────────────
string g_jobId          = "";
string g_resultFilePath = "";
string g_featuresPath   = "";
string g_errorFilePath  = "";
string g_heartbeatPath  = "";

// 品种列表（最多 20 个）
string g_symbols[20];
int    g_symbolCount = 0;

// 特征开关
bool g_feat_rsi_h4      = false;
bool g_feat_atr_h4      = false;
bool g_feat_ma_trend    = false;
bool g_feat_bb_pos      = false;
bool g_feat_stoch_h4    = false;
bool g_feat_market_state = false;
bool g_feat_rsi_d1      = false;
bool g_feat_atr_d1      = false;
bool g_feat_ma_h1       = false;

bool   g_initOk      = false;
bool   g_computed    = false;
string g_asOfDate    = "";
datetime g_lastHeartbeat = 0;

//── 工具函数 ──────────────────────────────────────────────────────────────────

string JsonGetString(string json, string key) {
    string pattern = "\"" + key + "\"";
    int pos = StringFind(json, pattern);
    if (pos < 0) return "";
    pos += StringLen(pattern);
    while (pos < StringLen(json)) {
        ushort c = StringGetCharacter(json, pos);
        if (c != ' ' && c != '\t' && c != '\r' && c != '\n' && c != ':') break;
        pos++;
    }
    if (pos >= StringLen(json)) return "";
    ushort first = StringGetCharacter(json, pos);
    if (first == '"') {
        pos++;
        string result = "";
        while (pos < StringLen(json)) {
            ushort c = StringGetCharacter(json, pos);
            if (c == '"') break;
            if (c == '\\') { pos++; }
            else result += ShortToString(c);
            pos++;
        }
        return result;
    }
    string result = "";
    while (pos < StringLen(json)) {
        ushort c = StringGetCharacter(json, pos);
        if (c == ',' || c == '}' || c == ']' || c == ' ' || c == '\r' || c == '\n') break;
        result += ShortToString(c);
        pos++;
    }
    return result;
}

// 解析 JSON 数组字符串（如 ["EURUSD","USDJPY"]），填充到 out[] 数组
int ParseJsonStringArray(string json, string key, string &out[], int maxCount) {
    string pattern = "\"" + key + "\"";
    int pos = StringFind(json, pattern);
    if (pos < 0) return 0;
    pos += StringLen(pattern);
    // 找到 [
    while (pos < StringLen(json) && StringGetCharacter(json, pos) != '[') pos++;
    if (pos >= StringLen(json)) return 0;
    pos++; // 跳过 [

    int count = 0;
    while (pos < StringLen(json) && count < maxCount) {
        ushort c = StringGetCharacter(json, pos);
        if (c == ']') break;
        if (c == '"') {
            pos++;
            string item = "";
            while (pos < StringLen(json)) {
                ushort ch = StringGetCharacter(json, pos);
                if (ch == '"') break;
                item += ShortToString(ch);
                pos++;
            }
            if (StringLen(item) > 0) {
                out[count] = item;
                count++;
            }
        }
        pos++;
    }
    return count;
}

bool WriteFile(string path, string content) {
    int fh = FileOpen(path, FILE_WRITE | FILE_TXT | FILE_ANSI);
    if (fh == INVALID_HANDLE) {
        Print("[FeatureWorker] WriteFile 失败: ", path, " err=", GetLastError());
        return false;
    }
    FileWriteString(fh, content);
    FileClose(fh);
    return true;
}

string ReadFile(string path) {
    int fh = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI);
    if (fh == INVALID_HANDLE) return "";
    string content = "";
    while (!FileIsEnding(fh)) {
        content += FileReadString(fh);
        if (!FileIsEnding(fh)) content += "\n";
    }
    FileClose(fh);
    return content;
}

void WriteHeartbeat(string status, int done, int total) {
    double pct = (total > 0) ? (100.0 * done / total) : 0;
    string json = StringFormat(
        "{\"job_id\":\"%s\",\"status\":\"%s\",\"timestamp\":\"%s\","
        "\"progress_pct\":%.1f,\"current_bar\":%d,\"total_bars\":%d,"
        "\"ea_version\":\"1.0\"}",
        g_jobId, status,
        TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS),
        pct, done, total
    );
    WriteFile(g_heartbeatPath, json);
}

void WriteError(string code, string message) {
    string json = StringFormat(
        "{\"job_id\":\"%s\",\"error_code\":\"%s\","
        "\"error_message\":\"%s\",\"timestamp\":\"%s\"}",
        g_jobId, code, message,
        TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS)
    );
    WriteFile(g_errorFilePath, json);
}

//── 特征计算函数 ──────────────────────────────────────────────────────────────

// RSI（H4，周期14，shift=1 取已完成 bar）
double CalcRSI_H4(string sym) {
    return iRSI(sym, PERIOD_H4, 14, PRICE_CLOSE, 1);
}

// ATR（H4，周期14）
double CalcATR_H4(string sym) {
    return iATR(sym, PERIOD_H4, 14, 1);
}

// RSI（D1，周期14）
double CalcRSI_D1(string sym) {
    return iRSI(sym, PERIOD_D1, 14, PRICE_CLOSE, 1);
}

// ATR（D1，周期14）
double CalcATR_D1(string sym) {
    return iATR(sym, PERIOD_D1, 14, 1);
}

// MA 趋势：EMA10 vs EMA50 vs EMA200（H4）
// 返回 "bullish" / "bearish" / "neutral"
string CalcMATrend(string sym) {
    double ema10  = iMA(sym, PERIOD_H4, 10,  0, MODE_EMA, PRICE_CLOSE, 1);
    double ema50  = iMA(sym, PERIOD_H4, 50,  0, MODE_EMA, PRICE_CLOSE, 1);
    double ema200 = iMA(sym, PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE, 1);
    if (ema10 > ema50 && ema50 > ema200) return "bullish";
    if (ema10 < ema50 && ema50 < ema200) return "bearish";
    return "neutral";
}

// MA H1 趋势（EMA20 vs EMA60）
string CalcMA_H1(string sym) {
    double ema20 = iMA(sym, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE, 1);
    double ema60 = iMA(sym, PERIOD_H1, 60, 0, MODE_EMA, PRICE_CLOSE, 1);
    if (ema20 > ema60) return "bullish";
    if (ema20 < ema60) return "bearish";
    return "neutral";
}

// Bollinger Band 位置：(close - lower) / (upper - lower)，0=下轨，1=上轨
double CalcBBPos(string sym) {
    double upper  = iBands(sym, PERIOD_H4, 20, 2.0, 0, PRICE_CLOSE, MODE_UPPER, 1);
    double lower  = iBands(sym, PERIOD_H4, 20, 2.0, 0, PRICE_CLOSE, MODE_LOWER, 1);
    double close  = iClose(sym, PERIOD_H4, 1);
    double range  = upper - lower;
    if (range < 1e-10) return 0.5;
    double pos = (close - lower) / range;
    if (pos < 0) pos = 0;
    if (pos > 1) pos = 1;
    return pos;
}

// Stochastic %K（H4，5,3,3）
double CalcStoch_H4(string sym) {
    return iStochastic(sym, PERIOD_H4, 5, 3, 3, MODE_SMA, 0, MODE_MAIN, 1);
}

// 市场状态综合判断
// trending_up / trending_down / ranging / breakout
string CalcMarketState(string sym) {
    string maTrend = CalcMATrend(sym);
    double rsi     = CalcRSI_H4(sym);
    double bbPos   = CalcBBPos(sym);

    if (maTrend == "bullish" && rsi > 50 && bbPos > 0.6) return "trending_up";
    if (maTrend == "bearish" && rsi < 50 && bbPos < 0.4) return "trending_down";
    if (bbPos > 0.85 || bbPos < 0.15)                    return "breakout";
    return "ranging";
}

//── 核心：计算所有品种特征，写 features.json ─────────────────────────────────

void ComputeAndWriteFeatures() {
    // 构建 features JSON
    string featuresJson = "{";
    featuresJson += "\"job_id\":\"" + g_jobId + "\",";
    featuresJson += "\"as_of_date\":\"" + g_asOfDate + "\",";
    featuresJson += "\"computed_at\":\"" + TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS) + "\",";
    featuresJson += "\"features\":{";

    for (int i = 0; i < g_symbolCount; i++) {
        string sym = g_symbols[i];
        WriteHeartbeat("running", i, g_symbolCount);

        if (i > 0) featuresJson += ",";
        featuresJson += "\"" + sym + "\":{";

        bool firstField = true;

        if (g_feat_rsi_h4) {
            double v = CalcRSI_H4(sym);
            if (!firstField) featuresJson += ",";
            featuresJson += StringFormat("\"RSI_H4\":%.4f", v);
            firstField = false;
        }
        if (g_feat_atr_h4) {
            double v = CalcATR_H4(sym);
            if (!firstField) featuresJson += ",";
            featuresJson += StringFormat("\"ATR_H4\":%.6f", v);
            firstField = false;
        }
        if (g_feat_rsi_d1) {
            double v = CalcRSI_D1(sym);
            if (!firstField) featuresJson += ",";
            featuresJson += StringFormat("\"RSI_D1\":%.4f", v);
            firstField = false;
        }
        if (g_feat_atr_d1) {
            double v = CalcATR_D1(sym);
            if (!firstField) featuresJson += ",";
            featuresJson += StringFormat("\"ATR_D1\":%.6f", v);
            firstField = false;
        }
        if (g_feat_ma_trend) {
            string v = CalcMATrend(sym);
            if (!firstField) featuresJson += ",";
            featuresJson += "\"MA_TREND\":\"" + v + "\"";
            firstField = false;
        }
        if (g_feat_ma_h1) {
            string v = CalcMA_H1(sym);
            if (!firstField) featuresJson += ",";
            featuresJson += "\"MA_H1\":\"" + v + "\"";
            firstField = false;
        }
        if (g_feat_bb_pos) {
            double v = CalcBBPos(sym);
            if (!firstField) featuresJson += ",";
            featuresJson += StringFormat("\"BB_POS\":%.4f", v);
            firstField = false;
        }
        if (g_feat_stoch_h4) {
            double v = CalcStoch_H4(sym);
            if (!firstField) featuresJson += ",";
            featuresJson += StringFormat("\"STOCH_H4\":%.4f", v);
            firstField = false;
        }
        if (g_feat_market_state) {
            string v = CalcMarketState(sym);
            if (!firstField) featuresJson += ",";
            featuresJson += "\"MARKET_STATE\":\"" + v + "\"";
            firstField = false;
        }

        featuresJson += "}";
        Print("[FeatureWorker] 完成品种: ", sym);
    }

    featuresJson += "}}";

    // 写 features.json
    WriteFile(g_featuresPath, featuresJson);
    Print("[FeatureWorker] features.json 已写出: ", g_featuresPath);

    // 写 result.json（包含 data.features 引用）
    string resultJson = StringFormat(
        "{\"job_id\":\"%s\",\"job_type\":\"feature\",\"status\":\"success\","
        "\"finished_at\":\"%s\","
        "\"data\":{"
        "\"symbols_processed\":%d,"
        "\"features_file\":\"%s\","
        "\"features\":%s"
        "}}",
        g_jobId,
        TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS),
        g_symbolCount,
        g_featuresPath,
        featuresJson
    );
    WriteFile(g_resultFilePath, resultJson);
    Print("[FeatureWorker] result.json 已写出: ", g_resultFilePath);
}

//── EA 生命周期 ───────────────────────────────────────────────────────────────

int OnInit() {
    g_initOk  = false;
    g_computed = false;

    g_jobId = (StringLen(JobId) > 0) ? JobId : "unknown_job";

    string resultFile = (StringLen(ResultFilePath) > 0)
        ? ResultFilePath
        : ("result_" + g_jobId + ".json");
    g_resultFilePath = resultFile;
    g_featuresPath   = "features_" + g_jobId + ".json";
    g_errorFilePath  = "error_"    + g_jobId + ".json";
    g_heartbeatPath  = "heartbeat_" + g_jobId + ".json";

    Print("[FeatureWorker] OnInit: job_id=", g_jobId, " job_file=", JobFilePath);

    // 读取 job.json
    string jobJson = ReadFile(JobFilePath);
    if (StringLen(jobJson) == 0) {
        string msg = "job.json 不存在或为空: " + JobFilePath;
        WriteError("JOB_NOT_FOUND", msg);
        Print("[FeatureWorker] ERROR: ", msg);
        return INIT_FAILED;
    }

    string jobType = JsonGetString(jobJson, "job_type");
    if (jobType != "feature") {
        string msg = "job_type 不是 feature: " + jobType;
        WriteError("JOB_PARSE_ERROR", msg);
        return INIT_FAILED;
    }

    // 解析 as_of_date
    g_asOfDate = JsonGetString(jobJson, "as_of_date");
    if (StringLen(g_asOfDate) == 0) {
        g_asOfDate = TimeToString(TimeGMT(), TIME_DATE);
    }

    // 解析品种列表
    g_symbolCount = ParseJsonStringArray(jobJson, "symbols", g_symbols, 20);
    if (g_symbolCount == 0) {
        // 默认品种
        g_symbols[0] = "EURUSD"; g_symbols[1] = "USDJPY"; g_symbols[2] = "GBPUSD";
        g_symbolCount = 3;
        Print("[FeatureWorker] 未指定 symbols，使用默认: EURUSD,USDJPY,GBPUSD");
    }

    // 解析特征列表
    string featureList[20];
    int featCount = ParseJsonStringArray(jobJson, "features", featureList, 20);
    if (featCount == 0) {
        // 默认全部特征
        g_feat_rsi_h4 = g_feat_atr_h4 = g_feat_ma_trend = true;
        g_feat_bb_pos = g_feat_stoch_h4 = g_feat_market_state = true;
    } else {
        for (int i = 0; i < featCount; i++) {
            string f = featureList[i];
            if (f == "RSI_H4")       g_feat_rsi_h4       = true;
            if (f == "ATR_H4")       g_feat_atr_h4       = true;
            if (f == "RSI_D1")       g_feat_rsi_d1       = true;
            if (f == "ATR_D1")       g_feat_atr_d1       = true;
            if (f == "MA_TREND")     g_feat_ma_trend     = true;
            if (f == "MA_H1")        g_feat_ma_h1        = true;
            if (f == "BB_POS")       g_feat_bb_pos       = true;
            if (f == "STOCH_H4")     g_feat_stoch_h4     = true;
            if (f == "MARKET_STATE") g_feat_market_state = true;
        }
    }

    WriteHeartbeat("running", 0, g_symbolCount);
    g_initOk = true;

    Print("[FeatureWorker] 初始化完成，品种数=", g_symbolCount, " as_of_date=", g_asOfDate);
    return INIT_SUCCEEDED;
}

void OnTick() {
    if (!g_initOk || g_computed) return;

    // 在第一个 tick 完成所有计算（Strategy Tester 模式下只需一次）
    g_computed = true;
    ComputeAndWriteFeatures();
    WriteHeartbeat("idle", g_symbolCount, g_symbolCount);
}

void OnDeinit(const int reason) {
    if (!g_initOk) return;

    // 如果 OnTick 未触发（极端情况），在 OnDeinit 补算
    if (!g_computed) {
        g_computed = true;
        ComputeAndWriteFeatures();
    }

    WriteHeartbeat("idle", g_symbolCount, g_symbolCount);
    Print("[FeatureWorker] OnDeinit: reason=", reason);
}
