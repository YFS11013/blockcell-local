use blockcell_core::{Error, Result};
use rhai::{Dynamic, Engine, Map, Scope};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tracing::{debug, info, warn};

fn safe_char_boundary_prefix(s: &str, max_chars: i64) -> String {
    if max_chars <= 0 {
        return String::new();
    }
    let max_chars = max_chars as usize;
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    match s.char_indices().nth(max_chars) {
        Some((idx, _)) => s[..idx].to_string(),
        None => s.to_string(),
    }
}

fn safe_char_substring(s: &str, start: i64, len: i64) -> String {
    if len <= 0 {
        return String::new();
    }

    let start = start.max(0) as usize;
    let len = len.max(0) as usize;
    let chars: Vec<char> = s.chars().collect();
    if start >= chars.len() {
        return String::new();
    }
    chars[start..(start + len).min(chars.len())]
        .iter()
        .collect::<String>()
}

fn take_lines(s: &str, max_lines: i64) -> rhai::Array {
    if max_lines <= 0 {
        return Vec::new();
    }
    s.lines()
        .take(max_lines as usize)
        .map(|line| Dynamic::from(line.to_string()))
        .collect()
}

fn join_array_strings(items: rhai::Array, sep: String) -> String {
    let mut out = String::new();
    for (idx, item) in items.into_iter().enumerate() {
        if idx > 0 {
            out.push_str(&sep);
        }
        if item.is::<String>() {
            out.push_str(&item.into_string().unwrap_or_default());
        } else if item.is::<rhai::ImmutableString>() {
            out.push_str(item.cast::<rhai::ImmutableString>().as_str());
        } else {
            let json = dynamic_to_json(&item);
            match json {
                Value::String(s) => out.push_str(&s),
                other => out.push_str(&other.to_string()),
            }
        }
    }
    out
}

fn dynamic_len(val: Dynamic) -> i64 {
    if val.is_unit() {
        0
    } else if val.is::<String>() {
        val.into_string().unwrap_or_default().chars().count() as i64
    } else if val.is::<rhai::ImmutableString>() {
        val.cast::<rhai::ImmutableString>().chars().count() as i64
    } else if val.is::<rhai::Array>() {
        val.into_array().unwrap_or_default().len() as i64
    } else if val.is::<Map>() {
        val.try_cast::<Map>().map(|m| m.len() as i64).unwrap_or(0)
    } else {
        let json = dynamic_to_json(&val);
        match json {
            Value::String(s) => s.chars().count() as i64,
            Value::Array(arr) => arr.len() as i64,
            Value::Object(obj) => obj.len() as i64,
            Value::Null => 0,
            _ => 0,
        }
    }
}

/// Reserved scope keys that cannot be overridden by context_vars.
/// These keys are used for system-level context injection and must be protected.
const RESERVED_SCOPE_KEYS: &[&str] = &["ctx", "context", "user_input"];

/// Result of executing a skill's Rhai script.
#[derive(Debug, Clone)]
pub struct SkillDispatchResult {
    /// The final output value from the Rhai script.
    pub output: Value,
    /// Tool calls that were made during execution, in order.
    pub tool_calls: Vec<ToolCallRecord>,
    /// Whether the skill completed successfully.
    pub success: bool,
    /// Error message if the skill failed.
    pub error: Option<String>,
}

/// Record of a tool call made by a Rhai script.
#[derive(Debug, Clone)]
pub struct ToolCallRecord {
    pub tool_name: String,
    pub params: Value,
    pub result: Value,
    pub success: bool,
}

/// The SkillDispatcher executes SKILL.rhai scripts with tool-calling capabilities.
///
/// Architecture:
/// - Rhai scripts call `call_tool(name, params)` which executes tools inline
/// - The dispatcher uses a synchronous callback mechanism to execute tools
/// - Tool results are returned to the Rhai script as Dynamic values
pub struct SkillDispatcher;

impl SkillDispatcher {
    pub fn new() -> Self {
        Self
    }

    /// Build a unified context object for Rhai script execution.
    /// 
    /// This function creates a context object that:
    /// - Contains `user_input` as a field
    /// - Merges non-reserved keys from `context_vars`
    /// - Detects and logs reserved key conflicts
    /// 
    /// Returns:
    /// - The context object as a `serde_json::Value::Object`
    /// - A list of reserved keys that were found in `context_vars` (for logging)
    fn build_context_object(
        user_input: &str,
        context_vars: &HashMap<String, Value>,
    ) -> (Value, Vec<String>) {
        let mut ctx_map = serde_json::Map::new();
        
        // Always set user_input from the function parameter
        ctx_map.insert("user_input".to_string(), Value::String(user_input.to_string()));
        
        let mut reserved_conflicts = Vec::new();
        
        // Merge non-reserved keys from context_vars
        for (key, val) in context_vars {
            if RESERVED_SCOPE_KEYS.contains(&key.as_str()) {
                // Reserved key conflict detected
                reserved_conflicts.push(key.clone());
                continue;
            }
            ctx_map.insert(key.clone(), val.clone());
        }
        
        (Value::Object(ctx_map), reserved_conflicts)
    }

    /// Execute a SKILL.rhai script with a synchronous tool executor.
    /// Tool calls are executed inline during script execution.
    pub fn execute_sync<F>(
        &self,
        script: &str,
        user_input: &str,
        context_vars: HashMap<String, Value>,
        tool_executor: F,
    ) -> Result<SkillDispatchResult>
    where
        F: Fn(&str, Value) -> Result<Value> + Send + Sync + 'static,
    {
        let tool_calls: Arc<Mutex<Vec<ToolCallRecord>>> = Arc::new(Mutex::new(Vec::new()));
        let output: Arc<Mutex<Option<Value>>> = Arc::new(Mutex::new(None));
        let executor = Arc::new(tool_executor);

        let mut engine = Engine::new();
        engine.set_max_string_size(1_000_000);
        engine.set_max_array_size(10_000);
        engine.set_max_map_size(10_000);
        engine.set_max_call_levels(64);
        engine.set_max_expr_depths(64, 64);

        // Register call_tool(name, params) -> Dynamic
        {
            let tc = tool_calls.clone();
            let exec = executor.clone();
            engine.register_fn("call_tool", move |name: String, params: Map| -> Dynamic {
                let params_json = map_to_json(&params);
                debug!(tool = %name, "SKILL.rhai calling tool");

                match exec(&name, params_json.clone()) {
                    Ok(result) => {
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: name,
                            params: params_json,
                            result: result.clone(),
                            success: true,
                        });
                        json_to_dynamic(&result)
                    }
                    Err(e) => {
                        let err_val = serde_json::json!({"error": format!("{}", e)});
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: name,
                            params: params_json,
                            result: err_val.clone(),
                            success: false,
                        });
                        json_to_dynamic(&err_val)
                    }
                }
            });
        }

        // Register call_tool with string params (JSON string)
        {
            let tc = tool_calls.clone();
            let exec = executor.clone();
            engine.register_fn(
                "call_tool_json",
                move |name: String, params_str: String| -> Dynamic {
                    let params_json: Value = serde_json::from_str(&params_str)
                        .unwrap_or(Value::Object(serde_json::Map::new()));
                    debug!(tool = %name, "SKILL.rhai calling tool (JSON)");

                    match exec(&name, params_json.clone()) {
                        Ok(result) => {
                            tc.lock().unwrap().push(ToolCallRecord {
                                tool_name: name,
                                params: params_json,
                                result: result.clone(),
                                success: true,
                            });
                            json_to_dynamic(&result)
                        }
                        Err(e) => {
                            let err_val = serde_json::json!({"error": format!("{}", e)});
                            tc.lock().unwrap().push(ToolCallRecord {
                                tool_name: name,
                                params: params_json,
                                result: err_val.clone(),
                                success: false,
                            });
                            json_to_dynamic(&err_val)
                        }
                    }
                },
            );
        }

        // Register set_output(value) — sets the final output
        {
            let out = output.clone();
            engine.register_fn("set_output", move |val: Dynamic| {
                let json_val = dynamic_to_json(&val);
                *out.lock().unwrap() = Some(json_val);
            });
        }

        // Register set_output_json(json_string) — sets output from JSON string
        {
            let out = output.clone();
            engine.register_fn("set_output_json", move |json_str: String| {
                let val: Value = serde_json::from_str(&json_str).unwrap_or(Value::String(json_str));
                *out.lock().unwrap() = Some(val);
            });
        }

        // Register set_output_json(map) — sets output from a map directly
        {
            let out = output.clone();
            engine.register_fn("set_output_json", move |map: Map| {
                let json_val = map_to_json(&map);
                *out.lock().unwrap() = Some(json_val);
            });
        }

        // Register log(message) — debug logging from Rhai
        engine.register_fn("log", |msg: String| {
            info!(source = "SKILL.rhai", "{}", msg);
        });

        // Register log_warn(message) — warning from Rhai
        engine.register_fn("log_warn", |msg: String| {
            warn!(source = "SKILL.rhai", "{}", msg);
        });

        // Register type-check helpers so scripts can call val.is_map(), val.is_string(), etc.
        engine.register_fn("is_map", |val: Dynamic| -> bool { val.is::<Map>() });
        engine.register_fn("is_string", |val: Dynamic| -> bool { val.is::<String>() });
        engine.register_fn("is_array", |val: Dynamic| -> bool { val.is::<rhai::Array>() });

        // Register is_error(result) — check if a tool result is an error
        engine.register_fn("is_error", |val: Map| -> bool { val.contains_key("error") });

        // Register is_map(value) — check if a value is a map/object
        engine.register_fn("is_map", |val: Dynamic| -> bool {
            val.is::<Map>()
        });

        // Register array.join(separator) — join array elements into a string
        engine.register_fn("join", |arr: rhai::Array, sep: &str| -> String {
            arr.iter()
                .map(|v| format!("{}", v))
                .collect::<Vec<_>>()
                .join(sep)
        });

        // Register string.starts_with(prefix) — check if string starts with prefix
        engine.register_fn("starts_with", |s: &str, prefix: &str| -> bool {
            s.starts_with(prefix)
        });

        // Register string.trim() — trim whitespace from string
        engine.register_fn("trim", |s: &str| -> String {
            s.trim().to_string()
        });

        // Register string.to_lower() — convert string to lowercase
        engine.register_fn("to_lower", |s: &str| -> String {
            s.to_lowercase()
        });

        // Register string.replace(from, to) — replace substring
        engine.register_fn("replace", |s: &str, from: &str, to: &str| -> String {
            s.replace(from, to)
        });

        // Register parse_int(string) — parse string to integer
        engine.register_fn("parse_int", |s: &str| -> i64 {
            s.parse::<i64>().unwrap_or(0)
        });

        // Register parse_int(i64) — identity function for integers
        engine.register_fn("parse_int", |n: i64| -> i64 {
            n
        });

        // Register parse_int(f64) — convert float to integer
        engine.register_fn("parse_int", |f: f64| -> i64 {
            f as i64
        });

        // Register string.match_regex(pattern) — match regex and return captures
        engine.register_fn("match_regex", |s: &str, pattern: &str| -> rhai::Array {
            use regex::Regex;
            match Regex::new(pattern) {
                Ok(re) => {
                    if let Some(captures) = re.captures(s) {
                        // Return all captured groups (excluding the full match at index 0)
                        captures.iter()
                            .skip(1)  // Skip the full match
                            .filter_map(|m| m.map(|m| Dynamic::from(m.as_str().to_string())))
                            .collect::<Vec<_>>()
                    } else {
                        Vec::new()
                    }
                }
                Err(_) => Vec::new(),
            }
        });

        // Register get_field(map, key) — safely get a field from a map
        engine.register_fn("get_field", |map: Map, key: String| -> Dynamic {
            map.get(key.as_str()).cloned().unwrap_or(Dynamic::UNIT)
        });

        // Register to_json(value) — convert a Dynamic to JSON string
        engine.register_fn("to_json", |val: Dynamic| -> String {
            let json = dynamic_to_json(&val);
            serde_json::to_string(&json).unwrap_or_default()
        });

        // Stable Rhai helper functions for common string/array operations.
        engine.register_fn("str_sub", |s: String, start: i64, len: i64| -> String {
            safe_char_substring(&s, start, len)
        });
        engine.register_fn("str_truncate", |s: String, max_chars: i64| -> String {
            safe_char_boundary_prefix(&s, max_chars)
        });
        engine.register_fn("str_lines", |s: String, max_lines: i64| -> rhai::Array {
            take_lines(&s, max_lines)
        });
        engine.register_fn("arr_join", |items: rhai::Array, sep: String| -> String {
            join_array_strings(items, sep)
        });
        engine.register_fn("len", |val: Dynamic| -> i64 { dynamic_len(val) });

        // Register from_json(string) — parse a JSON string to Dynamic
        engine.register_fn("from_json", |s: String| -> Dynamic {
            match serde_json::from_str::<Value>(&s) {
                Ok(v) => json_to_dynamic(&v),
                Err(_) => Dynamic::UNIT,
            }
        });

        // Register sleep_ms(ms) — sleep for milliseconds (for retry delays)
        engine.register_fn("sleep_ms", |ms: i64| {
            if ms > 0 && ms <= 10_000 {
                std::thread::sleep(std::time::Duration::from_millis(ms as u64));
            }
        });

        // Register timestamp() — current Unix timestamp
        engine.register_fn("timestamp", || -> i64 { chrono::Utc::now().timestamp() });

        // Register shorthand tool functions so SKILL.rhai can call exec(cmd) instead of
        // call_tool("exec", #{command: cmd}).  These are thin wrappers around call_tool.

        // exec(command) -> Dynamic
        {
            let tc = tool_calls.clone();
            let exec = executor.clone();
            engine.register_fn("exec", move |command: String| -> Dynamic {
                let params = serde_json::json!({"command": command});
                match exec("exec", params.clone()) {
                    Ok(result) => {
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: "exec".to_string(),
                            params,
                            result: result.clone(),
                            success: true,
                        });
                        json_to_dynamic(&result)
                    }
                    Err(e) => {
                        let err_val = serde_json::json!({"error": format!("{}", e)});
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: "exec".to_string(),
                            params,
                            result: err_val.clone(),
                            success: false,
                        });
                        json_to_dynamic(&err_val)
                    }
                }
            });
        }

        // web_search(query) -> Dynamic
        {
            let tc = tool_calls.clone();
            let exec = executor.clone();
            engine.register_fn("web_search", move |query: String| -> Dynamic {
                let params = serde_json::json!({"query": query});
                match exec("web_search", params.clone()) {
                    Ok(result) => {
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: "web_search".to_string(),
                            params,
                            result: result.clone(),
                            success: true,
                        });
                        json_to_dynamic(&result)
                    }
                    Err(e) => {
                        let err_val = serde_json::json!({"error": format!("{}", e)});
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: "web_search".to_string(),
                            params,
                            result: err_val.clone(),
                            success: false,
                        });
                        json_to_dynamic(&err_val)
                    }
                }
            });
        }

        // web_fetch(url) -> Dynamic
        {
            let tc = tool_calls.clone();
            let exec = executor.clone();
            engine.register_fn("web_fetch", move |url: String| -> Dynamic {
                let params = serde_json::json!({"url": url});
                match exec("web_fetch", params.clone()) {
                    Ok(result) => {
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: "web_fetch".to_string(),
                            params,
                            result: result.clone(),
                            success: true,
                        });
                        json_to_dynamic(&result)
                    }
                    Err(e) => {
                        let err_val = serde_json::json!({"error": format!("{}", e)});
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: "web_fetch".to_string(),
                            params,
                            result: err_val.clone(),
                            success: false,
                        });
                        json_to_dynamic(&err_val)
                    }
                }
            });
        }

        // read_file(path) -> Dynamic
        {
            let tc = tool_calls.clone();
            let exec = executor.clone();
            engine.register_fn("read_file", move |path: String| -> Dynamic {
                let params = serde_json::json!({"path": path});
                match exec("read_file", params.clone()) {
                    Ok(result) => {
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: "read_file".to_string(),
                            params,
                            result: result.clone(),
                            success: true,
                        });
                        json_to_dynamic(&result)
                    }
                    Err(e) => {
                        let err_val = serde_json::json!({"error": format!("{}", e)});
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: "read_file".to_string(),
                            params,
                            result: err_val.clone(),
                            success: false,
                        });
                        json_to_dynamic(&err_val)
                    }
                }
            });
        }

        // write_file(path, content) -> Dynamic
        {
            let tc = tool_calls.clone();
            let exec = executor.clone();
            engine.register_fn(
                "write_file",
                move |path: String, content: String| -> Dynamic {
                    let params = serde_json::json!({"path": path, "content": content});
                    match exec("write_file", params.clone()) {
                        Ok(result) => {
                            tc.lock().unwrap().push(ToolCallRecord {
                                tool_name: "write_file".to_string(),
                                params,
                                result: result.clone(),
                                success: true,
                            });
                            json_to_dynamic(&result)
                        }
                        Err(e) => {
                            let err_val = serde_json::json!({"error": format!("{}", e)});
                            tc.lock().unwrap().push(ToolCallRecord {
                                tool_name: "write_file".to_string(),
                                params,
                                result: err_val.clone(),
                                success: false,
                            });
                            json_to_dynamic(&err_val)
                        }
                    }
                },
            );
        }

        // http_request(url) -> Dynamic  (simple GET)
        {
            let tc = tool_calls.clone();
            let exec = executor.clone();
            engine.register_fn("http_request", move |url: String| -> Dynamic {
                let params = serde_json::json!({"url": url, "method": "GET"});
                match exec("http_request", params.clone()) {
                    Ok(result) => {
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: "http_request".to_string(),
                            params,
                            result: result.clone(),
                            success: true,
                        });
                        json_to_dynamic(&result)
                    }
                    Err(e) => {
                        let err_val = serde_json::json!({"error": format!("{}", e)});
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: "http_request".to_string(),
                            params,
                            result: err_val.clone(),
                            success: false,
                        });
                        json_to_dynamic(&err_val)
                    }
                }
            });
        }

        // message(content) -> Dynamic  (send outbound message)
        {
            let tc = tool_calls.clone();
            let exec = executor.clone();
            engine.register_fn("message", move |content: String| -> Dynamic {
                let params = serde_json::json!({"content": content});
                match exec("message", params.clone()) {
                    Ok(result) => {
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: "message".to_string(),
                            params,
                            result: result.clone(),
                            success: true,
                        });
                        json_to_dynamic(&result)
                    }
                    Err(e) => {
                        let err_val = serde_json::json!({"error": format!("{}", e)});
                        tc.lock().unwrap().push(ToolCallRecord {
                            tool_name: "message".to_string(),
                            params,
                            result: err_val.clone(),
                            success: false,
                        });
                        json_to_dynamic(&err_val)
                    }
                }
            });
        }

        // Compile
        let ast = engine
            .compile(script)
            .map_err(|e| Error::Skill(format!("SKILL.rhai compilation error: {}", e)))?;

        // Build unified context object
        let (ctx_obj, reserved_conflicts) = Self::build_context_object(user_input, &context_vars);
        
        // Log context information and conflicts
        if !reserved_conflicts.is_empty() {
            warn!(
                user_input_len = user_input.len(),
                context_vars_count = context_vars.len(),
                reserved_conflict_count = reserved_conflicts.len(),
                reserved_conflict_keys = ?reserved_conflicts,
                "Reserved key conflicts detected in context_vars"
            );
        } else {
            debug!(
                user_input_len = user_input.len(),
                context_vars_count = context_vars.len(),
                "Context object built successfully"
            );
        }
        
        let ctx_dynamic = json_to_dynamic(&ctx_obj);

        // Set up scope with unified context injection
        let mut scope = Scope::new();
        
        // Canonical entry point: ctx
        scope.push("ctx", ctx_dynamic.clone());
        
        // Compatibility alias: context
        scope.push("context", ctx_dynamic);
        
        // Top-level compatibility: user_input
        scope.push("user_input", user_input.to_string());
        
        // Top-level compatibility: non-reserved keys from context_vars
        for (key, val) in &context_vars {
            if RESERVED_SCOPE_KEYS.contains(&key.as_str()) {
                continue;
            }
            scope.push(key.as_str(), json_to_dynamic(val));
        }

        // Execute
        let result = engine.eval_ast_with_scope::<Dynamic>(&mut scope, &ast);

        let tc = tool_calls.lock().unwrap().clone();
        let out = output.lock().unwrap().clone();

        match result {
            Ok(value) => {
                let final_output = out.unwrap_or_else(|| dynamic_to_json(&value));
                Ok(SkillDispatchResult {
                    output: final_output,
                    tool_calls: tc,
                    success: true,
                    error: None,
                })
            }
            Err(e) => {
                let err_str = format!("{}", e);
                warn!(error = %err_str, "SKILL.rhai execution failed");
                Ok(SkillDispatchResult {
                    output: serde_json::json!({"error": err_str}),
                    tool_calls: tc,
                    success: false,
                    error: Some(err_str),
                })
            }
        }
    }
}

impl Default for SkillDispatcher {
    fn default() -> Self {
        Self::new()
    }
}

/// Convert a serde_json::Value to a Rhai Dynamic.
pub fn json_to_dynamic(val: &Value) -> Dynamic {
    match val {
        Value::Null => Dynamic::UNIT,
        Value::Bool(b) => Dynamic::from(*b),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Dynamic::from(i)
            } else if let Some(f) = n.as_f64() {
                Dynamic::from(f)
            } else {
                Dynamic::from(n.to_string())
            }
        }
        Value::String(s) => Dynamic::from(s.clone()),
        Value::Array(arr) => {
            let rhai_arr: Vec<Dynamic> = arr.iter().map(json_to_dynamic).collect();
            Dynamic::from(rhai_arr)
        }
        Value::Object(obj) => {
            let mut map = Map::new();
            for (k, v) in obj {
                map.insert(k.clone().into(), json_to_dynamic(v));
            }
            Dynamic::from(map)
        }
    }
}

/// Convert a Rhai Dynamic to serde_json::Value.
pub fn dynamic_to_json(val: &Dynamic) -> Value {
    if val.is_unit() {
        Value::Null
    } else if val.is::<bool>() {
        Value::Bool(val.as_bool().unwrap_or(false))
    } else if val.is::<i64>() {
        Value::Number(serde_json::Number::from(val.as_int().unwrap_or(0)))
    } else if val.is::<f64>() {
        if let Ok(f) = val.as_float() {
            serde_json::Number::from_f64(f)
                .map(Value::Number)
                .unwrap_or(Value::Null)
        } else {
            Value::Null
        }
    } else if val.is::<String>() {
        Value::String(val.clone().into_string().unwrap_or_default())
    } else if val.is::<rhai::Array>() {
        let arr = val.clone().into_array().unwrap_or_default();
        Value::Array(arr.iter().map(dynamic_to_json).collect())
    } else if val.is::<Map>() {
        match val.clone().try_cast::<Map>() {
            Some(m) => {
                let mut obj = serde_json::Map::new();
                for (k, v) in m {
                    obj.insert(k.to_string(), dynamic_to_json(&v));
                }
                Value::Object(obj)
            }
            None => Value::String(format!("{}", val)),
        }
    } else {
        Value::String(format!("{}", val))
    }
}

/// Convert a Rhai Map to serde_json::Value.
fn map_to_json(map: &Map) -> Value {
    let mut obj = serde_json::Map::new();
    for (k, v) in map {
        obj.insert(k.to_string(), dynamic_to_json(v));
    }
    Value::Object(obj)
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    // ============================================================================
    // Test Helper Functions
    // ============================================================================

    /// Load a SKILL.rhai script from the filesystem.
    /// 
    /// This helper function reads real skill scripts for integration testing,
    /// ensuring tests validate actual production code rather than simplified examples.
    /// 
    /// # Arguments
    /// * `path` - Relative path from workspace root (e.g., "skills/ai_news/SKILL.rhai")
    /// 
    /// # Returns
    /// * `String` - The script content
    /// 
    /// # Panics
    /// * If the file cannot be read (with a helpful error message)
    fn load_skill_script(path: &str) -> String {
        // Try multiple possible base paths to handle different test execution contexts
        let possible_paths = vec![
            path.to_string(),                                    // Direct path (when running from workspace root)
            format!("../../{}", path),                           // When running from crates/skills
            format!("../../../{}", path),                        // When running from target/debug
        ];
        
        for try_path in &possible_paths {
            if let Ok(content) = std::fs::read_to_string(try_path) {
                return content;
            }
        }
        
        // If all paths failed, try to find the workspace root
        let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
            .unwrap_or_else(|_| ".".to_string());
        
        // CARGO_MANIFEST_DIR points to crates/skills, so go up two levels to workspace root
        let workspace_root = std::path::Path::new(&manifest_dir)
            .parent()
            .and_then(|p| p.parent())
            .unwrap_or_else(|| std::path::Path::new("."));
        
        let full_path = workspace_root.join(path);
        
        std::fs::read_to_string(&full_path)
            .unwrap_or_else(|e| panic!(
                "Failed to load skill script '{}' (tried: {:?}, final: {:?}): {}", 
                path, possible_paths, full_path, e
            ))
    }

    // ============================================================================
    // Property-Based Test Generators
    // ============================================================================

    /// Generate valid Rhai identifiers: [A-Za-z_][A-Za-z0-9_]*
    /// Used for testing keys that can be accessed via `ctx.key` syntax
    fn valid_identifier() -> impl Strategy<Value = String> {
        prop::string::string_regex("[A-Za-z_][A-Za-z0-9_]{0,20}")
            .expect("valid identifier regex")
    }

    /// Generate non-identifier keys containing special characters
    /// These keys must be accessed via `ctx["key"]` syntax
    fn non_identifier_key() -> impl Strategy<Value = String> {
        prop::string::string_regex("[a-z]{1,5}-[a-z]{1,5}")
            .expect("non-identifier key regex")
    }

    // ============================================================================
    // Existing Unit Tests
    // ============================================================================

    #[test]
    fn test_simple_skill_script() {
        let dispatcher = SkillDispatcher::new();
        let result = dispatcher
            .execute_sync(
                r#"
            let msg = "Hello, " + user_input;
            set_output(msg);
            msg
            "#,
                "world",
                HashMap::new(),
                |_name, _params| Ok(serde_json::json!({"ok": true})),
            )
            .unwrap();

        assert!(result.success);
        assert_eq!(result.output, Value::String("Hello, world".to_string()));
    }

    #[test]
    fn test_tool_call_from_rhai() {
        let dispatcher = SkillDispatcher::new();
        let result = dispatcher
            .execute_sync(
                r#"
            let params = #{
                path: "/tmp/test.txt"
            };
            let result = call_tool("read_file", params);
            set_output(result);
            "#,
                "",
                HashMap::new(),
                |name, _params| {
                    assert_eq!(name, "read_file");
                    Ok(serde_json::json!({"content": "file contents here"}))
                },
            )
            .unwrap();

        assert!(result.success);
        assert_eq!(result.tool_calls.len(), 1);
        assert_eq!(result.tool_calls[0].tool_name, "read_file");
        assert!(result.tool_calls[0].success);
    }

    #[test]
    fn test_tool_error_handling() {
        let dispatcher = SkillDispatcher::new();
        let result = dispatcher
            .execute_sync(
                r#"
            let result = call_tool("bad_tool", #{});
            if is_error(result) {
                set_output("Tool failed, using fallback");
                log_warn("Tool call failed, degrading");
            }
            "#,
                "",
                HashMap::new(),
                |_name, _params| Err(Error::Tool("not found".to_string())),
            )
            .unwrap();

        assert!(result.success);
        assert_eq!(
            result.output,
            Value::String("Tool failed, using fallback".to_string())
        );
        assert_eq!(result.tool_calls.len(), 1);
        assert!(!result.tool_calls[0].success);
    }

    #[test]
    fn test_context_variables() {
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        ctx.insert("device".to_string(), serde_json::json!("front_camera"));
        ctx.insert("resolution".to_string(), serde_json::json!("1080p"));

        let result = dispatcher
            .execute_sync(
                r#"
            let msg = "Using " + device + " at " + resolution;
            set_output(msg);
            "#,
                "",
                ctx,
                |_name, _params| Ok(serde_json::json!({})),
            )
            .unwrap();

        assert!(result.success);
        assert_eq!(
            result.output,
            Value::String("Using front_camera at 1080p".to_string())
        );
    }

    #[test]
    fn test_multi_step_orchestration() {
        let dispatcher = SkillDispatcher::new();
        let result = dispatcher
            .execute_sync(
                r#"
            // Step 1: List devices
            let devices = call_tool("camera_list", #{});
            log("Found devices");

            // Step 2: Capture
            let capture = call_tool("camera_capture", #{
                device: "default",
                output_path: "/tmp/photo.jpg"
            });

            // Step 3: Check result
            if is_error(capture) {
                set_output(#{
                    success: false,
                    error: "Capture failed"
                });
            } else {
                set_output(#{
                    success: true,
                    path: "/tmp/photo.jpg",
                    device_count: 1
                });
            }
            "#,
                "帮我拍张照",
                HashMap::new(),
                |name, _params| match name {
                    "camera_list" => Ok(serde_json::json!({"devices": ["FaceTime HD Camera"]})),
                    "camera_capture" => {
                        Ok(serde_json::json!({"path": "/tmp/photo.jpg", "success": true}))
                    }
                    _ => Err(Error::Tool(format!("Unknown tool: {}", name))),
                },
            )
            .unwrap();

        assert!(result.success);
        assert_eq!(result.tool_calls.len(), 2);
        assert_eq!(result.tool_calls[0].tool_name, "camera_list");
        assert_eq!(result.tool_calls[1].tool_name, "camera_capture");
    }

    // ============================================================================
    // Property-Based Tests for Context Object
    // ============================================================================

    proptest! {
        /// **Property 1: Canonical Access**
        /// **Validates: Requirements 1.5**
        /// 
        /// For any user_input, ctx.user_input returns a value equal to the function parameter.
        #[test]
        fn prop_canonical_access(user_input in ".{0,512}") {
            let dispatcher = SkillDispatcher::new();
            let script = r#"
                let result = ctx.user_input;
                set_output(result);
            "#;
            
            let result = dispatcher.execute_sync(
                script,
                &user_input,
                HashMap::new(),
                |_name, _params| Ok(serde_json::json!({})),
            ).unwrap();
            
            prop_assert!(result.success);
            prop_assert_eq!(result.output, Value::String(user_input));
        }

        /// **Property 2: Compatibility Alias**
        /// **Validates: Requirements 2.1, 2.4**
        /// 
        /// For any user_input, context["user_input"] returns a value equal to the function parameter.
        #[test]
        fn prop_compatibility_alias(user_input in ".{0,512}") {
            let dispatcher = SkillDispatcher::new();
            let script = r#"
                let result = context["user_input"];
                set_output(result);
            "#;
            
            let result = dispatcher.execute_sync(
                script,
                &user_input,
                HashMap::new(),
                |_name, _params| Ok(serde_json::json!({})),
            ).unwrap();
            
            prop_assert!(result.success);
            prop_assert_eq!(result.output, Value::String(user_input));
        }

        /// **Property 3: Top-Level Compatibility**
        /// **Validates: Requirements 2.2, 2.4**
        /// 
        /// For any user_input, top-level user_input returns a value equal to the function parameter.
        #[test]
        fn prop_top_level_compatibility(user_input in ".{0,512}") {
            let dispatcher = SkillDispatcher::new();
            let script = r#"
                let result = user_input;
                set_output(result);
            "#;
            
            let result = dispatcher.execute_sync(
                script,
                &user_input,
                HashMap::new(),
                |_name, _params| Ok(serde_json::json!({})),
            ).unwrap();
            
            prop_assert!(result.success);
            prop_assert_eq!(result.output, Value::String(user_input));
        }

        /// **Property 4: Access Equivalence**
        /// **Validates: Requirements 2.4**
        /// 
        /// For any user_input, ctx.user_input, context["user_input"], and top-level user_input
        /// all return the same value.
        #[test]
        fn prop_access_equivalence(user_input in ".{0,512}") {
            let dispatcher = SkillDispatcher::new();
            let script = r#"
                let from_ctx = ctx.user_input;
                let from_context = context["user_input"];
                let from_top = user_input;
                set_output(#{
                    from_ctx: from_ctx,
                    from_context: from_context,
                    from_top: from_top
                });
            "#;
            
            let result = dispatcher.execute_sync(
                script,
                &user_input,
                HashMap::new(),
                |_name, _params| Ok(serde_json::json!({})),
            ).unwrap();
            
            prop_assert!(result.success);
            let output = result.output.as_object().unwrap();
            prop_assert_eq!(&output["from_ctx"], &Value::String(user_input.clone()));
            prop_assert_eq!(&output["from_context"], &Value::String(user_input.clone()));
            prop_assert_eq!(&output["from_top"], &Value::String(user_input.clone()));
            // All three should be equal
            prop_assert_eq!(&output["from_ctx"], &output["from_context"]);
            prop_assert_eq!(&output["from_ctx"], &output["from_top"]);
        }
    }

    // ============================================================================
    // Unit Tests for Reserved Key Conflict Handling
    // ============================================================================

    #[test]
    fn test_reserved_key_conflict_user_input() {
        // **Validates: Requirements 3.2, 3.3, 3.4**
        // When context_vars contains "user_input", it should not override the function parameter
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        ctx.insert("user_input".to_string(), serde_json::json!("SHOULD_BE_IGNORED"));
        
        let script = r#"
            // ctx.user_input should be the function parameter, not from context_vars
            let from_ctx = ctx.user_input;
            // Top-level user_input should also be the function parameter
            let from_top = user_input;
            set_output(#{
                from_ctx: from_ctx,
                from_top: from_top
            });
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "FUNCTION_PARAM",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        assert_eq!(output["from_ctx"], Value::String("FUNCTION_PARAM".to_string()));
        assert_eq!(output["from_top"], Value::String("FUNCTION_PARAM".to_string()));
    }

    #[test]
    fn test_reserved_key_conflict_ctx() {
        // **Validates: Requirements 3.2, 3.3, 3.4**
        // When context_vars contains "ctx", it should not override the system context object
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        ctx.insert("ctx".to_string(), serde_json::json!("SHOULD_BE_IGNORED"));
        ctx.insert("custom_key".to_string(), serde_json::json!("custom_value"));
        
        let script = r#"
            // ctx should be the system context object, not from context_vars
            let has_user_input = "user_input" in ctx;
            let has_custom = "custom_key" in ctx;
            set_output(#{
                has_user_input: has_user_input,
                has_custom: has_custom,
                custom_value: ctx.custom_key
            });
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "test_input",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        assert_eq!(output["has_user_input"], Value::Bool(true));
        assert_eq!(output["has_custom"], Value::Bool(true));
        assert_eq!(output["custom_value"], Value::String("custom_value".to_string()));
    }

    #[test]
    fn test_reserved_key_conflict_context() {
        // **Validates: Requirements 3.2, 3.3, 3.4**
        // When context_vars contains "context", it should not override the system context alias
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        ctx.insert("context".to_string(), serde_json::json!("SHOULD_BE_IGNORED"));
        
        let script = r#"
            // context should be the system context object, not from context_vars
            let from_context = context["user_input"];
            set_output(from_context);
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "test_input",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        assert_eq!(result.output, Value::String("test_input".to_string()));
    }

    #[test]
    fn test_three_access_methods() {
        // **Validates: Requirements 1.5, 2.1, 2.2, 2.4**
        // All three access methods should work and return the same value
        let dispatcher = SkillDispatcher::new();
        
        let script = r#"
            // Test all three access methods
            let from_ctx = ctx.user_input;
            let from_context = context["user_input"];
            let from_top = user_input;
            
            set_output(#{
                ctx_access: from_ctx,
                context_access: from_context,
                top_level_access: from_top,
                all_equal: (from_ctx == from_context) && (from_ctx == from_top)
            });
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "test_value",
            HashMap::new(),
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        assert_eq!(output["ctx_access"], Value::String("test_value".to_string()));
        assert_eq!(output["context_access"], Value::String("test_value".to_string()));
        assert_eq!(output["top_level_access"], Value::String("test_value".to_string()));
        assert_eq!(output["all_equal"], Value::Bool(true));
    }

    // ============================================================================
    // Property-Based Tests for Non-Identifier Key Access
    // ============================================================================

    proptest! {
        /// **Property 7: Non-Identifier Key Access**
        /// **Validates: Requirements 6.4**
        /// 
        /// For any non-identifier key (containing special characters like '-'),
        /// ctx["key"] should be accessible and return the correct value.
        #[test]
        fn prop_non_identifier_key_access(
            key in non_identifier_key(),
            value in ".{0,100}"
        ) {
            let dispatcher = SkillDispatcher::new();
            let mut ctx = HashMap::new();
            ctx.insert(key.clone(), serde_json::json!(value.clone()));
            
            // Use bracket notation to access non-identifier keys
            let script = format!(r#"
                let result = ctx["{}"];
                set_output(result);
            "#, key);
            
            let result = dispatcher.execute_sync(
                &script,
                "test",
                ctx,
                |_name, _params| Ok(serde_json::json!({})),
            ).unwrap();
            
            prop_assert!(result.success);
            prop_assert_eq!(result.output, Value::String(value));
        }
    }

    // ============================================================================
    // Unit Tests for Type Conversion Correctness
    // ============================================================================

    #[test]
    fn test_type_conversion_string() {
        // **Validates: Requirements 6.1, 6.2**
        // String values should be converted correctly
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        ctx.insert("str_key".to_string(), serde_json::json!("hello world"));
        
        let script = r#"
            let val = ctx.str_key;
            set_output(#{
                value: val,
                is_string: type_of(val) == "string"
            });
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        assert_eq!(output["value"], Value::String("hello world".to_string()));
        assert_eq!(output["is_string"], Value::Bool(true));
    }

    #[test]
    fn test_type_conversion_number_int() {
        // **Validates: Requirements 6.1, 6.2**
        // Integer values should be converted correctly
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        ctx.insert("int_key".to_string(), serde_json::json!(42));
        
        let script = r#"
            let val = ctx.int_key;
            set_output(#{
                value: val,
                is_int: type_of(val) == "i64"
            });
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        assert_eq!(output["value"], Value::Number(42.into()));
        assert_eq!(output["is_int"], Value::Bool(true));
    }

    #[test]
    fn test_type_conversion_number_float() {
        // **Validates: Requirements 6.1, 6.2**
        // Float values should be converted correctly
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        ctx.insert("float_key".to_string(), serde_json::json!(3.14));
        
        let script = r#"
            let val = ctx.float_key;
            set_output(#{
                value: val,
                is_float: type_of(val) == "f64"
            });
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        // Float comparison with tolerance
        if let Value::Number(n) = &output["value"] {
            let f = n.as_f64().unwrap();
            assert!((f - 3.14).abs() < 0.001);
        } else {
            panic!("Expected number value");
        }
        assert_eq!(output["is_float"], Value::Bool(true));
    }

    #[test]
    fn test_type_conversion_bool() {
        // **Validates: Requirements 6.1, 6.2**
        // Boolean values should be converted correctly
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        ctx.insert("bool_true".to_string(), serde_json::json!(true));
        ctx.insert("bool_false".to_string(), serde_json::json!(false));
        
        let script = r#"
            let val_true = ctx.bool_true;
            let val_false = ctx.bool_false;
            set_output(#{
                true_value: val_true,
                false_value: val_false,
                true_is_bool: type_of(val_true) == "bool",
                false_is_bool: type_of(val_false) == "bool"
            });
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        assert_eq!(output["true_value"], Value::Bool(true));
        assert_eq!(output["false_value"], Value::Bool(false));
        assert_eq!(output["true_is_bool"], Value::Bool(true));
        assert_eq!(output["false_is_bool"], Value::Bool(true));
    }

    #[test]
    fn test_type_conversion_array() {
        // **Validates: Requirements 6.1, 6.2**
        // Array values should be converted correctly
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        ctx.insert("arr_key".to_string(), serde_json::json!([1, 2, 3]));
        
        let script = r#"
            let val = ctx.arr_key;
            set_output(#{
                value: val,
                length: val.len(),
                first: val[0],
                is_array: type_of(val) == "array"
            });
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        assert_eq!(output["value"], serde_json::json!([1, 2, 3]));
        assert_eq!(output["length"], Value::Number(3.into()));
        assert_eq!(output["first"], Value::Number(1.into()));
        assert_eq!(output["is_array"], Value::Bool(true));
    }

    #[test]
    fn test_type_conversion_object() {
        // **Validates: Requirements 6.1, 6.2**
        // Object values should be converted correctly
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        ctx.insert("obj_key".to_string(), serde_json::json!({
            "name": "test",
            "count": 5
        }));
        
        let script = r#"
            let val = ctx.obj_key;
            set_output(#{
                name: val.name,
                count: val.count,
                is_map: type_of(val) == "map"
            });
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        assert_eq!(output["name"], Value::String("test".to_string()));
        assert_eq!(output["count"], Value::Number(5.into()));
        assert_eq!(output["is_map"], Value::Bool(true));
    }

    #[test]
    fn test_type_conversion_null() {
        // **Validates: Requirements 6.1, 6.2**
        // Null values should be converted correctly
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        ctx.insert("null_key".to_string(), Value::Null);
        
        let script = r#"
            let val = ctx.null_key;
            set_output(#{
                value: val,
                is_unit: type_of(val) == "()"
            });
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        assert_eq!(output["value"], Value::Null);
        assert_eq!(output["is_unit"], Value::Bool(true));
    }

    // ============================================================================
    // Error Handling and Observability Tests
    // ============================================================================

    #[test]
    fn test_compilation_error_returns_descriptive_error() {
        // **Validates: Requirements 4.1**
        // When script compilation fails, the dispatcher should return a descriptive Error::Skill
        let dispatcher = SkillDispatcher::new();
        
        // Invalid Rhai syntax - missing closing brace
        let invalid_script = r#"
            let x = #{
                key: "value"
            // Missing closing brace
        "#;
        
        let result = dispatcher.execute_sync(
            invalid_script,
            "test",
            HashMap::new(),
            |_name, _params| Ok(serde_json::json!({})),
        );
        
        // Should return an error
        assert!(result.is_err());
        
        // Error should be Error::Skill with descriptive message
        match result {
            Err(Error::Skill(msg)) => {
                assert!(msg.contains("compilation error"));
            }
            _ => panic!("Expected Error::Skill for compilation failure"),
        }
    }

    #[test]
    fn test_execution_error_returns_failure_result() {
        // **Validates: Requirements 4.2**
        // When script execution fails, the dispatcher should return a failure result with error info
        let dispatcher = SkillDispatcher::new();
        
        // Script that will cause a runtime error (division by zero)
        let script = r#"
            let x = 10;
            let y = 0;
            let z = x / y;  // Division by zero
            set_output(z);
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "test",
            HashMap::new(),
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        // Should return a result with success=false
        assert!(!result.success);
        
        // Should have an error message
        assert!(result.error.is_some());
        
        // Output should contain error information
        if let Value::Object(obj) = &result.output {
            assert!(obj.contains_key("error"));
        } else {
            panic!("Expected error object in output");
        }
    }

    #[test]
    fn test_undefined_variable_error() {
        // **Validates: Requirements 4.2, 4.5**
        // Accessing undefined variables should fail gracefully without panic
        let dispatcher = SkillDispatcher::new();
        
        let script = r#"
            let x = undefined_variable;  // This variable doesn't exist
            set_output(x);
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "test",
            HashMap::new(),
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        // Should fail gracefully
        assert!(!result.success);
        assert!(result.error.is_some());
        
        // Should not panic - we got here successfully
    }

    #[test]
    fn test_type_error_handling() {
        // **Validates: Requirements 4.2, 4.5**
        // Type errors should be handled gracefully
        let dispatcher = SkillDispatcher::new();
        
        let script = r#"
            let x = "string";
            let y = x + 5;  // Type mismatch: string + number
            set_output(y);
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "test",
            HashMap::new(),
            |_name, _params| Ok(serde_json::json!({})),
        );
        
        // Rhai actually handles string + number by converting number to string
        // So this should succeed with "string5"
        assert!(result.is_ok(), "Should handle type coercion gracefully");
        
        let result = result.unwrap();
        // Rhai coerces the number to string, so this should succeed
        assert!(result.success, "Rhai should coerce number to string in concatenation");
        assert_eq!(result.output, Value::String("string5".to_string()));
    }

    #[test]
    fn test_no_panic_on_complex_error() {
        // **Validates: Requirements 4.5**
        // Complex error scenarios should not cause panic
        let dispatcher = SkillDispatcher::new();
        
        let script = r#"
            // Multiple potential error sources
            let x = ctx.nonexistent_key;
            let y = x.nested.deeply.missing;
            let z = y[999];
            set_output(z);
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "test",
            HashMap::new(),
            |_name, _params| Ok(serde_json::json!({})),
        );
        
        // Should handle gracefully - either succeed or return error
        // The key is that we don't panic
        match result {
            Ok(_) => {}, // Fine
            Err(_) => {}, // Also fine
        }
    }

    #[test]
    fn test_logging_fields_present() {
        // **Validates: Requirements 4.4**
        // This test verifies that the logging code is present and structured correctly
        // Note: This test does not capture and verify actual log output. A proper implementation
        // would use tracing-subscriber's test utilities to capture and assert log fields.
        // For now, we verify the code path executes without error.
        
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        ctx.insert("test_key".to_string(), serde_json::json!("test_value"));
        
        let script = r#"
            set_output(ctx.test_key);
        "#;
        
        // Execute with context - this will trigger logging
        let result = dispatcher.execute_sync(
            script,
            "test_input",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        
        // The logging happens internally with the required fields:
        // - user_input_len
        // - context_vars_count
        // - reserved_conflict_count (when conflicts exist)
        // TODO: Use tracing-subscriber test utilities to capture and verify log fields
    }

    #[test]
    fn test_reserved_conflict_logging() {
        // **Validates: Requirements 3.4, 4.4**
        // When reserved key conflicts occur, they should be logged with proper fields
        // Note: This test does not capture and verify actual log output. A proper implementation
        // would use tracing-subscriber's test utilities to capture and assert log fields.
        // For now, we verify the behavior is correct (reserved keys are protected).
        
        let dispatcher = SkillDispatcher::new();
        let mut ctx = HashMap::new();
        // Add reserved keys to trigger conflict logging
        ctx.insert("ctx".to_string(), serde_json::json!("CONFLICT"));
        ctx.insert("context".to_string(), serde_json::json!("CONFLICT"));
        ctx.insert("user_input".to_string(), serde_json::json!("CONFLICT"));
        ctx.insert("normal_key".to_string(), serde_json::json!("normal_value"));
        
        let script = r#"
            // Should still work despite conflicts
            set_output(#{
                user_input: ctx.user_input,
                normal: ctx.normal_key
            });
        "#;
        
        // Execute - this will trigger warning log with conflict information
        let result = dispatcher.execute_sync(
            script,
            "test_input",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        
        // Verify that reserved keys were protected
        assert_eq!(output["user_input"], Value::String("test_input".to_string()));
        assert_eq!(output["normal"], Value::String("normal_value".to_string()));
        
        // The warning log with reserved_conflict_count and reserved_conflict_keys
        // was emitted during execution
        // TODO: Use tracing-subscriber test utilities to capture and verify log fields
    }

    #[test]
    fn test_successful_execution_no_error() {
        // **Validates: Requirements 4.1, 4.2**
        // Successful execution should not have error fields set
        let dispatcher = SkillDispatcher::new();
        
        let script = r#"
            set_output("success");
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "test",
            HashMap::new(),
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        assert!(result.error.is_none());
        assert_eq!(result.output, Value::String("success".to_string()));
    }

    // ============================================================================
    // Integration Tests for Existing Skills
    // ============================================================================

    #[test]
    fn test_existing_skill_stock_analysis_ctx() {
        // **Validates: Requirements 5.3**
        // skills/stock_analysis/SKILL.rhai uses ctx.user_input
        let dispatcher = SkillDispatcher::new();
        
        // Simplified version of stock_analysis script that tests ctx.user_input access
        let script = r#"
            let input = ctx.user_input;
            let stock_code = "";
            
            // Test that we can access ctx.user_input and extract stock code
            if input.contains("600519") {
                stock_code = "600519";
            }
            
            set_output(#{
                success: true,
                input_received: input,
                stock_code: stock_code,
                test: "stock_analysis_ctx_access"
            });
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "分析600519",
            HashMap::new(),
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        assert_eq!(output["success"], Value::Bool(true));
        assert_eq!(output["input_received"], Value::String("分析600519".to_string()));
        assert_eq!(output["stock_code"], Value::String("600519".to_string()));
    }

    #[test]
    fn test_existing_skill_app_control_context() {
        // **Validates: Requirements 5.4**
        // skills/app_control/SKILL.rhai uses context["user_input"] and context["app"]
        let dispatcher = SkillDispatcher::new();
        
        // Simplified version of app_control script that tests context[...] access
        let script = r#"
            let user_input = if "user_input" in context { context["user_input"] } else { "" };
            let target_app = if "app" in context { context["app"] } else { "Windsurf" };
            
            // Test that we can access context variables
            let intent = "screenshot";
            if user_input.contains("列出") {
                intent = "list_apps";
            }
            
            set_output(#{
                success: true,
                user_input: user_input,
                target_app: target_app,
                intent: intent,
                test: "app_control_context_access"
            });
        "#;
        
        let mut ctx = HashMap::new();
        ctx.insert("app".to_string(), serde_json::json!("VSCode"));
        
        let result = dispatcher.execute_sync(
            script,
            "列出应用",
            ctx,
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        assert!(result.success);
        let output = result.output.as_object().unwrap();
        assert_eq!(output["success"], Value::Bool(true));
        assert_eq!(output["user_input"], Value::String("列出应用".to_string()));
        assert_eq!(output["target_app"], Value::String("VSCode".to_string()));
        assert_eq!(output["intent"], Value::String("list_apps".to_string()));
    }

    #[test]
    fn test_existing_skill_camera_top_level_vars() {
        // **Validates: Requirements 5.5, 5.6**
        // skills/camera/SKILL.rhai uses top-level context variables (device, format, output_path)
        // This test loads the real SKILL.rhai file and verifies:
        // 1. Script executes successfully without variable missing errors
        // 2. Script can correctly access top-level variables device, format, output_path
        // 3. Script logic works with mocked camera_capture tool
        
        let dispatcher = SkillDispatcher::new();
        let script = load_skill_script("skills/camera/SKILL.rhai");
        
        // Provide context variables that the camera script expects
        let mut ctx = HashMap::new();
        ctx.insert("device".to_string(), serde_json::json!("1"));
        ctx.insert("format".to_string(), serde_json::json!("png"));
        ctx.insert("output_path".to_string(), serde_json::json!("/tmp/photo.png"));
        
        // Mock tool executor that simulates camera_capture responses
        let tool_executor = |name: &str, params: Value| -> Result<Value> {
            match name {
                "camera_capture" => {
                    let action = params.get("action").and_then(|v| v.as_str()).unwrap_or("capture");
                    
                    if action == "info" {
                        // Return camera info
                        Ok(serde_json::json!({
                            "devices": [
                                {"index": 0, "name": "FaceTime HD Camera"},
                                {"index": 1, "name": "External Webcam"}
                            ]
                        }))
                    } else {
                        // Return capture result
                        let device_index = params.get("device_index")
                            .and_then(|v| v.as_i64())
                            .unwrap_or(0);
                        let format = params.get("format")
                            .and_then(|v| v.as_str())
                            .unwrap_or("jpg");
                        let output_path = params.get("output_path")
                            .and_then(|v| v.as_str())
                            .unwrap_or("/tmp/capture.jpg");
                        
                        Ok(serde_json::json!({
                            "success": true,
                            "path": output_path,
                            "method": "camera",
                            "file_size_bytes": 1024000,
                            "resolution": "1920x1080",
                            "device_index": device_index,
                            "format": format
                        }))
                    }
                }
                _ => Err(Error::Tool(format!("Unknown tool: {}", name))),
            }
        };
        
        let result = dispatcher.execute_sync(
            &script,
            "拍照",
            ctx,
            tool_executor,
        ).unwrap();
        
        // Verify script executed successfully
        assert!(result.success, "Script should execute successfully");
        assert!(result.error.is_none(), "Should not have execution errors");
        
        // Verify the script accessed top-level variables correctly
        // The script should have made camera_capture calls
        assert!(!result.tool_calls.is_empty(), "Should have made tool calls");
        assert!(result.tool_calls.iter().any(|tc| tc.tool_name == "camera_capture"), 
                "Should have called camera_capture");
        
        // Verify output structure
        let output = result.output.as_object()
            .expect("Output should be an object");
        assert_eq!(output.get("success"), Some(&Value::Bool(true)), 
                   "Output should indicate success");
        assert!(output.contains_key("path"), "Output should contain path field");
        
        // Verify that the script used the context variables correctly
        // The output path should match what we provided
        if let Some(Value::String(path)) = output.get("path") {
            assert_eq!(path, "/tmp/photo.png", "Should use the provided output_path");
        }
    }

    #[test]
    fn test_no_context_variable_missing_errors() {
        // **Validates: Requirements 5.6**
        // Verify that no "Variable not found" errors occur for ctx, context, or user_input
        let dispatcher = SkillDispatcher::new();
        
        // Test all three access patterns in one script
        let script = r#"
            // This should not cause any "Variable not found" errors
            let from_ctx = ctx.user_input;
            let from_context = context["user_input"];
            let from_top = user_input;
            
            set_output(#{
                success: true,
                all_accessible: true,
                ctx_works: from_ctx.len() > 0,
                context_works: from_context.len() > 0,
                top_level_works: from_top.len() > 0
            });
        "#;
        
        let result = dispatcher.execute_sync(
            script,
            "test_input",
            HashMap::new(),
            |_name, _params| Ok(serde_json::json!({})),
        ).unwrap();
        
        // Should succeed without any variable not found errors
        assert!(result.success);
        assert!(result.error.is_none());
        
        let output = result.output.as_object().unwrap();
        assert_eq!(output["success"], Value::Bool(true));
        assert_eq!(output["all_accessible"], Value::Bool(true));
        assert_eq!(output["ctx_works"], Value::Bool(true));
        assert_eq!(output["context_works"], Value::Bool(true));
        assert_eq!(output["top_level_works"], Value::Bool(true));
    }

    #[test]
    fn test_all_skills_no_variable_errors() {
        // **Validates: Requirements 5.1, 5.2, 5.3, 5.4, 5.5, 5.6**
        // Table-driven test: batch validate all skill scripts
        // Ensures no "Variable not found: ctx/context/user_input" errors occur
        
        let dispatcher = SkillDispatcher::new();
        
        // Define test cases: (script_path, user_input, context_vars, expected_tools, skip_reason)
        let test_cases = vec![
            (
                "skills/ai_news/SKILL.rhai",
                "获取AI新闻",
                HashMap::new(),
                vec!["web_fetch"],
                None,
            ),
            (
                "skills/weather/SKILL.rhai",
                "北京天气",
                HashMap::new(),
                vec!["web_fetch"],
                None,
            ),
            (
                "skills/camera/SKILL.rhai",
                "拍照",
                {
                    let mut ctx = HashMap::new();
                    ctx.insert("device".to_string(), serde_json::json!("0"));
                    ctx.insert("format".to_string(), serde_json::json!("jpg"));
                    ctx.insert("output_path".to_string(), serde_json::json!("/tmp/test.jpg"));
                    ctx
                },
                vec!["camera_capture"],
                None,
            ),
            (
                "skills/stock_analysis/SKILL.rhai",
                "分析600519",
                HashMap::new(),
                vec!["finance_api"],
                None::<&str>,
            ),
            (
                "skills/app_control/SKILL.rhai",
                "列出应用",
                {
                    let mut ctx = HashMap::new();
                    ctx.insert("app".to_string(), serde_json::json!("VSCode"));
                    ctx
                },
                vec!["app_control"],
                None,
            ),
        ];
        
        // Run all test cases
        for (script_path, user_input, context_vars, expected_tools, skip_reason) in test_cases {
            println!("Testing skill: {}", script_path);
            
            if let Some(reason) = skip_reason {
                println!("⊘ Skipping {} - {}", script_path, reason);
                continue;
            }
            
            // Load the real script
            let script = load_skill_script(script_path);
            
            // Generic mock tool executor that returns success for any tool
            // Create a new closure for each test case to avoid lifetime issues
            let result = dispatcher.execute_sync(
                &script,
                user_input,
                context_vars,
                |name: &str, _params: Value| -> Result<Value> {
                    match name {
                        "web_fetch" => Ok(serde_json::json!({
                            "text": "Mock content for testing",
                            "url": "https://example.com"
                        })),
                        "camera_capture" => Ok(serde_json::json!({
                            "success": true,
                            "path": "/tmp/test.jpg",
                            "method": "camera",
                            "file_size_bytes": 1024
                        })),
                        "finance_api" => Ok(serde_json::json!({
                            "success": true,
                            "data": []
                        })),
                        "app_control" => Ok(serde_json::json!({
                            "success": true,
                            "apps": []
                        })),
                        _ => Ok(serde_json::json!({"success": true})),
                    }
                },
            );
            
            // Verify no compilation or execution errors
            let error_msg = if let Err(ref e) = result {
                format!("{:?}", e)
            } else {
                String::new()
            };
            
            assert!(result.is_ok(), 
                    "Script {} should compile successfully. Error: {}", script_path, error_msg);
            
            let result = result.unwrap();
            
            // Primary assertion: script must execute successfully
            // This ensures we're testing real compatibility, not just absence of specific errors
            assert!(result.success, 
                    "Script {} should execute successfully. Error: {:?}", 
                    script_path, result.error);
            
            // Secondary assertion: verify no context variable errors
            // (This should be redundant if success=true, but provides clear failure messages)
            if let Some(ref error) = result.error {
                assert!(!error.contains("Variable not found: ctx"),
                        "Script {} should not have 'Variable not found: ctx' error", script_path);
                assert!(!error.contains("Variable not found: context"),
                        "Script {} should not have 'Variable not found: context' error", script_path);
                assert!(!error.contains("Variable not found: user_input"),
                        "Script {} should not have 'Variable not found: user_input' error", script_path);
            }
            
            // Verify expected tools were called
            for expected_tool in expected_tools {
                assert!(result.tool_calls.iter().any(|tc| tc.tool_name == expected_tool),
                        "Script {} should have called tool '{}'", script_path, expected_tool);
            }
            
            println!("✓ Script {} passed validation", script_path);
        }
    }

    // ============================================================================
    // Property-Based Test: Context Vars Inclusion
    // ============================================================================

    proptest! {
        /// **Property 6: Context Vars Inclusion**
        /// **Validates: Requirements 1.3, 2.3**
        /// 
        /// For any non-reserved key in context_vars, it should be accessible via both
        /// ctx[key] and top-level key, with semantically equivalent values.
        #[test]
        fn prop_context_vars_inclusion(
            key in valid_identifier(),
            value in ".{0,100}"
        ) {
            // Skip reserved keys
            prop_assume!(!RESERVED_SCOPE_KEYS.contains(&key.as_str()));
            
            // Skip keys that start with underscore (Rhai has restrictions on these)
            // These keys can still be accessed via ctx["key"] but not as top-level identifiers
            prop_assume!(!key.starts_with('_'));
            
            let dispatcher = SkillDispatcher::new();
            let mut ctx = HashMap::new();
            ctx.insert(key.clone(), serde_json::json!(value.clone()));
            
            // Test both ctx[key] (bracket notation) and top-level key access
            // Use bracket notation for ctx to handle all valid identifiers
            let script = format!(r#"
                let from_ctx = ctx["{}"];
                let from_top = {};
                set_output(#{{
                    from_ctx: from_ctx,
                    from_top: from_top,
                    both_equal: from_ctx == from_top
                }});
            "#, key, key);
            
            let result = dispatcher.execute_sync(
                &script,
                "test",
                ctx,
                |_name, _params| Ok(serde_json::json!({})),
            ).unwrap();
            
            prop_assert!(result.success);
            let output = result.output.as_object().unwrap();
            prop_assert_eq!(&output["from_ctx"], &Value::String(value.clone()));
            prop_assert_eq!(&output["from_top"], &Value::String(value.clone()));
            prop_assert_eq!(&output["both_equal"], &Value::Bool(true));
        }
    }

    // ============================================================================
    // Property-Based Test: Reserved Key Protection
    // ============================================================================

    proptest! {
        /// **Property 5: Reserved Key Protection**
        /// **Validates: Requirements 3.2, 3.3**
        /// 
        /// When context_vars contains reserved keys, the system should not override
        /// reserved semantics and should log warnings.
        #[test]
        fn prop_reserved_key_protection(
            user_input_val in ".{0,100}",
            conflicting_value in ".{0,100}"
        ) {
            let dispatcher = SkillDispatcher::new();
            let mut ctx = HashMap::new();
            
            // Add all reserved keys with conflicting values
            ctx.insert("ctx".to_string(), serde_json::json!(conflicting_value.clone()));
            ctx.insert("context".to_string(), serde_json::json!(conflicting_value.clone()));
            ctx.insert("user_input".to_string(), serde_json::json!(conflicting_value.clone()));
            
            let script = r#"
                // Reserved keys should maintain their system semantics
                let ui_from_ctx = ctx.user_input;
                let ui_from_context = context["user_input"];
                let ui_from_top = user_input;
                
                set_output(#{
                    from_ctx: ui_from_ctx,
                    from_context: ui_from_context,
                    from_top: ui_from_top,
                    all_match_param: (ui_from_ctx == ui_from_context) && (ui_from_ctx == ui_from_top)
                });
            "#;
            
            let result = dispatcher.execute_sync(
                script,
                &user_input_val,
                ctx,
                |_name, _params| Ok(serde_json::json!({})),
            ).unwrap();
            
            prop_assert!(result.success);
            let output = result.output.as_object().unwrap();
            
            // All three should return the function parameter, not the conflicting value
            prop_assert_eq!(&output["from_ctx"], &Value::String(user_input_val.clone()));
            prop_assert_eq!(&output["from_context"], &Value::String(user_input_val.clone()));
            prop_assert_eq!(&output["from_top"], &Value::String(user_input_val.clone()));
            prop_assert_eq!(&output["all_match_param"], &Value::Bool(true));
        }
    }
}
