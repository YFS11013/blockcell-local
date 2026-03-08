# Windows 平台测试结果（最新复核）

## 测试环境

- 操作系统: Windows
- 平台: win32
- 测试日期: 2026-03-08

## 可执行验证（通过）

### Debug（lib）模式

命令：
```bash
cargo test -p blockcell-tools --lib
```

结果：
- ✅ 234/234 通过
- ✅ `ocr::tests::test_resolve_path` 通过
- ✅ `video_process::tests::test_resolve_path` 通过

## 受策略限制项（未通过）

### Debug（integration）模式

命令：
```bash
cargo test -p blockcell-tools --test mcp_manager -- --list
```

结果：
- ❌ 进程启动前被 WDAC 拦截
- 错误：`os error 4551`（应用程序控制策略已阻止此文件）
- 被拦截文件：`target\debug\deps\mcp_manager-*.exe`

### Release（lib）模式

命令：
```bash
cargo test -p blockcell-tools --lib --release
```

结果：
- ❌ 进程启动前被 WDAC 拦截
- 错误：`os error 4551`
- 被拦截文件：`target\release\deps\blockcell_tools-*.exe`

## 总结

- ✅ Windows 下 `--lib` 回归可执行且通过（234/234）
- ⚠️ Windows 下 integration/release 测试受 WDAC 策略拦截，属于环境限制而非代码回归
- ✅ 完整包级验收已在 WSL2 通过（见 `unix-linux-test-results.md`）
