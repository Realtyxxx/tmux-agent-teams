# Board API 契约（serve.py ⇄ index.html 并行开发的冻结接口）

日期：2026-08-28。改动本文件 = 破坏并行开发，必须先在此更新再改两端实现。
上位文档：`2026-08-28-team-kanban-board.md`（状态映射 §3、lineage §5、安全 §6）。

## 文件布局

```text
skills/tmux-agent-teams/board/
  serve.py            # Python3 stdlib-only HTTP 服务，无第三方依赖
  index.html          # 自包含前端（B 泳道骨架 + C 焦点面板/回执流/轨迹时间线）
  run-sandboxed.sh    # bwrap(Linux) / sandbox-exec(macOS) / dev 直跑 三级启动器
```

## 端点

- `GET /` → `index.html` 原样返回（`text/html; charset=utf-8`）。
- `GET /api/team?team=<name>` → 下述 JSON。`team` 缺省时取 `.teams/` 下唯一
  team；多个且未指定 → `400 {"error":"team_required","teams":[...]}`。
- `GET /api/teams` → `{"teams":[{"name":..,"status":..}]}`（team 切换器用）。
- 其他路径 → 404。只读服务，任何写方法 → 405。
- 服务进程启动参数：`serve.py --teams-root <dir> [--port 8737]`。
  沙箱内 `--teams-root` 指向只读 bind 的 `.teams/`。

## `GET /api/team` 响应 schema

```jsonc
{
  "team": {"name": "payments-refactor", "status": "active",
            "mode": "feature-mr", "session": "team-payments"},
  "roster": [                       // 泳道按此数组顺序渲染，动态角色的唯一来源
    {"worker": "impl-a", "runtime": "claude", "role": "worker",
     "registered_at": null,         // agents.tsv 无时间戳则 null
     "new": false}                  // 名册里无任何 board/flow 行 → true（new 芯片）
  ],
  "tasks": [
    {"id": "T5-verify",
     "title": "验证退款路径改造",   // tasks/<id>.md 首个非空行，纯文本，≤120 字符截断
     "column": "todo|doing|blocked|done",   // 服务端按 §3 映射表算好，前端不再推断
     "owner": "reviewer",           // board.tsv 首行 owner；todo 为 null
     "badges": ["receipt:blocked"], // 受控词表，见下
     "receipt": {                   // 无完整回执则 null；字段已过白名单校验
       "status": "completed", "verdict": "pass", "blocker": "none",
       "next": "verify", "artifact": "artifacts/T5-verify.md"},
     "worktree": {                  // 该 owner 最新 worktrees.tsv 行；无则 null
       "mr": "!41", "branch": "feat/refund-path", "status": "review"},
     "lineage": {                   // 逻辑任务链
       "chain": [{"task": "T5", "worker": "impl-a"},
                  {"task": "T5-verify", "worker": "reviewer"}],
       "source": "flow|heuristic"}  // flow.tsv 缺失/断链时 heuristic + 页面标注
    }
  ],
  "attention": [                    // C 融合模块①：需要 leader 决策的任务 id，
    "T4"                            // 判定：receipt.status ∈ {blocked,failed}
  ],                                //   或 receipt.next = await_user
  "receipts_feed": [                // C 融合模块②：按 mtime 倒序，最多 20 条
    {"task": "T4", "worker": "impl-a", "mtime": 1756366920,
     "fields": {"status": "blocked", "verdict": "unverified",
                 "blocker": "T2", "next": "await_user"}}
  ],
  "generated_at": 1756367000,
  "warnings": ["invalid-receipt:T9"]  // 校验失败项在此列出，绝不透传原文
}
```

## 受控徽标词表（前端只认这些，其余忽略）

`receipt:blocked` `receipt:failed` `worktree:blocked` `verdict:fail`
`rework` `new` `heuristic-lineage`

## 安全不变量（两端都必须遵守）

- 服务端：回执字段用 `show_receipt` 同套正则白名单；任何字段非法 → 整条回执
  按 null 处理并写入 `warnings`。标题/一切文件内容永不透传 HTML。
- 前端：所有动态值一律 `textContent` 赋值；不存在任何 `innerHTML` 动态拼接。
- 服务端只读打开文件；不 touch、不创建、不执行 `.teams/` 下任何内容。
- `artifacts/` 路径只作为字符串展示（回执 artifact 字段），服务进程永不打开它。

## 前端行为

- 2s `fetch('/api/team?...')` 轮询，失败时页头显示 `offline` 芯片并保留上次数据。
- 泳道行 = `roster` 顺序 + 顶部"待派工"池（column=todo 且 owner=null 的任务）。
- 深浅色：`:root` 浅色 + `prefers-color-scheme: dark` 覆盖，token 同样例 B。
- 点击任务卡 → 右侧轨迹时间线切换到该任务的 lineage chain。
- 焦点面板路由建议按钮是**展示性**的（title 提示对应 teamctl 命令），MVP 不执行命令。
