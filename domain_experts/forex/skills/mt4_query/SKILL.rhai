// mt4_query skill — 通过 ZMQ 查询 MT4 DataService EA 的实时市场数据
// 依赖：DataService_EA.mq4 挂载在 MT4 图表上，端口 5556

let input = ctx.user_input.trim();

// ============================================================================
// 自然语言 → ZMQ 命令映射
// ============================================================================
// 支持两种输入格式：
//   1. 直接命令：  "GET_INDICATOR:RSI,EURUSD,240,14"
//   2. 自然语言：  "EURUSD 的 RSI 是多少" → 自动映射为命令格式

let cmd = input;

// 空输入 → PING
if cmd == "" {
    cmd = "PING";
}

// 自然语言映射（仅当输入不是标准命令格式时）
if !cmd.contains(":") && cmd != "PING" && cmd != "IS_MARKET_OPEN" && cmd != "GET_ACCOUNT_INFO" && cmd != "GET_POSITIONS" {
    let lower = cmd.to_lower();

    // 持仓查询
    if lower.contains("持仓") || lower.contains("position") || lower.contains("单子") || lower.contains("订单") {
        cmd = "GET_POSITIONS";
    }
    // 账户信息
    else if lower.contains("账户") || lower.contains("余额") || lower.contains("净值") || lower.contains("account") || lower.contains("balance") {
        cmd = "GET_ACCOUNT_INFO";
    }
    // 市场状态
    else if lower.contains("市场") || lower.contains("开市") || lower.contains("能交易") || lower.contains("market") || lower.contains("连接") {
        cmd = "IS_MARKET_OPEN";
    }
    // RSI 查询（默认 EURUSD H4 14）
    else if lower.contains("rsi") {
        let sym = "EURUSD";
        if lower.contains("gbpusd") { sym = "GBPUSD"; }
        else if lower.contains("usdjpy") { sym = "USDJPY"; }
        else if lower.contains("audusd") { sym = "AUDUSD"; }
        let tf = "240";
        if lower.contains("h1") || lower.contains("1小时") { tf = "60"; }
        else if lower.contains("d1") || lower.contains("日线") { tf = "1440"; }
        else if lower.contains("m15") { tf = "15"; }
        cmd = "GET_INDICATOR:RSI," + sym + "," + tf + ",14";
    }
    // MACD 查询
    else if lower.contains("macd") {
        let sym = "EURUSD";
        if lower.contains("gbpusd") { sym = "GBPUSD"; }
        cmd = "GET_INDICATOR:MACD," + sym + ",240,12,26,9";
    }
    // EMA/MA 查询
    else if lower.contains("ema") || lower.contains("均线") {
        let sym = "EURUSD";
        if lower.contains("gbpusd") { sym = "GBPUSD"; }
        cmd = "GET_INDICATOR:EMA," + sym + ",240,200";
    }
    // 报价查询
    else if lower.contains("价格") || lower.contains("报价") || lower.contains("多少") || lower.contains("price") || lower.contains("quote") {
        let sym = "EURUSD";
        if lower.contains("gbpusd") { sym = "GBPUSD"; }
        else if lower.contains("usdjpy") { sym = "USDJPY"; }
        else if lower.contains("audusd") { sym = "AUDUSD"; }
        cmd = "GET_SYMBOL_INFO:" + sym;
    }
    // 连通性检查
    else if lower.contains("ping") || lower.contains("连通") || lower.contains("正常") {
        cmd = "PING";
    }
}

// ============================================================================
// 调用 zmq_client.py
// ============================================================================

let result = exec("python", [
    "domain_experts/forex/ea/scripts/zmq_client.py",
    cmd,
    "--timeout", "5000"
]);

// ============================================================================
// 处理结果
// ============================================================================

if is_error(result) {
    return #{
        success: false,
        error: result.to_string(),
        instruction: "MT4 DataService EA 查询失败。\n\n可能原因：\n1. DataService_EA 未挂载在 MT4 图表上\n2. MT4 自动交易未启用\n3. pyzmq 未安装（pip install pyzmq）\n4. 端口 5556 被占用\n\n请确认 MT4 已运行并挂载了 DataService_EA.mq4"
    };
}

let instruction = "MT4 查询结果（命令：" + cmd + "）：\n\n```json\n" + result + "\n```";

if cmd == "PING" {
    instruction = "MT4 DataService EA 连通性检查：" + result;
} else if cmd == "IS_MARKET_OPEN" {
    instruction = "市场状态查询结果：\n\n" + result;
} else if cmd == "GET_ACCOUNT_INFO" {
    instruction = "账户信息：\n\n" + result;
} else if cmd == "GET_POSITIONS" {
    instruction = "当前持仓：\n\n" + result;
}

return #{
    success: true,
    command: cmd,
    raw: result,
    instruction: instruction
};
