# Requirements Document: Rhai Context Variable Fix

## Introduction

本文档定义修复 Rhai 技能脚本上下文变量注入问题的需求。当前仓库中的脚本存在三种访问方式并存：

1. `ctx.user_input`（新脚本）
2. `context["user_input"]`（历史脚本）
3. 直接访问 `user_input`（历史脚本）

目标是建立统一规范（`ctx.*`）并保持兼容，避免出现 `Variable not found: ctx` / `Variable not found: context` / `Variable not found: user_input` 类错误。

## Glossary

- **Rhai Engine**: 执行 Rhai 脚本的运行时引擎
- **SkillDispatcher**: 负责调度和执行技能脚本的组件
- **Scope**: Rhai 执行作用域，用于注入脚本可访问变量
- **Context Object**: 注入到 Scope 的上下文对象，包含 `user_input` 和上下文键值
- **context_vars**: 调用方传入的上下文变量 `HashMap<String, serde_json::Value>`
- **Reserved Scope Keys**: 作用域保留键，至少包含 `ctx`、`context`、`user_input`

## Requirements

### Requirement 1: Canonical Context Object Injection

**User Story:** 作为技能脚本开发者，我希望通过统一的 `ctx` 对象访问上下文信息，以减少脚本写法分歧并提高可维护性。

#### Acceptance Criteria

1. WHEN SkillDispatcher 执行脚本前初始化上下文，THE SkillDispatcher SHALL 创建 Context Object。
2. WHEN Context Object 被创建，THE SkillDispatcher SHALL 将函数入参 `user_input` 放入 `ctx.user_input`。
3. WHEN Context Object 被创建，THE SkillDispatcher SHALL 将 `context_vars` 中的非保留键合并为 `ctx` 属性。
4. WHEN Scope 初始化，THE SkillDispatcher SHALL 注入变量名 `ctx`。
5. WHEN 脚本访问 `ctx.user_input`，THE Rhai Engine SHALL 返回与调用入参一致的字符串值。

### Requirement 2: Backward Compatibility

**User Story:** 作为系统维护者，我希望历史脚本在修复后无需立即改造即可继续运行。

#### Acceptance Criteria

1. WHEN Scope 初始化，THE SkillDispatcher SHALL 注入 `context`，且其值与 `ctx` 等价（同一上下文语义）。
2. WHEN Scope 初始化，THE SkillDispatcher SHALL 注入顶层变量 `user_input`。
3. WHEN Scope 初始化，THE SkillDispatcher SHALL 为 `context_vars` 的非保留键注入顶层变量（兼容旧脚本）。
4. WHEN 脚本分别访问 `ctx.user_input`、`context["user_input"]`、`user_input`，THE 三者返回值 SHALL 相同。
5. WHEN 旧脚本使用 `context[...]` 或 `user_input`，THE 运行结果 SHALL 不因本次修复而回归。

### Requirement 3: Reserved Keys and Conflict Handling

**User Story:** 作为平台开发者，我希望保留键不会被外部上下文覆盖，以保证系统行为可预测。

#### Acceptance Criteria

1. THE SkillDispatcher SHALL 定义 Reserved Scope Keys，至少包含 `ctx`、`context`、`user_input`。
2. WHEN `context_vars` 包含保留键，THE SkillDispatcher SHALL 忽略这些键的顶层注入。
3. WHEN `context_vars` 包含 `user_input`，THE `ctx.user_input` 与顶层 `user_input` SHALL 仍以函数入参为准。
4. WHEN 发生保留键冲突，THE SkillDispatcher SHALL 记录 `warn` 日志并继续执行。
5. THE 冲突处理 SHALL 不导致 panic。

### Requirement 4: Error Handling and Observability

**User Story:** 作为运维人员，我希望上下文构建与脚本执行失败时有可观测、可诊断的错误信息。

#### Acceptance Criteria

1. WHEN 脚本编译失败，THE SkillDispatcher SHALL 返回描述性 `Error::Skill`。
2. WHEN 脚本执行失败，THE SkillDispatcher SHALL 返回失败结果并包含错误信息。
3. IF 上下文构建流程出现内部错误（如未来引入可失败转换），THEN SkillDispatcher SHALL 记录错误并返回描述性 `Error::Skill`。
4. THE 日志 SHALL 至少包含 `user_input_len`、`context_vars_count`、`reserved_conflict_count`（如有）。
5. THE 实现 SHALL 不引入未处理 panic。

### Requirement 5: Existing Skills Validation

**User Story:** 作为 QA，我希望确认仓库现有技能脚本在修复后可正常运行。

#### Acceptance Criteria

1. WHEN 执行 `skills/ai_news/SKILL.rhai`，THE 脚本 SHALL 可访问 `ctx.user_input`。
2. WHEN 执行 `skills/weather/SKILL.rhai`，THE 脚本 SHALL 可访问 `ctx.user_input`。
3. WHEN 执行 `skills/stock_analysis/SKILL.rhai`，THE 脚本 SHALL 可访问 `ctx.user_input`。
4. WHEN 执行 `skills/app_control/SKILL.rhai`，THE 脚本 SHALL 可访问 `context[...]`。
5. WHEN 执行 `skills/camera/SKILL.rhai`，THE 脚本 SHALL 可访问顶层上下文变量（如 `device`、`format`）。
6. THE 上述验证 SHALL 不出现上下文变量缺失类错误。

### Requirement 6: Type Safety and Access Semantics

**User Story:** 作为技能脚本开发者，我希望上下文类型转换一致可预期。

#### Acceptance Criteria

1. WHEN Context Object 包含字符串值，THE 转换后 SHALL 在 Rhai 中以字符串可用。
2. WHEN Context Object 包含数字、布尔、数组、对象、null，THE 转换后 SHALL 保持语义一致。
3. WHEN key 为合法标识符，THE 脚本 MAY 使用 `ctx.key` 访问。
4. WHEN key 非合法标识符（如包含 `-`、空格），THE 脚本 SHALL 使用 `ctx["key-name"]` 访问。
5. WHEN SkillDispatcher 注入 `ctx` 或顶层兼容变量，THE 实现 SHALL 使用统一 JSON -> Rhai Dynamic 转换路径（如 `json_to_dynamic` 或等价函数）。
6. THE 转换规则 SHALL 在设计文档中明确，至少覆盖 `Object/Array/String/Number/Bool/Null` 六类。

### Requirement 7: Testing and Migration Policy

**User Story:** 作为项目维护者，我希望通过测试和渐进迁移稳定收敛到统一写法。

#### Acceptance Criteria

1. THE 项目 SHALL 为本特性增加单元测试与属性测试。
2. THE 属性测试 SHALL 每个属性至少执行 100 次迭代。
3. THE 新增脚本规范 SHALL 使用 `ctx.*`。
4. THE 兼容入口（`context`、顶层 `user_input`）在迁移期 SHALL 保留。
5. THE 文档 SHALL 明确 `ctx.*` 为规范写法。
