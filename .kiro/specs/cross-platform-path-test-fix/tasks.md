# Implementation Plan: Cross-Platform Path Test Fix

## Overview

本实施计划用于修复跨平台路径测试失败问题。核心修复位于：
- `crates/tools/src/ocr.rs::tests::test_resolve_path`
- `crates/tools/src/video_process.rs::tests::test_resolve_path`

修复策略：将字符串字面量断言改为 `PathBuf` 语义比较，避免平台特定的路径分隔符问题。

## Tasks

- [x] 1. 修复 OCR 工具路径测试
  - [x] 1.1 修改 `crates/tools/src/ocr.rs::test_resolve_path`
    - 将绝对路径断言改为 `PathBuf` 比较
    - 将相对路径断言改为 `PathBuf` 比较
    - 添加描述性错误消息
    - 保持现有测试用例不变（包括 `~/...` 路径形态，如已存在）
    - _Requirements: 1.1, 1.2, 2.1, 2.2, 2.4_
  - [x] 1.2 验证 OCR 测试通过（当前平台）
    - 运行 `cargo test -p blockcell-tools ocr::tests::test_resolve_path`
    - 确认测试在当前平台通过
    - _Requirements: 2.5_

- [x] 2. 修复视频处理工具路径测试
  - [x] 2.1 修改 `crates/tools/src/video_process.rs::test_resolve_path`
    - 将绝对路径断言改为 `PathBuf` 比较
    - 将相对路径断言改为 `PathBuf` 比较
    - 添加描述性错误消息
    - _Requirements: 1.1, 1.2, 3.1, 3.2, 3.4_
  - [x] 2.2 验证视频处理测试通过（当前平台）
    - 运行 `cargo test -p blockcell-tools video_process::tests::test_resolve_path`
    - 确认测试在当前平台通过
    - _Requirements: 3.5_

- [x] 3. Checkpoint - 验证包级测试通过
  - 运行 `cargo test -p blockcell-tools`
  - 运行 `cargo test -p blockcell-tools --release`
  - 确认不引入新的测试失败
  - _Requirements: 5.3, 5.4, 5.6_

- [x] 4. 代码质量检查
  - [x] 4.1 运行 clippy 检查
    - 执行 `cargo clippy -p blockcell-tools --tests`
    - 确认命令返回码为 0；记录并跟踪非阻塞 warning（如有）
    - _Requirements: 6.5_
  - [x] 4.2 代码审查
    - 确认使用 `std::path::PathBuf` 进行路径比较
    - 确认避免硬编码平台特定的路径分隔符
    - 确认测试代码可读性良好
    - _Requirements: 6.1, 6.2, 6.3_

- [x] 5. 跨平台验证（必做，提供双平台可复核证据）
  - [x] 5.1 Windows 平台验证
    - 在 Windows 环境运行 `cargo test -p blockcell-tools`
    - 在 Windows 环境运行 `cargo test -p blockcell-tools --release`
    - 记录测试结果（截图或日志）
    - _Requirements: 5.1, 5.3, 5.5_
  - [x] 5.2 Unix/Linux 平台验证
    - 在 Unix/Linux 环境运行 `cargo test -p blockcell-tools`
    - 在 Unix/Linux 环境运行 `cargo test -p blockcell-tools --release`
    - 记录测试结果（截图或日志）
    - _Requirements: 5.2, 5.4, 5.5_
  - [x] 5.3 提供跨平台测试记录
    - 收集 Windows 与 Unix/Linux（原生 Linux / WSL2 / ubuntu-latest CI）的测试记录
    - 作为跨平台验收证据
    - _Requirements: 5.5_

- [x] 6. 文档更新
  - [x] 6.1 更新 `FINAL_STATUS.md`
    - 将"未复核"状态更新为"已复核"（如适用）
    - 添加跨平台测试修复的完成状态说明
    - 反映当前测试通过情况
    - _Requirements: 4.1, 4.2, 4.3_

- [x] 7. Final Checkpoint - 验证完整性
  - 确认所有修改的测试通过
  - 确认 `cargo clippy -p blockcell-tools --tests` 通过
  - 确认文档更新完成
  - 可选：运行 `cargo test --release` 验证全仓测试（额外目标）
  - _Requirements: 5.8_

## Notes

- 本计划聚焦于 `blockcell-tools` 包的路径测试修复
- 不修改 `resolve_path` 函数的实现逻辑
- 不新增测试用例，仅修改现有测试的断言方式（保持 OCR 的 `~/...` 路径形态等现有用例）
- 跨平台验证（任务 5）为必做任务，需提供 Windows + Unix/Linux 的可复核证据
- 全仓 release 测试（任务 7）作为额外目标，非主验收条件

## 修复示例

### OCR 工具测试修复

**修复前**：
```rust
#[test]
fn test_resolve_path() {
    let ws = std::path::Path::new("/workspace");
    assert_eq!(resolve_path("/abs/path.png", ws), "/abs/path.png");
    assert_eq!(resolve_path("rel/path.png", ws), "/workspace/rel/path.png");
}
```

**修复后**：
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

### 视频处理工具测试修复

**修复前**：
```rust
#[test]
fn test_resolve_path() {
    let ctx = ToolContext { /* ... */ };
    assert_eq!(resolve_path(&ctx, "/absolute/path.mp4"), "/absolute/path.mp4");
    assert_eq!(resolve_path(&ctx, "relative.mp4"), "/tmp/workspace/relative.mp4");
}
```

**修复后**：
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
