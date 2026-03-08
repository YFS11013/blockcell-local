# Design Document: Cross-Platform Path Test Fix

## Overview

本设计用于修复跨平台路径测试失败问题。当前 `ocr.rs` 和 `video_process.rs` 中的 `test_resolve_path` 测试在 Windows 环境下失败，因为测试使用字符串字面量断言路径，而 Windows 使用 `\` 分隔符，Unix/Linux 使用 `/` 分隔符。

失败用例：
- `crates/tools/src/ocr.rs:428` - `test_resolve_path`
- `crates/tools/src/video_process.rs:584` - `test_resolve_path`

根本原因：
- 实现使用 `PathBuf::display()` 或 `to_string_lossy()` 返回平台特定的路径字符串
- 测试使用 `assert_eq!` 比较字符串字面量，硬编码了 `/` 分隔符
- Windows 下路径包含 `\`，导致断言失败

## Goals

1. 修复 `ocr.rs` 和 `video_process.rs` 中的 `test_resolve_path` 测试，使其在所有平台上通过。
2. 使用 `PathBuf` 进行路径语义比较，而非字符串字面量比较。
3. 不改变 `resolve_path` 函数的实现逻辑和运行时行为。
4. 提供跨平台测试的参考示例。

## Non-Goals

1. 本次不修改 `resolve_path` 函数的实现。
2. 本次不重构路径处理逻辑。
3. 本次不修改其他模块的路径测试（除非发现类似问题）。

## Architecture

### Current Test Pattern (Problematic)

```rust
#[test]
fn test_resolve_path() {
    let ws = std::path::Path::new("/workspace");
    // ❌ 字符串字面量比较，平台相关
    assert_eq!(resolve_path("/abs/path.png", ws), "/abs/path.png");
    assert_eq!(resolve_path("rel/path.png", ws), "/workspace/rel/path.png");
}
```

问题：
- Windows 下 `resolve_path("rel/path.png", ws)` 返回 `C:\workspace\rel\path.png`（或类似格式）
- 测试期望 `/workspace/rel/path.png`
- 字符串不匹配，测试失败

### Proposed Test Pattern (Cross-Platform)

```rust
#[test]
fn test_resolve_path() {
    let ws = std::path::Path::new("/workspace");
    
    // ✅ PathBuf 语义比较，跨平台
    let result_abs = resolve_path("/abs/path.png", ws);
    assert_eq!(
        std::path::PathBuf::from(result_abs),
        std::path::PathBuf::from("/abs/path.png")
    );
    
    let result_rel = resolve_path("rel/path.png", ws);
    assert_eq!(
        std::path::PathBuf::from(result_rel),
        ws.join("rel/path.png")
    );
}
```

优势：
- 使用 `Path`/`PathBuf` 进行平台无关的路径比较，避免分隔符字面量断言
- 语义比较：验证路径是否指向同一位置
- 跨平台兼容

## Components and Interfaces

### 1. OCR Tool Test Fix

**文件**: `crates/tools/src/ocr.rs`

**当前测试**（第 424-428 行）：
```rust
#[test]
fn test_resolve_path() {
    let ws = std::path::Path::new("/workspace");
    assert_eq!(resolve_path("/abs/path.png", ws), "/abs/path.png");
    assert_eq!(resolve_path("rel/path.png", ws), "/workspace/rel/path.png");
}
```

**修复后测试**：
```rust
#[test]
fn test_resolve_path() {
    let ws = std::path::Path::new("/workspace");
    
    // Test absolute path resolution
    let result_abs = resolve_path("/abs/path.png", ws);
    assert_eq!(
        std::path::PathBuf::from(result_abs),
        std::path::PathBuf::from("/abs/path.png"),
        "Absolute path should remain unchanged"
    );
    
    // Test relative path resolution
    let result_rel = resolve_path("rel/path.png", ws);
    assert_eq!(
        std::path::PathBuf::from(result_rel),
        ws.join("rel/path.png"),
        "Relative path should be joined with workspace"
    );
}
```

### 2. Video Process Tool Test Fix

**文件**: `crates/tools/src/video_process.rs`

**当前测试**（第 580-584 行）：
```rust
#[test]
fn test_resolve_path() {
    let ctx = ToolContext { /* ... */ };
    assert_eq!(resolve_path(&ctx, "/absolute/path.mp4"), "/absolute/path.mp4");
    assert_eq!(resolve_path(&ctx, "relative.mp4"), "/tmp/workspace/relative.mp4");
}
```

**修复后测试**：
```rust
#[test]
fn test_resolve_path() {
    let ctx = ToolContext {
        workspace: std::path::PathBuf::from("/tmp/workspace"),
        // ... other fields
    };
    
    // Test absolute path resolution
    let result_abs = resolve_path(&ctx, "/absolute/path.mp4");
    assert_eq!(
        std::path::PathBuf::from(result_abs),
        std::path::PathBuf::from("/absolute/path.mp4"),
        "Absolute path should remain unchanged"
    );
    
    // Test relative path resolution
    let result_rel = resolve_path(&ctx, "relative.mp4");
    assert_eq!(
        std::path::PathBuf::from(result_rel),
        ctx.workspace.join("relative.mp4"),
        "Relative path should be joined with workspace"
    );
}
```

### 3. Test Strategy

**跨平台验证**：
- 在 Windows 环境运行 `cargo test -p blockcell-tools`
- 在 Unix/Linux 环境运行 `cargo test -p blockcell-tools`
- 在两个平台运行 `cargo test -p blockcell-tools --release`
- 提供 Windows + Unix/Linux 双平台可复核测试记录作为验收证据（Unix/Linux 可为原生 Linux、WSL2 或 CI）

**验证点**：
1. 绝对路径解析：`/abs/path` 应保持不变
2. 相对路径解析：`rel/path` 应与 workspace 拼接
3. 路径语义等价：使用 `PathBuf` 比较，忽略分隔符差异

## Data Models

无需修改数据模型。测试修复仅涉及断言方式的改变。

## Correctness Properties

*属性是一个特征或行为，应该在系统的所有有效执行中保持为真——本质上是关于系统应该做什么的正式陈述。属性作为人类可读规范和机器可验证正确性保证之间的桥梁。*

### Property 1: Absolute Path Preservation

*对于*以 `/` 开头的绝对路径 `p`（OCR 还支持 `~` 开头的路径）和工作空间 `ws`，`resolve_path(p, ws)` 返回的路径应与 `p` 语义等价（通过 `PathBuf` 比较）。

**Validates: Requirements 1.1, 2.1, 3.1**

### Property 2: Relative Path Resolution

*对于*不以 `/` 或 `~` 开头的相对路径 `p` 和工作空间 `ws`，`resolve_path(p, ws)` 返回的路径应与 `ws.join(p)` 语义等价（通过 `PathBuf` 比较）。

**Validates: Requirements 1.2, 2.2, 3.2**

### Property 3: Platform Independence

*对于*本次测试覆盖的路径形态（`/...` 绝对路径、相对路径，及 OCR 的 `~/...` 路径）和工作空间 `ws`，在 Windows 和 Unix/Linux 平台上，`resolve_path(p, ws)` 的语义结果应一致（通过 `PathBuf` 比较）。

**Validates: Requirements 1.3, 1.4, 5.1, 5.2**

### Property 4: Implementation Invariance

*对于*本次测试覆盖的路径形态和工作空间 `ws`，修复前后 `resolve_path(p, ws)` 的运行时行为应保持不变。

**Validates: Requirements 1.5, 5.7**

## Error Handling

本次修复不涉及错误处理逻辑的改变。测试修复仅改变断言方式，不影响 `resolve_path` 函数的错误处理。

## Testing Strategy

### Unit Tests

修复两个现有测试：
1. `crates/tools/src/ocr.rs::tests::test_resolve_path`
2. `crates/tools/src/video_process.rs::tests::test_resolve_path`

修复方式：
- 将 `assert_eq!(resolve_path(...), "expected_string")` 改为 `assert_eq!(PathBuf::from(resolve_path(...)), PathBuf::from("expected_string"))`
- 添加描述性错误消息
- 保持测试逻辑不变

### Property-Based Tests

本次修复不添加新的属性测试。现有单元测试足以验证跨平台行为。

### Cross-Platform Validation

**验证步骤**：
1. 在 Windows 环境运行：
   - `cargo test -p blockcell-tools`
   - `cargo test -p blockcell-tools --release`
2. 在 Unix/Linux 环境运行：
   - `cargo test -p blockcell-tools`
   - `cargo test -p blockcell-tools --release`
3. 提供双平台可复核测试记录（Windows + Unix/Linux；Unix/Linux 可为原生 Linux、WSL2 或 CI）

**验收标准**：
- 所有 `test_resolve_path` 测试通过
- 不引入新的测试失败（限定 `blockcell-tools` 包范围）
- `cargo clippy -p blockcell-tools --tests` 通过

## Documentation Updates

### FINAL_STATUS.md

更新内容（交付项）：
1. 将"未复核"状态更新为"已复核"（白名单生效后）
2. 添加跨平台测试修复的完成状态说明
3. 反映当前测试通过情况

示例更新：
```markdown
## 跨平台测试修复

✅ **完成状态**: 已修复 `ocr.rs` 和 `video_process.rs` 中的路径测试
✅ **验证平台**: Windows（原生） + Unix/Linux（WSL2 或 CI）
✅ **测试通过**: `cargo test -p blockcell-tools` (debug + release)
```

## Migration Plan

无需迁移计划。本次修复仅涉及测试代码，不影响生产代码。

## Acceptance Checklist

1. `ocr.rs::test_resolve_path` 在 Windows 和 Unix/Linux 上通过
2. `video_process.rs::test_resolve_path` 在 Windows 和 Unix/Linux 上通过
3. 测试使用 `PathBuf` 进行路径比较
4. 不改变 `resolve_path` 函数的实现
5. `cargo clippy -p blockcell-tools --tests` 通过
6. 不引入新的测试失败（`blockcell-tools` 包范围）
7. 提供 Windows + Unix/Linux 双平台可复核测试记录
8. 更新 `FINAL_STATUS.md` 文档
