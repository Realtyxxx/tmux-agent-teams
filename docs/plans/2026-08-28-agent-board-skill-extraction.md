# agent-board：把看板抽成独立 skill 的设计计划

日期：2026-08-28
状态：**设计稿，等用户确认后才进入实现**（本文件不含任何实施动作）
上位文档：[`2026-08-28-team-kanban-board.md`](2026-08-28-team-kanban-board.md)（状态映射 §3、lineage §5、沙箱 §6）、
[`board-api-contract.md`](board-api-contract.md)（当前 teams 专用契约，本文件把它一般化）
参考：[goalbuddy](https://github.com/tolibear/goalbuddy)（数据形态）、diagram-design（视觉语言）

---

## 1. 已确认的决策（用户 2026-08-28 拍板）

| 项 | 决定 |
| --- | --- |
| skill 名 | **`agent-board`**，定位 "agent todo board" |
| 远端可见性 | **private 先行**（`Realtyxxx/agent-board-skill`），成熟后再考虑转 public |
| 安装链 | **自带 `bin/install.js`**，不进 `personal-skills` submodule 链（同 eli5-skill / quota-watcher-skill） |
| 数据模型 | **通用核心 + 双适配器**：看板自己的数据契约为核心，原生目录适配器 + tmux-agent-teams(`.teams/`) 适配器 |
| 数据记录格式 | **学 goalbuddy 用 YAML/JSON 做记录**，原生格式不沿用 TSV（本文件 §3 展开） |

第 5 条是本轮新增输入，也是本文件的重点。

---

## 2. goalbuddy 的数据形态（已查证，非推测）

查证来源：仓库 README、`docs/spec/receipt-v1.md`、
`goalbuddy/surfaces/local-goal-board/examples/sample-goal/state.yaml`。

**目录**

```text
docs/goals/<goal-slug>/
  goal.md                 # 目标陈述（散文）
  state.yaml              # 看板的唯一真相源
  notes/                  # 长篇发现，不塞进主线程
  .goalbuddy-board/       # 生成的本地看板产物
  subgoals/               # 可选，深度 1 的子看板
```

**`state.yaml` 实际结构**（取自 sample-goal，逐字核对过）

```yaml
version: 2
goal:
  title: "Local Goal Board Surface"
  slug: "local-goal-board-surface"
  kind: specific
  tranche: "..."
  status: active
active_task: null
tasks:
  - id: T001
    type: scout          # scout | judge | worker | pm
    assignee: Scout
    status: done         # queued | active | blocked | done
    objective: "Map the goal state inputs."
    receipt:
      result: done       # done | blocked
      summary: "..."
```

**receipt-v1 规范要点**：task card 必填 `id`（`T` + 3 位数字）/`type`/`assignee`/`status`/
`objective`/`inputs`/`constraints`/`expected_output`/`receipt`；worker 类任务额外必填
`allowed_files`/`verify`/`stop_if`；可选 `harness: codex | claude-code`。
回执是一个信封 `{"goalbuddy_receipt_v1": {...}}`，公共字段 `result`(done|blocked)、
`task_id`、`board_path`，其余按角色分（scout 的 evidence/facts、judge 的 decision、
worker 的 changed_files/commands/deviations 或 blocked_reason/spawned_tasks）。

**值得抄的三点**

1. 纯文本、harness 无关：看板只是 `state.yaml` 的一个 view，换 agent/harness 不影响数据。
2. 声明式单文件 + 明确 schema：agent 能整体读、整体重写，人也能手改。
3. 回执是有 schema 的结构化对象，不是自由散文——校验得动、路由得动。

**明确不抄的一点（偏离要说清楚）**

goalbuddy 把回执**内联进 `state.yaml`**（见上面 sample 的 `tasks[].receipt`）。
agent-board **把回执拆成独立的、worker 自己拥有的文件**。理由：本项目的协议核心是
**写入权分离**——leader 写契约、worker 写回执，两边永不写同一个文件（现有 `.teams/`
就是 `tasks/` vs `receipts/` 的切分）。单文件内联在单 agent 场景没问题，在多 worker
并发下会变成一个天然冲突点。代价是失去"一个文件看全部"的便利，用 §3 的分层缓解：
**只有 `board.yaml` 是必需的**，receipts/ 与 events.jsonl 都可缺省，缺省时就退化成
goalbuddy 那样的单文件看板。

---

## 3. 原生数据格式（native adapter）

### 3.1 目录布局

```text
.agent-board/                 # 数据根，放在被观察的项目仓库里
  board.yaml                  # 必需。驱动者（leader / 单 agent）拥有
  receipts/<task-id>.yaml     # 可选。执行者（worker）拥有，一任务一文件
  events.jsonl                # 可选。追加式机器日志，任何一方 append，永不重写
  notes/<task-id>.md          # 可选。长文详情，board.yaml 里用 detail_file 指过来
```

拥有权（沿用 `.teams/` 的不变量）：

| 文件 | 谁写 | 写法 |
| --- | --- | --- |
| `board.yaml` | 驱动者，单写者 | 整体重写（读-改-写） |
| `receipts/<id>.yaml` | 该任务的执行者 | 只创建/覆盖自己那一个文件 |
| `events.jsonl` | 双方 | 只 append 一行，永不修改既有行 |
| `notes/<id>.md` | 作者不限 | 只读消费 |

服务端**全程只读**，不创建、不 touch、不执行其中任何内容。

### 3.2 `board.yaml`

```yaml
version: 1
board:
  title: "退款链路重构"
  slug: payments-refactor
  status: active            # active | paused | done
lanes:                      # 泳道（角色/worker）。省略则退化为单泳道 todo 板
  - id: impl-a
    label: "实现 A"
    runtime: claude         # 自由文本，仅展示
  - id: reviewer
    label: "评审"
tasks:
  - id: T005
    title: "改造退款回滚路径"
    status: doing           # todo | doing | blocked | done
    owner: impl-a           # 对应 lanes[].id；null = 待派工池
    parent: T004            # 可选，接力来源（lineage 兜底来源之一）
    blocked_by: T002        # 可选，被谁挡住（详情抽屉的 "block at"）
    blocked_since: 1756366920
    updated_at: 1756366999
    tags: [refund, hot]
    detail: |               # 可选，块标量；或用 detail_file
      契约摘要写在这里，多行。
    detail_file: notes/T005.md
```

- `status` 同时接受 goalbuddy 词表并做别名归一：`queued→todo`、`active→doing`。
- `owner` 不在 `lanes` 里 → 视为动态新角色，自动补一条泳道并打 `new` 芯片
  （满足"角色动态增加，看板随之变化"）。
- `detail` 与 `detail_file` 同时存在时 `detail` 优先，`detail_file` 只读、路径必须落在
  `.agent-board/` 内（越界一律拒绝并计入 `warnings`）。

### 3.3 `receipts/<id>.yaml`

字段沿用现有 teams 回执白名单（这样两个适配器归一到同一个 receipt 对象，
前端只写一次渲染逻辑），并借 goalbuddy 的信封思路加一层版本标识：

```yaml
agent_board_receipt_v1:
  task: T005
  worker: impl-a
  status: completed        # completed | blocked | failed
  verdict: pass            # pass | fail | unverified | not_applicable
  next: verify             # verify | rework | deliver | await_user | none
  blocker: none            # none | <task-id> | <短语>
  artifact: artifacts/T005.md   # 仅作字符串展示，服务端永不打开
  summary: "一句话，≤120 字"
```

校验规则与现有 `show_receipt` 完全同套（正则白名单）；任一字段非法 → **整条回执按
null 处理**并写 `warnings: ["invalid-receipt:T005"]`，绝不把原文透传到页面。

### 3.4 `events.jsonl`（JSON 那一半）

一行一个 JSON 对象，追加式，是 lineage / 流转轨迹 / 时间线的一等来源：

```jsonl
{"ts":1756366000,"event":"create","task":"T005"}
{"ts":1756366100,"event":"dispatch","task":"T005","worker":"impl-a","parent":"T004"}
{"ts":1756366800,"event":"block","task":"T005","blocker":"T002"}
{"ts":1756366920,"event":"receipt","task":"T005","worker":"impl-a","status":"completed","next":"verify"}
{"ts":1756367000,"event":"handoff","task":"T005-verify","worker":"reviewer","parent":"T005"}
```

`event ∈ {create, dispatch, handoff, block, unblock, receipt, done, note}`；未知 event
忽略但计入 `warnings`。**为什么这半边用 JSONL 而不是 YAML**：它是机器追加的日志，
要的是"一行一条、永不重写、坏一行不毁全文件"，YAML 在这个用法上没有优势且更易写坏。
YAML 留给人/agent 声明式编辑的那部分（board.yaml、receipts/）。

**lineage 降级链**（三级，页面标注来源）：

| 来源 | 条件 | `lineage.source` |
| --- | --- | --- |
| events.jsonl 的 parent 链 | 有该文件且链完整 | `events` |
| board.yaml 的 `tasks[].parent` | 无 events 但有 parent 字段 | `parent-field` |
| id 前缀启发式（`T5` ↔ `T5-verify`） | 都没有 | `heuristic`（页面打 `heuristic-lineage` 芯片） |

teams 适配器的三级是 `flow.tsv → board.tsv 顺序 → heuristic`，语义对齐。

### 3.5 YAML 解析：Python stdlib 没有 YAML

这是把原生格式定成 YAML 后立刻撞上的硬约束——现有契约把 `serve.py` 冻结为
**stdlib-only、零第三方依赖**，沙箱方案也建立在这上面（不需要 site-packages 进 bind 列表）。
两条路：

| 方案 | 代价 | 收益 |
| --- | --- | --- |
| **A（推荐）** 内置 `miniyaml.py`，只支持一个受限子集 | 约 120–180 行自研解析器，需要自己测 | 最贴近用户指的 goalbuddy 形态；agent 和人都写得顺手 |
| B 全用 JSON（`board.json` / `receipts/*.json` / events.jsonl） | 手写体验差（无注释、逗号约束） | 零解析成本、零歧义 |

**推荐 A**，并把子集**明确写进 SKILL.md 当作格式规范**，而不是"尽量像 YAML"：

- 支持：两空格缩进的映射与列表、`key: value` 标量、`- ` 列表项、行内 `[a, b]` 简单列表、
  `|` 块标量、`#` 注释、`null`/`true`/`false`/整数/引号或裸字符串。
- 不支持（遇到即报错，不猜）：锚点/别名（`&`/`*`）、多文档（`---`）、`>` 折叠标量、
  复杂 key、流式映射 `{a: 1}`、tab 缩进。
- 解析失败 → 该文件整体丢弃 + `warnings: ["parse-error:<file>:<line>"]`，服务不崩，
  页面保留上一次成功的数据（与现有 offline 行为一致）。

同一个 loader 按扩展名分发：`board.json` 存在时走 `json.loads`（同 schema），
这样 B 方案是 A 的免费子集，用户之后想切也不用改契约。

---

## 4. 通用 JSON 契约：核心 vs 适配器扩展

现有 `board-api-contract.md` 的 payload 里混着 teams 专有字段（worktree/mr/pane/runtime）。
抽成 skill 后拆成两层，前端只对**核心**做布局，对**扩展**做"认识就渲染、不认识就忽略"。

### 4.1 核心（两个适配器都必须提供）

```jsonc
{
  "board": {"name": "payments-refactor", "title": "退款链路重构", "status": "active"},
  "lanes": [                       // 原 roster，泛化命名；顺序即渲染顺序
    {"id": "impl-a", "label": "实现 A", "new": false,
     "ext": {"runtime": "claude", "role": "worker"}}
  ],
  "tasks": [
    {"id": "T005-verify",
     "title": "验证退款路径改造",   // 纯文本，≤120 字符截断
     "column": "todo|doing|blocked|done",   // 服务端算好，前端不推断
     "owner": "reviewer",          // null = 待派工池
     "detail": "契约摘要纯文本",    // 详情抽屉正文；无则 null
     "blocker": "T002",            // 详情抽屉 "block at"；无则 null
     "blocked_since": 1756366920,  // epoch 秒；无则 null
     "updated_at": 1756367000,
     "badges": ["receipt:blocked"],
     "receipt": {"status": "completed", "verdict": "pass", "blocker": "none",
                  "next": "verify", "artifact": "...", "summary": "..."},
     "lineage": {"chain": [{"task": "T005", "worker": "impl-a"},
                            {"task": "T005-verify", "worker": "reviewer"}],
                  "source": "events|flow|parent-field|heuristic"},
     "ext": {}                     // 适配器专有，见 4.2
    }
  ],
  "attention": ["T004"],           // 需要驱动者决策：receipt.status ∈ {blocked,failed} 或 next=await_user
  "activity": [                    // 原 receipts_feed，泛化：回执 + 事件混流，倒序 ≤20
    {"task": "T004", "worker": "impl-a", "ts": 1756366920, "kind": "receipt",
     "fields": {"status": "blocked", "next": "await_user", "blocker": "T2"}}
  ],
  "adapter": "native|tmux-agent-teams",
  "generated_at": 1756367000,
  "warnings": ["invalid-receipt:T9", "parse-error:board.yaml:31"]
}
```

`detail` / `blocker` / `blocked_since` 是本轮**回填**的字段——sample-d 的详情抽屉已经
用上了它们，但当前契约里没有。各适配器的来源：

| 字段 | native | tmux-agent-teams |
| --- | --- | --- |
| `detail` | `tasks[].detail` 或 `detail_file` 正文 | `tasks/<id>.md` 首行之后的正文（纯文本，截断） |
| `blocker` | `tasks[].blocked_by` 或回执 `blocker` | 回执 `blocker` 字段 |
| `blocked_since` | `tasks[].blocked_since` 或 block 事件 ts | 回执文件 mtime |

### 4.2 适配器扩展（`ext` 命名空间）

teams 适配器往 `tasks[].ext` 塞：

```jsonc
"ext": {"worktree": {"mr": "!41", "branch": "feat/refund-path", "status": "review"},
        "pane": "team-payments:1.2"}
```

前端对 `ext.worktree` 有专门的渲染块（MR 徽标、worktree 状态芯片）；对任何未知
`ext.*` 键**不渲染也不报错**。这样第三个适配器（比如 GitHub Issues、Obsidian 任务）
以后可以只实现核心就上板。

### 4.3 受控徽标词表

核心：`blocked` `failed` `verdict:fail` `rework` `new` `heuristic-lineage` `stale`
teams 扩展：`worktree:blocked` `worktree:review`
（前端只认词表内的值，其余忽略——徽标来自服务端计算，永不来自用户文本。）

---

## 5. 适配器接口

```python
# board/adapters/<name>.py
def detect(root: Path) -> bool: ...          # 目录里有没有本适配器认得的数据
def list_boards(root: Path) -> list[dict]: ...   # 供 /api/boards 切换器
def load(root: Path, board: str | None) -> dict: ...  # 返回 §4 的核心 payload
```

`serve.py --root <dir> [--adapter native|tmux-agent-teams] [--port 8737]`；
不给 `--adapter` 时按 `detect()` 顺序自动识别（`.agent-board/` → native，
`.teams/` → tmux-agent-teams），都命中则报错要求显式指定。

端点（在现有基础上泛化命名）：`GET /`、`GET /api/board?board=<name>`、`GET /api/boards`；
只读服务，写方法一律 405。

---

## 6. 沙箱：每个适配器自带 bind 清单

`run-sandboxed.sh` 保持三级（Linux bwrap / macOS sandbox-exec / dev 直跑），
把"挂什么"从脚本里的硬编码改成适配器声明的清单：

| 适配器 | ro-bind 白名单 | 永不 bind |
| --- | --- | --- |
| native | `.agent-board/board.yaml`、`receipts/`、`events.jsonl`、`notes/` | 项目仓库其余一切 |
| tmux-agent-teams | `board.tsv`、`flow.tsv`、`worktrees.tsv`、`agents.tsv`、`workers.tsv`、`receipts/`、`tasks/`、`mode.md`、`team.meta` | **`artifacts/`**（协议边界的机械化） |

现有 `tests/board-sandbox.sh` 的断言（沙箱内 `artifacts/` 不可见）随适配器一起迁移，
native 侧加一条对称断言（`.agent-board/` 之外的仓库文件不可见）。

---

## 7. 仓库骨架与安装链

```text
~/workspace/project.skills/agent-board-skill/        # private
  README.md
  bin/install.js                    # 同 eli5-skill / quota-watcher-skill 的形态
  skill/
    SKILL.md                        # 数据格式规范 + 启动方式 + agent 怎么写 board.yaml
    board/
      serve.py
      miniyaml.py
      index.html                    # sample-d 的融合模板（B 泳道 + C 焦点/回执流 + 详情抽屉）
      run-sandboxed.sh
      adapters/{__init__.py,native.py,tmux_teams.py}
      schema/board-payload.schema.json
    templates/board.yaml            # 空板模板，agent 照抄
    examples/{solo-todo/,team-mock/}  # 两个适配器各一套可跑示例
  tests/{miniyaml.sh,native-adapter.sh,teams-adapter.sh,board-sandbox.sh}
```

安装（按 CLAUDE.md 的安装目标布局）：

```bash
node bin/install.js --force                 # → ~/.agents/skills/agent-board
ln -s ~/.agents/skills/agent-board ~/.codex/skills/agent-board   # mac 首次手工补
```

b200 走 rsync + 本地 `node bin/install.js --force`（private 仓库，b200 无凭据）。
安装后需在 CLAUDE.md 第 2 节仓库地图 + 第 3 节真相源表各加一行。

---

## 8. 从 tmux-agent-team-server 迁出的步骤（等开工）

1. 新建 private 仓库 `Realtyxxx/agent-board-skill`，落 §7 骨架。
2. `skills/tmux-agent-teams/board/{serve.py,index.html,run-sandboxed.sh}` 迁入，
   `serve.py` 的聚合逻辑原样变成 `adapters/tmux_teams.py`。
3. 新写 `adapters/native.py` + `miniyaml.py` + 两套 examples。
4. `index.html` 以 sample-d 为基线（含详情抽屉），字段改吃 §4 核心契约。
5. `board-api-contract.md` 头部标注"已由本文件 §4 取代"，避免后续会话把旧契约
   （`roster`/`receipts_feed`/teams 专有字段）当成权威；两端实现一律以 §4 为准。
6. tmux-agent-teams 侧：**删掉 `board/` 目录**，`SKILL.md` 保留一段指针
   （"看板见 agent-board skill，用 `--adapter tmux-agent-teams --root .teams/`"）；
   `tests/board-sandbox.sh` 随代码迁走。
7. **留在 tmux-agent-teams 的**：`flow.tsv` + `dispatch --parent` + `tests/teamctl-flow-lineage.sh`
   ——这是团队协议本身的扩展，不是看板的一部分，看板只是它的消费者。
8. `docs/plans/board-samples/` 四个样例留在本仓库当设计存档，不迁。

---

## 9. 明确不在本轮范围

- 任何实施动作（建仓、迁文件、写 miniyaml）——**等用户说开工**。
- 看板写回（拖拽改状态、页面上点按钮执行 teamctl）。现在和以后都保持**只读**：
  写权归 agent，看板是 surface，这条不松。
- 多层 board（goalbuddy 的 subgoals）——原生格式先做单层，`board.yaml` 里预留
  `parent_board` 字段位但不实现。
- 第三个适配器（GitHub Issues / Obsidian）——`ext` 机制为它留门，本轮不做。

## 10. 待你拍板的点

1. **§3.5 的 A/B**：推荐 A（受限 YAML 子集 + 自带解析器）。若你更看重零风险，
   B（全 JSON）也完全符合"yaml 或者 json"这个口径。
2. **数据根目录名**：`.agent-board/`（显式）vs `.aboard/`（好敲）。默认取前者。
3. **`board.yaml` 单文件 vs 拆 `tasks/<id>.yaml`**：默认单文件（贴 goalbuddy、
   单 agent 场景最简），多写者靠 receipts/ 与 events.jsonl 分流。如果你预期原生格式
   也要跑多 worker 并发，那 tasks 也该一任务一文件——这会改变 §3.2 的形态。
