# Local Collaboration Rules

Test workflow execution

These rules apply to my local workflow in this repository:

- **Upstream sync policy**: sync from `origin/main` by `fetch`/`pull`/`rebase` only, no `push`.
- **Change scope policy**: all modifications stay in my own local repo/branch/worktree.
- **Upstream safety policy**: do not push to `origin`, do not open PR to upstream, do not merge into `origin/main`.

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
- 上游同步：只从 `origin/main` 拉取（fetch/pull/rebase），`origin` 仅用于同步上游
- 上游安全：不向 `origin` 推送，不向上游提 PR，不合并到 `origin/main`
- 个人仓库：仅推送到 `personal` remote（自用发布）

### 操作步骤
```bash
# 1. 创建/切换到本地开发分支
git checkout -b local/dev
# 或已存在时：
git checkout local/dev

# 2. 同步上游最新代码（只同步，不推送）
git fetch origin
git rebase origin/main

# 3. 开发修改...

# 4. 提交修改
git add <files>
git commit -m "描述"

# 5. 推送到个人仓库（rebase 后推荐）
git push --force-with-lease personal HEAD:main
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
