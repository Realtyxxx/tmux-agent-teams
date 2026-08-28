# Team 级别工作任务看板（Web）设计计划

日期：2026-08-28
状态：待用户选定样例方向（3 个样例图见 `docs/plans/board-samples/`）
参考：[goalbuddy](https://github.com/tolibear/goalbuddy)（local live board 形态）、
diagram-design skill（视觉语言：kanban 类型规范 + style-guide token 体系）

## 1. 目标

为 `tmux-agent-teams` 的每个 team（`.teams/<name>/`）提供一个网页看板，
呈现任务在 **todo / doing / blocked / done** 四个状态间的分布与流转，
只读、零依赖、可在 bubblewrap 沙箱下运行，且严格遵守 leader/worker
协议的信息边界（看板是控制面 surface，永远不读 `artifacts/` 与 pane 文本）。

## 2. 数据源与现状核实（2026-08-28 已查证 teamctl.sh）

| 文件 | 内容 | 看板用途 |
| --- | --- | --- |
| `tasks/<id>.md` | Leader 写的任务契约 | todo 判定、卡片标题 |
| `board.tsv` | `dispatch` 追加 `task_id \t worker`，无时间戳 | doing 判定、归属 |
| `receipts/<id>.md` | Worker 写的回执，`DONE <id>` 哨兵；字段 status（completed/blocked/failed）、verdict、blocker、next（verify/rework/deliver/await_user/none）、artifact | done/blocked 判定、流转路由 |
| `worktrees.tsv` | 追加式快照 `worker \t pane \t mr \t dir \t branch \t status`（working/blocked/review/merged/closed），最新行生效 | 卡片上的 worktree/MR 徽标、in-flight blocked 信号 |
| `agents.tsv` / `workers.tsv` | 名册（role、runtime、session、pane、lifecycle） | 角色/泳道动态生成 |
| `mode.md`、`team.meta` | 场景模式快照、team 元数据 | 页头信息 |

**已核实的关键事实**：`dispatch` 对 task id 不查重（直接追加），但
`show_receipt` 取 board.tsv **第一条**匹配行为 owner 并要求与回执 worker 一致。
因此同一 id 不能安全重派；现行协议中"任务在 worker 间流转"= **新 task id 接力**
（回执 `next: verify/rework` → leader 派新契约给另一 worker，输入是前序
artifact 的不透明路径）。"逻辑任务走过哪些角色"目前只能靠 id 命名约定弱恢复，
不是一等公民 → 需要第 5 节的小扩展。

## 3. 状态映射表（用户四状态 ← 三套既有词汇）

| 看板列 | 判定规则 | 备注 |
| --- | --- | --- |
| **todo** | `tasks/<id>.md` 存在且 board.tsv 无该 id 行 | 契约已写、未派工 |
| **doing** | board.tsv 有行，且 `receipts/<id>.md` 无完整 `DONE <id>` 哨兵 | worker 最新 worktree 状态为 review/merged 时在卡片上加芯片，不换列 |
| **blocked** | 回执 status=blocked（终态，等 leader 路由）**或** 该任务 owner 的最新 worktree status=blocked（in-flight 信号） | 两种来源用不同徽标区分；回执 status=failed 也落此列，徽标 `failed`，暗示 rework 路由 |
| **done** | 回执 status=completed 且哨兵完整 | verdict=fail 的已完成 verify 任务加 `verdict:fail` 徽标，其目标任务加 `rework` 徽标 |

## 4. 用户需求 → 方案映射

1. **doing 内任务在 worker 间流转** —— 用第 5 节的 lineage 链把接力的
   task id 串成一条"逻辑任务"，doing 卡片显示当前 owner + 流转轨迹
   （A → B → C 的角色芯片序列）。
2. **角色动态增减，看板随之变化** —— 泳道/图例完全由 `workers.tsv` +
   `agents.tsv` 实时派生，注册新 worker 即出现新泳道，无任何硬编码。
3. **任务不一定走所有角色、走过哪些要记录** —— lineage 链只记实际发生的
   接力；每张卡片渲染其真实轨迹芯片，未经过的角色不显示。
4. **bubblewrap 下运行、最小可见文件** —— 第 6 节沙箱方案；`artifacts/`
   永不进入 bind 列表（这正是协议边界的机械化）。
5. **参考 diagram-design** —— 视觉全部取自 style-guide token
   （paper/ink/muted/accent、Geist/Geist Mono/Instrument Serif、
   WIP 芯片 rx=2 矩形、blocked 卡左侧 accent 竖条、克制的 1-2 accent 预算）。
   kanban 类型的"无箭头/≤5列/≤12卡"是静态图预算，交互看板只借视觉语言不继承预算。

## 5. 协议小扩展：流转轨迹一等公民化（实现阶段做）

新增追加式 `$TEAM_DIR/flow.tsv`，由 `teamctl.sh dispatch` 写入（对既有
读者零破坏，board.tsv 格式不动）：

```text
epoch_ts \t task_id \t worker \t parent_task_id|-
```

- `dispatch` 增加可选参数 `--parent <id>`（缺省 `-`）。leader 在 verify/
  rework/接力派工时带上前序 id。
- 看板由 parent 链聚合出"逻辑任务"，得到角色轨迹与流转动画数据。
- 降级策略：flow.tsv 不存在或链断裂时，看板退回"按 id 前缀分组"的弱恢复，
  页面上明确标注 `lineage: heuristic`。
- 同步改动：SKILL.md 的 Dispatch Protocol 补一句 `--parent` 约定 + 一个
  bats 风格测试（`tests/teamctl-flow-lineage.sh`）。

## 6. 运行形态与沙箱

- **服务**：`board/serve.py`，Python3 stdlib（零第三方依赖）。
  - `GET /` 返回自包含 HTML（token 内联，深浅色跟随系统）。
  - `GET /api/team` 返回聚合 JSON；前端 2s 轮询刷新（不做 SSE，保持简单）。
  - 多 team：`?team=<name>`，页头 team 切换器（对齐 goalbuddy 的 board switcher）。
- **渲染安全**：回执字段在服务端按 `show_receipt` 同一套白名单+正则校验，
  非法值整条降级为 `invalid-receipt` 徽标；前端一律 `textContent`，永不
  `innerHTML`——恶意 worker 能写 receipts/，这是注入面而不只是显示问题。
  `tasks/<id>.md` 只取首行标题，同样按纯文本渲染。
- **沙箱启动器** `board/run-sandboxed.sh`：
  - Linux（b200）：`bwrap --unshare-all --share-net --ro-bind` 仅挂
    `board.tsv`、`worktrees.tsv`、`agents.tsv`、`workers.tsv`、`flow.tsv`、
    `receipts/`、`tasks/`、`mode.md`、`team.meta`、`serve.py` 与 python 运行时；
    **不挂 `artifacts/`**，其余文件系统不可见。
  - macOS：bwrap 不存在 → `sandbox-exec` 只读 profile 兜底；再兜底为
    显式打印 "unsandboxed dev mode" 的直跑模式。

## 7. 三个样例方向（本计划的下一步产出）

| 样例 | 形态 | 侧重 |
| --- | --- | --- |
| A `sample-a-status-columns.html` | 经典四列 todo/doing/blocked/done | 状态普查；doing 卡片上用角色芯片序列表达流转轨迹 |
| B `sample-b-role-swimlane.html` | 行=worker/角色（动态泳道），列=四状态 | 角色维度；新增角色即新增一行，流转=卡片跨行 |
| C `sample-c-control-room.html` | goalbuddy 式控制台：焦点任务 + 四列迷你板 + 回执流 + 轨迹时间线 | 控制面全景；leader 视角的路由决策信息 |

三个样例均为自包含 HTML、假数据但结构真实（含一条 A→B 的流转轨迹、
一个动态新增角色、一张 blocked 卡、一张 failed 徽标卡），供用户选定后
进入实现阶段。

## 8. 实现阶段任务清单（用户选定样例后执行）

1. `flow.tsv` + `dispatch --parent` 扩展与测试。
2. `board/serve.py` 聚合器（状态映射表 §3 + lineage §5 + 校验 §6）。
3. 选定样例的前端落地（token、轮询、team 切换器、深浅色）。
4. `board/run-sandboxed.sh` 双平台启动器 + `tests/board-sandbox.sh`
   （断言 artifacts/ 在沙箱内不可见）。
5. SKILL.md 增补 board 章节（leader 可看的控制面 surface 定位）。
