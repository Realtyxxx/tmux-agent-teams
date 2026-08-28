# Board 样例共同规范（三个样例 worker 都必须先读完本文件）

## 必读输入

1. `../2026-08-28-team-kanban-board.md` —— 总计划。重点：§3 状态映射表、§4 需求映射、§7 你负责的样例定义。
2. `~/workspace/project.skills/diagram-design/skills/diagram-design/references/style-guide.md` —— 全部颜色/排版 token 的唯一来源。
3. `~/workspace/project.skills/diagram-design/skills/diagram-design/references/type-kanban.md` —— kanban 视觉语言（卡片四态、WIP 芯片、blocked 左侧 accent 竖条）。注意：其中"≤5列/≤12卡/无交互"是静态图预算，本任务是交互看板 mockup，只借视觉语言，不继承预算。

## 产物要求

- 单个自包含 HTML 文件，无任何外部请求（无 CDN、无 webfont 下载）。字体用回退栈：正文 `"Geist", "Inter", system-ui, sans-serif`；等宽 `"Geist Mono", "SF Mono", ui-monospace, monospace`；页面大标题 `"Instrument Serif", Georgia, serif`。
- 颜色全部用 style-guide 的语义 token（paper/paper-2/ink/muted/soft/rule/accent/accent-tint/link），以 CSS 变量定义，深浅色齐备：`:root` 定义浅色，`@media (prefers-color-scheme: dark)` 覆盖为深色值。
- accent 克制：整页 accent 元素 ≤ 2 处的精神要保持（blocked 卡 + 一处超限/告警即可），不要满屏橙色。
- 这是**设计样例（静态假数据 mockup）**，不接真实数据、不写轮询逻辑；允许少量纯展示性 CSS hover。页面顶部放 team 名、mode、tmux session 等页头信息，风格对齐 goalbuddy 的 local board（干净、控制台感）。
- 页面语言：中文界面文案 + 英文等宽元数据（task id、branch、MR）。

## 统一假数据（三个样例用同一份，便于横向对比）

Team `payments-refactor`，mode `feature-mr`，session `team-payments`。

角色名册（泳道/图例按此动态生成；`perf-analyst` 是**刚注册的新角色**，要能看出"角色是动态加进来的"，比如空泳道 + `new` 芯片）：

| worker | runtime | 职责 |
| --- | --- | --- |
| impl-a | claude | 实现 |
| impl-b | codex | 实现 |
| reviewer | claude | 评审/验证 |
| perf-analyst | codex | 性能分析（新注册，暂无任务） |

任务（注意流转轨迹 lineage 是核心卖点，必须显式可视化——doing 卡片上出现 `impl-a → reviewer` 这样的角色芯片序列）：

| 看板列 | task id | 标题 | 说明 |
| --- | --- | --- | --- |
| todo | T7 | 对账单导出接口 | 契约已写未派工，无 owner |
| todo | T8 | 幂等键迁移脚本 | 同上 |
| doing | T5-verify | 验证退款路径改造 | owner=reviewer，lineage：T5(impl-a) → T5-verify(reviewer)，卡片显示轨迹芯片；worktree `wt/T5`，branch `feat/refund-path`，MR `!41`，worktree status=review 芯片 |
| doing | T6 | 支付网关重试策略 | owner=impl-b，无流转，branch `feat/gateway-retry`，worktree status=working |
| blocked | T4 | 账务快照压缩 | owner=impl-a，回执 status=blocked，blocker=T2，徽标 `receipt:blocked`，blocked 卡视觉（accent 左竖条+虚线描边） |
| done | T2 | 交易表分区改造 | owner=impl-b，receipt completed，verdict=pass，MR `!38` merged |
| done | T3-verify | 验证分区改造 | owner=reviewer，receipt completed，**verdict=fail** → 徽标 `verdict:fail`，其目标任务 T3 带 `rework` 徽标回到 doing/todo（你选一种表达并保持自洽） |
| done | T1 | 支付域建模 | receipt completed，verdict=pass，lineage：T1(impl-a) → T1-verify(reviewer) 已完整走完，done 卡也要能看到走过的角色 |

## 交付与回执

- 输出路径：本目录下你任务指定的文件名，其他文件一律不动。
- 完成后用 orchestration 的 worker_done 汇报，body 里给出产物绝对路径和一句话自查结论（深浅色是否都过、是否零外部请求）。
