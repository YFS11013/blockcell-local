# Windows 代码完整性策略白名单申请

## 申请目的

为本机开发目录下由 `cargo test` 生成的测试二进制添加执行白名单，解除 Windows 代码完整性策略拦截。

## 问题现象

- **命令**: `cargo test -p blockcell-skills -- --list`
- **错误**: `os error 4551` - 应用程序控制策略已阻止此文件

## 阻断详情

- **时间**: 2026-03-08 07:55:48 (Asia/Shanghai)
- **事件日志**: `Microsoft-Windows-CodeIntegrity/Operational`
- **Event ID**: `3077`
- **策略名**: `VerifiedAndReputableDesktop`
- **被阻断文件**: `...\blockcell\target\debug\deps\blockcell_skills-*.exe`
- **签名状态**: NotSigned

## 建议白名单范围

按以下优先级放行：

1. **目录规则**（推荐）
   - `C:\Users\ireke\Documents\GitHub\blockcell\target\debug\deps\*.exe`

2. **进程+目录组合**
   - 父进程: `cargo.exe`（rustup stable toolchain）
   - 目标目录: `...\blockcell\target\debug\deps\*.exe`

3. **哈希规则**（不推荐）
   - 测试二进制哈希会频繁变化，需要批量更新方案

## 说明

- 当前会话为非提权上下文，无法直接修改 WDAC/App Control 策略
- 此拦截来自 Code Integrity 策略，而非普通 AppLocker 规则
- 若使用 Smart App Control，可能需要管理员策略侧放行或改用 CI/WSL 环境

## 取证命令

```powershell
# 查看最新拦截事件
$evt = Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' `
  -FilterXPath "*[System[(EventID=3077)]]" -MaxEvents 1

$evt | Select-Object TimeCreated, Id, RecordId | Format-List
[xml]$xml = $evt.ToXml()
$xml.Event.EventData.Data | ForEach-Object { "{0}={1}" -f $_.Name, $_.'#text' }
```
