# Design Document: Rhai Context Variable Fix

## Overview

本设计用于修复 Rhai 技能脚本上下文变量注入不一致问题，并建立统一访问规范。

当前仓库中脚本存在三种访问方式并存：

1. `ctx.user_input`（新脚本倾向）
2. `context["user_input"]`（历史脚本）
3. 顶层变量 `user_input`（历史脚本）

现有 `SkillDispatcher::execute_sync` 仅注入顶层变量，未注入 `ctx` / `context`，会触发变量缺失错误。

## Goals

1. `ctx.user_input` 成为规范入口并稳定可用。
2. 保持历史写法兼容，不造成脚本回归。
3. 明确保留键冲突策略，避免外部输入覆盖系统语义。
4. 通过可执行测试验证正确性与兼容性。

## Non-Goals

1. 本次不强制立即迁移所有历史脚本到 `ctx.*`。
2. 本次不重构 tool executor 与函数注册体系。
3. 本次不调整工具调用语义。

## Architecture

### Current

```text
SkillDispatcher::execute_sync
  ├─ 创建 Rhai Engine
  ├─ 注册函数 (call_tool, set_output, ...)
  ├─ 创建 Scope
  │   ├─ scope.push("user_input", ...)
  │   └─ scope.push(context_vars 的顶层键)
  └─ 执行脚本
      ├─ ctx.user_input  -> 失败（ctx 未注入）
      └─ context[...]    -> 失败（context 未注入）
```

### Proposed

```text
SkillDispatcher::execute_sync
  ├─ 创建 Rhai Engine & 注册函数
  ├─ 构建统一上下文对象 ctx_obj (rhai::Map / Dynamic::Map)
  │   ├─ ctx_obj["user_input"] = user_input_param
  │   └─ for (key, val) in context_vars:
  │       ├─ if key not in reserved_keys:
  │       │   └─ ctx_obj[key] = convert(val)
  │       └─ else:
  │           └─ warn reserved-key conflict and skip
  ├─ 创建 Scope
  │   ├─ scope.push("ctx", ctx_obj.clone())         // 规范入口
  │   ├─ scope.push("context", ctx_obj.clone())     // 兼容别名
  │   ├─ scope.push("user_input", user_input_param) // 顶层兼容变量
  │   └─ for (key, val) in context_vars:
  │       └─ if key not in reserved_keys:
  │           └─ scope.push(key, convert(val))      // 顶层兼容变量
  └─ 执行脚本
      ├─ ctx.user_input       -> 成功
      ├─ context["user_input"]-> 成功
      └─ user_input           -> 成功
```

## Components and Interfaces

### 1. Reserved Keys

保留键集合：

```rust
const RESERVED_SCOPE_KEYS: &[&str] = &["ctx", "context", "user_input"];
```

规则：

1. `context_vars` 中的保留键不参与顶层注入。
2. `context_vars["user_input"]` 不允许覆盖函数入参 `user_input`。
3. 发生冲突时记录 `warn`，不中断脚本执行。

### 2. Context Object 构建

在 Scope 初始化前构建 `ctx` 对象：

```rust
let mut ctx_map = serde_json::Map::new();
ctx_map.insert("user_input".to_string(), Value::String(user_input.to_string()));

let mut reserved_conflicts = Vec::new();

for (key, val) in &context_vars {
    if RESERVED_SCOPE_KEYS.contains(&key.as_str()) {
        reserved_conflicts.push(key.clone());
        continue;
    }
    ctx_map.insert(key.clone(), val.clone());
}
```

### 3. 类型转换

`ctx_map` 与顶层变量均使用统一转换路径：

```rust
fn convert(val: &serde_json::Value) -> rhai::Dynamic {
    json_to_dynamic(val)
}
```

转换语义：

1. `Object -> Map`
2. `Array -> Array`
3. `String -> String`
4. `Number -> i64/f64`
5. `Bool -> bool`
6. `Null -> UNIT`

### 4. Scope 注入顺序

```rust
let ctx_value = Value::Object(ctx_map);
let ctx_dynamic = json_to_dynamic(&ctx_value);

let mut scope = Scope::new();
scope.push("ctx", ctx_dynamic.clone());
scope.push("context", ctx_dynamic);
scope.push("user_input", user_input.to_string());

for (key, val) in &context_vars {
    if RESERVED_SCOPE_KEYS.contains(&key.as_str()) {
        continue;
    }
    scope.push(key.as_str(), json_to_dynamic(val));
}
```

## Correctness Properties

### Property 1: Canonical Access

对任意 `user_input`，`ctx.user_input` 返回值恒等于函数入参。

### Property 2: Compatibility Alias

对任意 `user_input`，`context["user_input"]` 返回值恒等于函数入参。

### Property 3: Top-Level Compatibility

对任意 `user_input`，顶层 `user_input` 返回值恒等于函数入参。

### Property 4: Access Equivalence

`ctx.user_input`、`context["user_input"]`、`user_input` 三种访问方式结果恒相等。

### Property 5: Reserved Key Protection

当 `context_vars` 包含保留键时，系统不会覆盖保留语义，并记录警告。

### Property 6: Context Vars Inclusion

任意非保留键 `k` 在 `ctx[k]` 与顶层 `k` 上均可访问，且语义等价于输入值。

### Property 7: Non-Identifier Key Access

当键名不满足标识符规则（如 `a-b`）时，`ctx["a-b"]` 可访问且值正确。

## Error Handling and Observability

1. 脚本 compile/eval 失败沿用现有错误返回语义。
2. 保留键冲突记录 `warn` 日志。
3. 日志建议包含：
4. `user_input_len`
5. `context_vars_count`
6. `reserved_conflict_count`
7. `reserved_conflict_keys`（可选）
8. 当前 `json_to_dynamic` 为确定性转换路径；若未来引入可失败转换（如 `try_json_to_dynamic`），失败时必须返回描述性 `Error::Skill`。

## Testing Strategy

### Unit Tests

在 `crates/skills/src/dispatcher.rs` 的 `#[cfg(test)]` 中新增：

1. `test_ctx_user_input_access`
2. `test_context_alias_access`
3. `test_top_level_user_input_access`
4. `test_access_equivalence`
5. `test_reserved_key_conflict_user_input`
6. `test_reserved_key_conflict_ctx_context`
7. `test_non_identifier_key_bracket_access`
8. `test_context_vars_top_level_compat`
9. `test_existing_skill_ai_news_ctx`
10. `test_existing_skill_weather_ctx`
11. `test_existing_skill_stock_analysis_ctx`
12. `test_existing_skill_app_control_context`
13. `test_existing_skill_camera_top_level_vars`

### Property-Based Tests

使用 `proptest`，每个属性至少 100 次。

生成策略：

1. `user_input`：`".{0,512}"`
2. 标识符键：`[A-Za-z_][A-Za-z0-9_]{0,20}`
3. 非标识符键：包含 `-`、空格等字符，仅用 `ctx["key"]` 访问
4. JSON 值：受限深度生成器，避免超深嵌套

## Migration Plan

### Phase 1 (当前版本)

1. 同时支持 `ctx`、`context`、顶层兼容变量。
2. 文档明确 `ctx.*` 是规范写法。

### Phase 2 (后续版本)

1. 对 `context` 与顶层兼容入口增加可选 deprecation warning（仅日志）。
2. 新脚本模板仅推荐 `ctx.*`。

### Phase 3 (可选)

1. 在确认迁移完成后评估是否移除兼容入口。
2. 若移除，需提前发布变更公告并提供迁移指引。

## Acceptance Checklist

1. 不再出现 `Variable not found: ctx` / `context` / `user_input`。
2. `ctx.user_input == context["user_input"] == user_input`。
3. 保留键冲突不会覆盖系统语义。
4. 现有技能脚本回归通过。
5. 单元测试与属性测试均通过。
