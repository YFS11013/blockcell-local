// mt4_query skill — 通过 ZMQ 查询 MT4 DataService EA 的实时市场数据
// 依赖：DataService_EA.mq4 挂载在 MT4 图表上，端口 5556

let input = ctx.user_input;

// ============================================================================
// 解析用户输入，构建 ZMQ 命令
// ============================================================================

// 支持两种输入格式：
//   1. 直接命令：  "GET_INDICATOR:RSI,EURUSD,240,14"
//   2. 自然语言：  "EURUSD 的 RSI 是多少" → 由 agent 解析后传入命令格式

let cmd = input.trim();

// 如果输入为空，默认发 PING 检查连通性
if cmd == "" {
    cmd = "PING";
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

// zmq_client.py 以非零退出码表示 EA 返回了 error 字段
// 但 exec 返回的是 stdout，仍然是有效 JSON，继续解析

let instruction = "MT4 查询结果（命令：" + cmd + "）：\n\n```json\n" + result + "\n```";

// 针对常见命令给出友好说明
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
