//+------------------------------------------------------------------+
//| ReplayWorker.mq4                                                 |
//| P2 通用历史回放 EA — 配合 P0 文件协议                              |
//|                                                                  |
//| 职责：                                                            |
//|   1. OnInit：读取 job.json，解析参数                              |
//|   2. OnTick：逐 bar 执行回放逻辑，每 10s 写 heartbeat.json        |
//|   3. OnDeinit：写 result.json（成功/失败）                        |
//|                                                                  |
//| 与 run_replay.ps1 配合：                                          |
//|   - run_replay.ps1 将 job.json 复制到 tester/files/job.json      |
//|   - EA 读取 job.json，写出 result_{job_id}.json                   |
//|   - run_replay.ps1 读取 result_{job_id}.json，写到 job 目录       |
//+------------------------------------------------------------------+
#property strict
#property version   "1.0"
#property description "P2 通用历史回放 Worker EA"

//── 输入参数 ──────────────────────────────────────────────────────────────────
input string JobId           = "";           // 由 run_replay.ps1 通过 .set 注入
input string JobFilePath     = "job.json";   // 相对于 MQL4/Files/tester/files/
input string ResultFilePath  = "";           // 相对于 MQL4/Files/tester/files/，空则自动推导
input bool   DryRun          = true;         // 始终 true，不下单

//── 全局状态 ──────────────────────────────────────────────────────────────────
string g_jobId          = "";
string g_resultFilePath = "";
string g_errorFilePath  = "";
string g_heartbeatPath  = "";

int    g_totalBars      = 0;
int    g_processedBars  = 0;
int    g_signalsGenerated = 0;
int    g_signalsHit     = 0;

double g_peakEquity     = 0;
double g_maxDrawdownPct = 0;
double g_totalProfitPips = 0;

datetime g_lastHeartbeat = 0;
bool   g_initOk         = false;
string g_errorMsg       = "";

//── 工具函数 ──────────────────────────────────────────────────────────────────

// 简单 JSON 字段提取（仅支持字符串值，足够读 job.json 基础字段）
string JsonGetString(string json, string key) {
    string pattern = "\"" + key + "\"";
    int pos = StringFind(json, pattern);
    if (pos < 0) return "";
    pos += StringLen(pattern);
    // 跳过空白和冒号
    while (pos < StringLen(json)) {
        ushort c = StringGetCharacter(json, pos);
        if (c != ' ' && c != '\t' && c != '\r' && c != '\n' && c != ':') break;
        pos++;
    }
    if (pos >= StringLen(json)) return "";
    ushort first = StringGetCharacter(json, pos);
    if (first == '"') {
        // 字符串值
        pos++;
        string result = "";
        while (pos < StringLen(json)) {
            ushort c = StringGetCharacter(json, pos);
            if (c == '"') break;
            if (c == '\\') { pos++; } // 跳过转义
            else result += ShortToString(c);
            pos++;
        }
        return result;
    }
    // 非字符串（数字/bool），读到分隔符为止
    string result = "";
    while (pos < StringLen(json)) {
        ushort c = StringGetCharacter(json, pos);
        if (c == ',' || c == '}' || c == ']' || c == ' ' || c == '\r' || c == '\n') break;
        result += ShortToString(c);
        pos++;
    }
    return result;
}

// 写文件（覆盖）
bool WriteFile(string path, string content) {
    int fh = FileOpen(path, FILE_WRITE | FILE_TXT | FILE_ANSI);
    if (fh == INVALID_HANDLE) {
        Print("[ReplayWorker] WriteFile 失败: ", path, " err=", GetLastError());
        return false;
    }
    FileWriteString(fh, content);
    FileClose(fh);
    return true;
}

// 读文件
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

// 写 heartbeat.json
void WriteHeartbeat(string status, int currentBar, int totalBars) {
    // Bug4 修复：progress_pct clamp 到 [0,100]，避免超出 schema 限制
    double pct = 0.0;
    if (totalBars > 0) {
        pct = 100.0 * currentBar / totalBars;
        if (pct > 100.0) pct = 100.0;
        if (pct < 0.0)   pct = 0.0;
    }
    // Bug4 修复：timestamp 使用 ISO 8601 格式（YYYY-MM-DDTHH:MM:SSZ）
    datetime now = TimeGMT();
    string ts = StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
        TimeYear(now), TimeMonth(now), TimeDay(now),
        TimeHour(now), TimeMinute(now), TimeSeconds(now));
    string json = StringFormat(
        "{\"job_id\":\"%s\",\"status\":\"%s\",\"timestamp\":\"%s\","
        "\"progress_pct\":%.1f,\"current_bar\":%d,\"total_bars\":%d,"
        "\"ea_version\":\"1.0\"}",
        g_jobId, status, ts,
        pct, currentBar, totalBars
    );
    WriteFile(g_heartbeatPath, json);
}

// 写 error 文件
void WriteError(string code, string message) {
    // Bug4 修复：timestamp 使用 ISO 8601 格式
    datetime now = TimeGMT();
    string ts = StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
        TimeYear(now), TimeMonth(now), TimeDay(now),
        TimeHour(now), TimeMinute(now), TimeSeconds(now));
    string json = StringFormat(
        "{\"job_id\":\"%s\",\"error_code\":\"%s\","
        "\"error_message\":\"%s\",\"timestamp\":\"%s\"}",
        g_jobId, code, message, ts
    );
    WriteFile(g_errorFilePath, json);
}

// 写 result.json（成功）
void WriteResultSuccess() {
    double hitRate = (g_signalsGenerated > 0)
        ? (double)g_signalsHit / g_signalsGenerated
        : 0.0;
    double avgProfitPips = (g_signalsHit > 0)
        ? g_totalProfitPips / g_signalsHit
        : 0.0;

    // Bug4 修复：finished_at 使用 ISO 8601 格式
    datetime now = TimeGMT();
    string ts = StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
        TimeYear(now), TimeMonth(now), TimeDay(now),
        TimeHour(now), TimeMinute(now), TimeSeconds(now));

    string json = StringFormat(
        "{\"job_id\":\"%s\",\"job_type\":\"replay\",\"status\":\"success\","
        "\"finished_at\":\"%s\","
        "\"data\":{"
        "\"total_bars\":%d,"
        "\"signals_generated\":%d,"
        "\"signals_hit\":%d,"
        "\"hit_rate\":%.4f,"
        "\"avg_profit_pips\":%.2f,"
        "\"max_drawdown_pct\":%.4f"
        "}}",
        g_jobId, ts,
        g_totalBars,
        g_signalsGenerated,
        g_signalsHit,
        hitRate,
        avgProfitPips,
        g_maxDrawdownPct
    );
    WriteFile(g_resultFilePath, json);
    Print("[ReplayWorker] result.json 已写出: ", g_resultFilePath);
}

// 写 result.json（失败）
void WriteResultFailed(string errorMessage) {
    // Bug4 修复：finished_at 使用 ISO 8601 格式
    datetime now = TimeGMT();
    string ts = StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
        TimeYear(now), TimeMonth(now), TimeDay(now),
        TimeHour(now), TimeMinute(now), TimeSeconds(now));
    string json = StringFormat(
        "{\"job_id\":\"%s\",\"job_type\":\"replay\",\"status\":\"failed\","
        "\"finished_at\":\"%s\","
        "\"error_message\":\"%s\"}",
        g_jobId, ts, errorMessage
    );
    WriteFile(g_resultFilePath, json);
}

//── EA 生命周期 ───────────────────────────────────────────────────────────────

int OnInit() {
    g_initOk = false;

    // 推导 job_id
    g_jobId = (StringLen(JobId) > 0) ? JobId : "unknown_job";

    // 推导文件路径（相对于 MQL4/Files/）
    string resultFile = (StringLen(ResultFilePath) > 0)
        ? ResultFilePath
        : ("result_" + g_jobId + ".json");
    g_resultFilePath  = resultFile;
    g_errorFilePath   = "error_" + g_jobId + ".json";
    g_heartbeatPath   = "heartbeat_" + g_jobId + ".json";

    Print("[ReplayWorker] OnInit: job_id=", g_jobId,
          " job_file=", JobFilePath,
          " result=", g_resultFilePath);

    // 读取 job.json
    string jobJson = ReadFile(JobFilePath);
    if (StringLen(jobJson) == 0) {
        g_errorMsg = "job.json 不存在或为空: " + JobFilePath;
        WriteError("JOB_NOT_FOUND", g_errorMsg);
        Print("[ReplayWorker] ERROR: ", g_errorMsg);
        return INIT_FAILED;
    }

    // 验证 job_type
    string jobType = JsonGetString(jobJson, "job_type");
    if (jobType != "replay") {
        g_errorMsg = "job_type 不是 replay: " + jobType;
        WriteError("JOB_PARSE_ERROR", g_errorMsg);
        return INIT_FAILED;
    }

    // 统计总 bar 数（Strategy Tester 中 Bars 即为回放范围内的 bar 数）
    g_totalBars = Bars;
    g_processedBars = 0;
    g_peakEquity = AccountEquity();

    // 写初始 heartbeat
    WriteHeartbeat("running", 0, g_totalBars);

    g_initOk = true;
    Print("[ReplayWorker] 初始化完成，总 bars=", g_totalBars);
    return INIT_SUCCEEDED;
}

void OnTick() {
    if (!g_initOk) return;

    g_processedBars++;

    // ── 回放核心逻辑（可替换为实际策略）────────────────────────────────────
    // 当前实现：简单 MA 交叉信号统计，作为通用框架示例
    // 实际使用时，blockcell 通过 ea_params 传入策略参数，EA 读取后执行对应逻辑

    if (g_processedBars >= 3) {
        double ma_fast = iMA(NULL, 0, 10, 0, MODE_EMA, PRICE_CLOSE, 0);
        double ma_slow = iMA(NULL, 0, 50, 0, MODE_EMA, PRICE_CLOSE, 0);
        double ma_fast_prev = iMA(NULL, 0, 10, 0, MODE_EMA, PRICE_CLOSE, 1);
        double ma_slow_prev = iMA(NULL, 0, 50, 0, MODE_EMA, PRICE_CLOSE, 1);

        // 金叉/死叉信号
        bool crossUp   = (ma_fast_prev < ma_slow_prev) && (ma_fast > ma_slow);
        bool crossDown = (ma_fast_prev > ma_slow_prev) && (ma_fast < ma_slow);

        if (crossUp || crossDown) {
            g_signalsGenerated++;

            // 简单命中判断：信号方向与下一根 bar 收盘方向一致
            double nextOpen  = iOpen(NULL, 0, 0);
            double nextClose = iClose(NULL, 0, 0);
            bool hit = (crossUp && nextClose > nextOpen) ||
                       (crossDown && nextClose < nextOpen);
            if (hit) {
                g_signalsHit++;
                double pips = MathAbs(nextClose - nextOpen) / Point / 10.0;
                g_totalProfitPips += pips;
            }
        }
    }

    // ── 最大回撤跟踪 ─────────────────────────────────────────────────────────
    double equity = AccountEquity();
    if (equity > g_peakEquity) g_peakEquity = equity;
    if (g_peakEquity > 0) {
        double dd = (g_peakEquity - equity) / g_peakEquity;
        if (dd > g_maxDrawdownPct) g_maxDrawdownPct = dd;
    }

    // ── 每 10s 写 heartbeat ──────────────────────────────────────────────────
    datetime now = TimeGMT();
    if (now - g_lastHeartbeat >= 10) {
        WriteHeartbeat("running", g_processedBars, g_totalBars);
        g_lastHeartbeat = now;
    }
}

void OnDeinit(const int reason) {
    if (!g_initOk) {
        // OnInit 失败时已写 error，不重复写 result
        return;
    }

    // Bug2 修复：根据退出原因区分正常完成 vs 中断/异常，避免假阳性
    // Strategy Tester 正常完成时 reason = REASON_PROGRAM(0) 或 REASON_CHARTCLOSE(3)
    // 被外部强制终止时 reason = REASON_REMOVE(1) 或其他非预期值
    bool normalExit = (reason == REASON_PROGRAM || reason == REASON_CHARTCLOSE ||
                       reason == REASON_RECOMPILE);

    WriteHeartbeat("idle", g_processedBars, g_totalBars);

    if (normalExit) {
        WriteResultSuccess();
        Print("[ReplayWorker] OnDeinit(正常): processed=", g_processedBars,
              " signals=", g_signalsGenerated,
              " hits=", g_signalsHit,
              " reason=", reason);
    } else {
        // 非正常退出（被移除、强制关闭等）写 failed
        string msg = StringFormat("EA 非正常退出（reason=%d，processed=%d/%d）",
                                  reason, g_processedBars, g_totalBars);
        WriteResultFailed(msg);
        WriteError("UNKNOWN", msg);
        Print("[ReplayWorker] OnDeinit(异常): ", msg);
    }
}
