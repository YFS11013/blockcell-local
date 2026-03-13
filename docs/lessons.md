# 开发经验教训（整理版）

## 文档状态

- 范围：当前聚焦 `domain_experts/forex` 相关开发与验收经验
- 目标：沉淀可复用工程规则，避免重复踩坑
- 版本：`v2026-03-12`
- 说明：详细过程证据已下沉到各模块文档，本文件只保留“结论 + 规则 + 入口”

## 变更记录（只追加一行）

| 日期 | 操作人 | 变更摘要 |
|------|--------|----------|
| 2026-03-12 | Codex | 重构为整理版（时间线+规则+检查清单+证据入口），并建立变更记录机制 |

## 时间线索引

| 日期 | 主题 | 结果 |
|------|------|------|
| 2026-03-09 | MT4 EA 运行时安全、参数解析、风险边界问题 | 完成多项高优先级修复 |
| 2026-03-10 | MT4 EA 静态审查多轮修复（11.5~11.7） | 完成时序、参数解析、调用签名等关键修复 |
| 2026-03-10 | Blockcell Skill 静态审查多轮修复 | 修正工具调用、Cron 协议、时间算法、文档/API 对齐 |
| 2026-03-11 | Task 14 回测与实盘一致性验证 | 证据链形成，关键路径通过 |
| 2026-03-11 | Task 15 Final Checkpoint 验收 | 最终验收通过 |

## 核心经验（按主题）

### 1) 参数契约必须“硬失败”

- 反模式：
  - `tp_levels/tp_ratios` 长度不一致时截断后继续执行
  - 必填字段缺失时用 `0` 等默认值吞掉错误
- 规则：
  - 关联数组长度不一致直接 `return false`
  - 必填字段、值域、时间窗口（如 `start < end`）必须强校验
  - 参数无效时进入 `SAFE_MODE`，禁止开新仓

### 2) 运行时约束不能依赖人工

- 反模式：假设用户总会挂在正确图表/周期
- 规则：
  - `OnInit` 强制校验 `Symbol() == EURUSD`、`Period() == H4`
  - 不满足直接 `INIT_FAILED`

### 3) K 线时序语义要贴合 MT4 机制

- 反模式：评估-缓存-延迟执行导致错过“下一根 K 线首 tick”
- 规则：
  - 明确 `isNewBar` 触发语义
  - 对“Signal_K 收盘后下一根 K 线首 tick 执行”做专门时序验证

### 4) 风控计算要用净值与边界保护

- 反模式：
  - 使用 `AccountBalance()` 代替 `AccountEquity()`
  - `lot_step` 参与除法但未防零
  - 低于 `min_lot` 时盲目上调导致超风险
- 规则：
  - 风险口径基于净值（equity）
  - 涉及步长/点值运算必须做除零保护
  - 超风险场景宁可拒单，不做“看似可交易”的近似处理

### 5) 订单 API 调用签名和返回值类型必须严格匹配

- 反模式：
  - 参数顺序错位（`entry`/`stop_loss`/`slippage` 错传）
  - `int` 返回值当 `bool` 用，造成日志误报
- 规则：
  - 调用点按签名顺序逐项核对
  - 计数型返回值必须区分“全部成功/部分成功/全部失败”

### 6) 热更新必须具备原子性

- 反模式：加载失败直接污染当前有效参数
- 规则：
  - 使用 `temp_params` 解析与校验
  - 全部通过后再替换 `g_CurrentParams`
  - 失败保留旧参数并记录原因

### 7) 日志是审计契约，不是附属输出

- 反模式：
  - 关 logger 后再写停机日志，导致末条丢失
  - 关键字段缺失（版本、决策、规则）
- 规则：
  - 统一 schema：`timestamp/level/component/symbol/rule_hit/param_version/decision`
  - 停机顺序固定：先写完最后日志，再关闭 logger

### 8) Skill 运行时能力边界要先确认

- 反模式：在 Rhai 环境调用未注册函数（如 `call_skill`）
- 规则：
  - 先以运行时已注册工具为准（`call_tool`/`call_tool_json`/`write_file`）
  - 不可用能力必须在文档中明确“V1 限制 + 回退策略”

### 9) Cron 与 Gateway 协议必须以真实 API 为准

- 反模式：
  - 使用旧字段结构或错误路径
  - 任务名与 UUID 混用
- 规则：
  - 先拉取 `GET /v1/cron` 验证返回结构
  - 手动触发走 `POST /v1/cron/<id>/run`
  - 文档示例与脚本实现同步更新

### 10) 文档要区分“当前基准”和“历史过程”

- 反模式：过程快照长期冒充当前状态，导致误导
- 规则：
  - 过程文档标注“历史归档”
  - 主入口文档只保留当前有效结论与证据基准
  - 模板文档必须标注“非证据文档”

## 可执行检查清单

### EA 改动前自检

- [ ] 参数字段、数组长度、值域、时间窗口全部有硬校验
- [ ] 关键时序（新 K 线触发）有日志可验证
- [ ] 风控计算使用 equity 且具备除零保护
- [ ] 订单调用签名与返回值类型核对通过
- [ ] 参数热更新失败不会污染当前有效配置
- [ ] 停机日志写入顺序正确（先写后关）

### Skill/Cron 改动前自检

- [ ] 所有工具调用均在运行时能力范围内
- [ ] Cron 表达式与字段结构与当前网关实现一致
- [ ] 手动触发路径（一次性 Cron 或 run 接口）可复现
- [ ] 时间格式化覆盖闰年和月份天数
- [ ] 文档示例与脚本行为一致

### 文档改动前自检

- [ ] 标明文档类型：当前基准 / 历史归档 / 模板
- [ ] 关键链接可达（本地链接检查）
- [ ] “下一步/待办”描述与当前项目状态一致

## 证据与详细文档入口

- 最终验收：
  - `../.kiro/specs/mt4-forex-strategy-executor/final_acceptance_2026-03-11.md`
- 任务与规格：
  - `../.kiro/specs/mt4-forex-strategy-executor/tasks.md`
  - `../.kiro/specs/mt4-forex-strategy-executor/requirements.md`
  - `../.kiro/specs/mt4-forex-strategy-executor/design.md`
- EA 侧：
  - `../domain_experts/forex/ea/README.md`
  - `../domain_experts/forex/ea/STATIC_REVIEW_FIXES.md`
  - `../domain_experts/forex/ea/docs/BACKTEST_REPORT.md`
  - `../domain_experts/forex/ea/backtest_artifacts/README.md`
- Skill 侧：
  - `../domain_experts/forex/skills/forex_strategy_generator/README.md`
  - `../domain_experts/forex/skills/forex_strategy_generator/SKILL.md`
  - `../domain_experts/forex/skills/forex_strategy_generator/CRON_SETUP.md`
  - `../domain_experts/forex/skills/forex_strategy_generator/ONLINE_STRICT_ACCEPTANCE_2026-03-10.md`
  - `../domain_experts/forex/skills/forex_strategy_generator/STATIC_REVIEW_FIXES.md`

---

维护原则：本文件只维护“长期有效规则”；具体实现细节与运行日志一律回到对应模块文档更新。
