# Unix/Linux 平台测试复跑指南

## 当前状态

✅ Unix/Linux 平台已完成实测验证（WSL2 Ubuntu 24.04.4 LTS）。

已验证命令：
- `cargo test -p blockcell-tools -q` -> 370/370 通过
- `cargo test -p blockcell-tools --release -q` -> 370/370 通过

详细记录见：
- `unix-linux-test-results.md`
- `ci-matrix-summary.md`

## 复跑方式

### 方式 1：在当前 Windows 机器通过 WSL2 复跑（推荐）

```bash
wsl -e bash -lc "cd /mnt/c/Users/ireke/Documents/GitHub/blockcell && cargo test -p blockcell-tools -q"
wsl -e bash -lc "cd /mnt/c/Users/ireke/Documents/GitHub/blockcell && cargo test -p blockcell-tools --release -q"
```

### 方式 2：在原生 Linux 环境复跑

```bash
cd <repo-root>
cargo test -p blockcell-tools
cargo test -p blockcell-tools --release
```

### 方式 3：在 CI 复跑（可选补充证据）

在 `ubuntu-latest` 运行同样两条命令即可。CI 结果可作为补充，不是本次验收的唯一来源。

## 通过判定

- `ocr::tests::test_resolve_path` 通过
- `video_process::tests::test_resolve_path` 通过
- `blockcell-tools` 包级测试总数与失败数符合预期（当前为 370/370 通过）

## 结果回写要求

如重新复跑，请同步更新：
1. `unix-linux-test-results.md`（环境、命令、结果）
2. `ci-matrix-summary.md`（矩阵状态）
