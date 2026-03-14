// mt4_features skill — 通过文件协议（job/result/features JSON）+ FeatureWorker EA 计算多品种技术特征
// 依赖：MT4 portable runner + FeatureWorker.mq4 + run_feature.ps1

let input = ctx.user_input.trim();

// ============================================================================
// 解析输入，构建 job.json
// ============================================================================
// 支持两种格式：
//   1. JSON 格式：直接传 job.json 内容（job_type 必须为 feature）
//   2. 简写格式：  "EURUSD,USDJPY RSI_H4,ATR_H4,MARKET_STATE"
//                  "EURUSD"  （只传品种，使用默认特征集）

import "std" as std;

// 生成 job_id
let ts = std::now_utc_iso().replace("-","").replace(":","").replace("T","_").slice(0, 15);
let rand4 = std::random_hex(2);
let job_id = `feature_${ts}_${rand4}`;

// 解析输入
let job_json = "";

if input.starts_with("{") {
    // 直接传 JSON
    job_json = input;
} else {
    // 简写解析：第一段为品种（逗号分隔），第二段为特征（空格分隔）
    let parts = input.split(" ");
    let symbols_str = parts[0];
    let features_str = if parts.len() > 1 { parts[1] } else { "" };

    // 构建 symbols 数组
    let symbols_arr = symbols_str.split(",")
        .map(|s| `"${s.trim()}"`)
        .join(",");

    // 构建 features 数组（默认全套）
    let features_arr = if features_str == "" {
        `"RSI_H4","ATR_H4","MA_TREND","BB_POS","STOCH_H4","MARKET_STATE"`
    } else {
        features_str.split(",")
            .map(|f| `"${f.trim()}"`)
            .join(",")
    };

    let now_iso = std::now_utc_iso();
    let today   = now_iso.slice(0, 10);

    job_json = `{
  "job_id": "${job_id}",
  "job_type": "feature",
  "created_at": "${now_iso}",
  "symbols": [${symbols_arr}],
  "features": [${features_arr}],
  "as_of_date": "${today}",
  "timeout_seconds": 120
}`;
}

// ============================================================================
// 写 job.json 到临时目录
// ============================================================================

let job_dir = `domain_experts/forex/ea/jobs/${job_id}`;
let job_file = `${job_dir}/job.json`;

let write_result = exec("powershell", [
    "-NoProfile", "-Command",
    `New-Item -ItemType Directory -Path '${job_dir}' -Force | Out-Null; [System.IO.File]::WriteAllText('${job_file}', '${job_json}', [System.Text.Encoding]::UTF8)`
]);

if is_error(write_result) {
    return #{
        success: false,
        error: `写 job.json 失败: ${write_result}`,
        instruction: "mt4_features: 无法创建 job 目录，请检查路径权限。"
    };
}

// ============================================================================
// 调用 run_feature.ps1
// ============================================================================

let ps_result = exec("powershell", [
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", "domain_experts/forex/ea/scripts/run_feature.ps1",
    "-JobFile", job_file
]);

if is_error(ps_result) {
    return #{
        success: false,
        job_id: job_id,
        error: ps_result.to_string(),
        instruction: `mt4_features 执行失败（job_id=${job_id}）。\n\n可能原因：\n1. MT4 portable runner 未配置（.mt4_portable_runner 目录不存在）\n2. FeatureWorker.mq4 编译失败\n3. 历史数据不足\n\n详情：\n${ps_result}`
    };
}

// ============================================================================
// 读取 result.json + features.json
// ============================================================================

let result_file    = `${job_dir}/result.json`;
let features_file  = `${job_dir}/features.json`;

let result_content = exec("powershell", [
    "-NoProfile", "-Command",
    `if (Test-Path '${result_file}') { Get-Content '${result_file}' -Raw } else { '{}' }`
]);

let features_content = exec("powershell", [
    "-NoProfile", "-Command",
    `if (Test-Path '${features_file}') { Get-Content '${features_file}' -Raw } else { '{}' }`
]);

// ============================================================================
// 构建返回
// ============================================================================

let instruction = `MT4 特征计算完成（job_id=${job_id}）：\n\n`;
instruction += `**result.json**\n\`\`\`json\n${result_content}\n\`\`\`\n\n`;
instruction += `**features.json**\n\`\`\`json\n${features_content}\n\`\`\``;

return #{
    success: true,
    job_id: job_id,
    job_dir: job_dir,
    result: result_content,
    features: features_content,
    instruction: instruction
};
