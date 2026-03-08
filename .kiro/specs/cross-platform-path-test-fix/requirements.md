# Requirements Document: Cross-Platform Path Test Fix

## Introduction

本文档定义修复跨平台路径测试失败的需求。当前测试在 Windows 环境下失败，因为测试代码对路径分隔符做了平台相关的字符串硬编码断言。

失败用例：
- `crates/tools/src/ocr.rs:428` - `test_resolve_path`
- `crates/tools/src/video_process.rs:584` - `test_resolve_path`

根本原因：实现使用 `PathBuf::display()` 或 `to_string_lossy()`，在 Windows 下返回 `\` 分隔符，但测试固定断言 `/` 分隔符。

## Glossary

- **PathBuf**: Rust 标准库的跨平台路径类型
- **Path Separator**: 路径分隔符，Unix/Linux 使用 `/`，Windows 使用 `\`
- **resolve_path**: 将相对路径解析为绝对路径的函数
- **Cross-Platform Test**: 在不同操作系统上都能通过的测试
- **Path Equivalence**: 路径语义等价，不依赖字符串字面量比较

## Requirements

### Requirement 1: Platform-Independent Path Assertions

**User Story:** 作为测试维护者，我希望路径断言不依赖平台特定的字符串格式，以确保测试在所有平台上都能通过。

#### Acceptance Criteria

1. WHEN 测试断言路径相等性，THE 测试 SHALL 使用 `PathBuf` 等价比较而非字符串字面量比较。
2. WHEN `resolve_path` 返回路径字符串，THE 测试 SHALL 将其转换为 `PathBuf` 后再比较。
3. WHEN 测试在 Windows 环境运行，THE 路径断言 SHALL 不因分隔符差异而失败。
4. WHEN 测试在 Unix/Linux 环境运行，THE 路径断言 SHALL 保持原有行为。
5. THE 修复 SHALL 不改变 `resolve_path` 函数的实现逻辑。

### Requirement 2: OCR Tool Path Test Fix

**User Story:** 作为 OCR 工具维护者，我希望 `test_resolve_path` 在所有平台上都能通过。

#### Acceptance Criteria

1. WHEN 测试绝对路径解析（`/abs/path.png`），THE 测试 SHALL 使用 `PathBuf` 比较。
2. WHEN 测试相对路径解析（`rel/path.png`），THE 测试 SHALL 使用 `PathBuf` 比较。
3. WHEN 测试在 Windows 运行，THE 测试 SHALL 验证路径语义等价（通过 `PathBuf` 比较），而非字符串字面量。
4. THE 测试 SHALL 验证路径解析的语义正确性，而非字符串格式。
5. THE 修复后测试 SHALL 在 `cargo test -p blockcell-tools` 中通过。

### Requirement 3: Video Process Tool Path Test Fix

**User Story:** 作为视频处理工具维护者，我希望 `test_resolve_path` 在所有平台上都能通过。

#### Acceptance Criteria

1. WHEN 测试绝对路径解析（`/absolute/path.mp4`），THE 测试 SHALL 使用 `PathBuf` 比较。
2. WHEN 测试相对路径解析（`relative.mp4`），THE 测试 SHALL 使用 `PathBuf` 比较。
3. WHEN 测试在 Windows 运行，THE 测试 SHALL 验证路径语义等价（通过 `PathBuf` 比较），而非字符串字面量。
4. THE 测试 SHALL 验证路径解析的语义正确性，而非字符串格式。
5. THE 修复后测试 SHALL 在 `cargo test -p blockcell-tools` 中通过。

### Requirement 4: Documentation Update

**User Story:** 作为项目维护者，我希望状态文档反映最新的测试复核情况。

#### Acceptance Criteria

1. WHEN 白名单生效后测试可执行，THE `FINAL_STATUS.md` SHALL 更新"未复核"状态为"已复核"（交付项）。
2. WHEN 跨平台测试修复完成，THE `FINAL_STATUS.md` SHALL 更新说明跨平台测试修复的完成状态（交付项）。
3. THE 文档更新 SHALL 反映当前测试通过情况。
4. THE 文档更新 SHALL 作为交付项，不与功能验收混合。

### Requirement 5: Test Validation

**User Story:** 作为 QA，我希望确认修复后的测试在 Windows 和 Unix/Linux 环境下都能通过。

#### Acceptance Criteria

1. WHEN 在 Windows 环境运行 `cargo test -p blockcell-tools`，THE `test_resolve_path` 测试 SHALL 通过。
2. WHEN 在 Unix/Linux 环境运行 `cargo test -p blockcell-tools`，THE `test_resolve_path` 测试 SHALL 通过。
3. WHEN 在 Windows 环境运行 `cargo test -p blockcell-tools --release`，THE `test_resolve_path` 测试 SHALL 通过。
4. WHEN 在 Unix/Linux 环境运行 `cargo test -p blockcell-tools --release`，THE `test_resolve_path` 测试 SHALL 通过。
5. THE 跨平台验证 SHALL 提供可复核的双平台测试记录（Windows + Unix/Linux）作为验收证据；Unix/Linux 证据可来自原生 Linux、WSL2 或 CI（ubuntu-latest）。
6. THE 修复 SHALL 不引入新的测试失败（限定 `blockcell-tools` 包范围）。
7. THE 修复 SHALL 不改变 `resolve_path` 函数的运行时行为。
8. THE 全仓 release 测试通过（`cargo test --release`）作为额外目标，非主验收条件。

### Requirement 6: Code Quality and Maintainability

**User Story:** 作为代码审查者，我希望修复方案清晰、可维护，并遵循 Rust 最佳实践。

#### Acceptance Criteria

1. THE 测试代码 SHALL 使用 `std::path::PathBuf` 进行路径比较。
2. THE 测试代码 SHALL 避免硬编码平台特定的路径分隔符。
3. THE 修复 SHALL 保持测试代码的可读性。
4. THE 修复 SHALL 添加注释说明跨平台路径比较的原因（如需要）。
5. THE 代码 SHALL 通过 `cargo clippy -p blockcell-tools --tests` 检查。

### Requirement 7: Regression Prevention

**User Story:** 作为项目维护者，我希望防止未来再次引入类似的平台特定测试问题。

#### Acceptance Criteria

1. THE 修复 SHALL 作为跨平台测试的参考示例。
2. THE 文档 SHALL 记录跨平台路径测试的最佳实践（可选）。
3. THE 修复 SHALL 不影响其他测试的通过率。
4. THE 修复 SHALL 在设计文档中说明跨平台测试策略。
