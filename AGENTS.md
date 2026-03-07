# Local Collaboration Rules

Test workflow execution

These rules apply to my local workflow in this repository:

- **Upstream sync policy**: pull-only (`fetch` / `pull` / `rebase`), no `push`.
- **Change scope policy**: all modifications stay in my own local repo/branch/worktree.
- **Upstream safety policy**: do not submit local task changes to upstream remotes.

---

# 开发规则

## Git 工作流

### Remote 配置
```
origin   → blockcell-labs/blockcell (只拉取上游)
personal → YFS11013/blockcell-local (个人仓库)
```

### 分支策略
- 本地开发使用 `local/` 前缀分支
- 上游同步：只从 `origin/main` 拉取（fetch/pull），不推送到 origin
- 个人仓库：推送到 `personal` remote

### 操作步骤
```bash
# 1. 拉取上游最新代码
git fetch origin
git pull origin/main

# 2. 创建/切换到本地开发分支
git checkout -b local/dev

# 3. 开发修改...

# 4. 提交修改
git add <files>
git commit -m "描述"

# 5. 推送到个人仓库（不是 origin！）
git push personal
```

### 注意事项
- 禁止推送到 `origin`
- 允许推送到 `personal`
- Windows 特殊文件名（如 `nul`）需要手动处理

## Cron 任务

### 创建方式
1. **CLI**：`blockcell run msg "创建定时任务..."`
2. **API**：`POST http://localhost:18790/v1/cron/<id>/run`
3. **WebUI**：侧边栏 → 定时

### 触发（CLI 不工作）
- CLI `cron run` 未实现真正的触发逻辑
- 使用 Gateway API 触发任务

## 记忆系统

### Session 摘要自动保存
- 当会话消息数 ≥ 6 时自动生成摘要
- 保存到记忆库，标记为 `session_summary`
- 与 Ghost Agent 无关，是内置功能
