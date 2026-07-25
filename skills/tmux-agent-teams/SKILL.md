---
name: tmux-agent-teams
description: "Use when a confirmed team of external Claude Code or Codex agents must cooperate in tmux panes, especially when the current agent must remain a manager and substantive work must stay isolated in worker artifacts. Triggers: 多个 agent 协作, tmux 面板编排, leader worker, agent team, multi-agent tmux."
---

# tmux Agent Teams — Leader Skill

## Overview

This is the **primary skill for the `leader` object**. Read this file completely
before creating a team. The leader behaves like a product manager: it negotiates
the work design with the user, builds the task graph, dispatches workers, routes
blockers, and reports control-plane status.

The secondary skill is [`worker/SKILL.md`](worker/SKILL.md). The leader MUST NOT
open or load it. `teamctl.sh dispatch` gives its absolute path to every worker,
and each worker must read it before starting.

**Core principle: the leader manages work but never performs or consumes it.**

## Objects

The protocol has exactly two object types:

| Object   | Owns                                                       | Does not own                                       |
| -------- | ---------------------------------------------------------- | -------------------------------------------------- |
| `leader` | User alignment, roster, task graph, scheduling, escalation | Implementation, investigation, review, work output |
| `worker` | One bounded task and its substantive artifact              | Team policy, roster, scheduling, user commitments  |

Worker responsibilities are dynamic. A worker can be assigned implementation,
investigation, review, verification, integration, or delivery, but only through
a user-confirmed task contract.

## Permission Boundary

| Capability                                      | Leader | Worker |
| ----------------------------------------------- | :----: | :----: |
| Read this primary skill                         |  MUST  | NEVER  |
| Read `worker/SKILL.md`                          | NEVER  |  MUST  |
| Negotiate roster and methods with the user      |  MUST  | NEVER  |
| Create, prioritize, assign, or cancel tasks     |  MUST  | NEVER  |
| Inspect task source, code, documents, or data   | NEVER  |  MAY   |
| Implement, investigate, analyze, or review      | NEVER  |  MAY   |
| Read or summarize work artifacts                | NEVER  |  MAY   |
| Read bounded control receipts                   |  MAY   |  MAY   |
| Read the worktree control board                 |  MAY   |  MAY   |
| Update a worker's own worktree snapshot         | NEVER  |  MAY   |
| Change the agreed task method or acceptance bar | NEVER  | NEVER  |

The leader may inspect tmux identities, liveness, process state, the task board,
and validated receipt fields. These are orchestration metadata, not work output.

### No Managerial Override

The following are still work and MUST be delegated:

- Opening an artifact “just to understand it”
- Reading a diff, source file, report, review, or test log
- Doing a quick implementation, investigation, or sanity check
- Synthesizing findings into a technical answer
- Accepting work based on personal judgment

Deadlines, idle worker seats, small changes, and user urgency do not relax the
boundary. If no qualified worker is available, report the task as blocked or
unverified.

## Information Planes

| Plane          | Path                          | Producer | Reader                   | Content                          |
| -------------- | ----------------------------- | -------- | ------------------------ | -------------------------------- |
| Task contract  | `$TEAM_DIR/tasks/<id>.md`     | Leader   | Assigned worker          | Confirmed work instructions      |
| Work artifact  | `$TEAM_DIR/artifacts/<id>.md` | Worker   | Other assigned workers   | Findings, code review, synthesis |
| Receipt        | `$TEAM_DIR/receipts/<id>.md`  | Worker   | Leader through `teamctl` | Bounded status metadata          |
| Task board     | `$TEAM_DIR/board.tsv`         | Helper   | Leader                   | Assignment and completion state  |
| Worktree board | `$TEAM_DIR/worktrees.tsv`     | Worker   | Leader and workers       | Path, branch, MR, and state      |

The leader MUST NOT open `artifacts/`. It also MUST NOT print raw receipts
because a malformed worker could place substantive or injected content there.
Use `teamctl.sh show-receipt <id>` to expose only validated control fields.

Pane output is not a result channel. Do not use `capture-pane` to collect or
read work. Liveness checks must use tmux metadata such as pane existence,
`pane_dead`, and `pane_current_command`.

## Team Design and User Confirmation

Before creating a session, launching a CLI, or dispatching a task, propose the
team design and obtain the user's confirmation.

| Required field       | Meaning                                                   |
| -------------------- | --------------------------------------------------------- |
| Worker               | Stable seat name                                          |
| Responsibility       | Implementation, investigation, review, verification, etc. |
| Method               | Task-specific approach, tools, or required skill          |
| Inputs               | User-provided context or opaque prior-artifact paths      |
| Acceptance criteria  | Observable completion conditions                          |
| Dependency/verifier  | Upstream artifacts and independent checking route         |
| CLI and model        | `claude` or `codex`, plus launch-scoped model choice      |
| Artifact destination | The work product another worker or the user will consume  |

The secondary skill defines only interaction. It does not choose technical
methods. The leader proposes methods from the user's request, asks the user to
resolve material choices, and records confirmed methods in each task contract.

If the user changes scope or method, update the design and obtain confirmation
before dispatching affected tasks.

## CLI and Model Policy

The supported worker CLIs are fixed:

| CLI    | Full-access launch after confirmation                      |
| ------ | ---------------------------------------------------------- |
| claude | `command claude --dangerously-skip-permissions`            |
| codex  | `command codex --dangerously-bypass-approvals-and-sandbox` |

Use launch-scoped model flags only. Never type `/model` or edit persistent CLI
configuration. If the user does not name a model, use the CLI default and omit
model flags. If the user names a model, validate it against a sibling
`model-catalog.json` when present. A missing or unusable cache is a user
decision point; never refresh it automatically.

## Leader Startup

| Mode           | Trigger                               | Leader location                      |
| -------------- | ------------------------------------- | ------------------------------------ |
| Self-lead      | Current agent is asked to orchestrate | Current agent in a dedicated pane    |
| Spawn a leader | User explicitly asks for another lead | New window or dedicated tmux session |

The leader occupies the left pane and workers occupy the right panes. If the
current leader shares a window with unrelated panes, isolate it before creating
worker seats. Never apply team UI or layout settings to the user's unrelated
windows.

Set a concise window title:

```bash
teamctl.sh init "<team-name>" "<task-summary>"
teamctl.sh ui "<session>"
teamctl.sh layout "<window>"
```

## Dispatch Protocol

```mermaid
flowchart LR
    U[User confirms design] --> L[Leader writes task contract]
    L --> D[Leader dispatches worker]
    D --> W[Worker loads secondary skill]
    W --> A[Worker writes artifact and receipt]
    A --> R[Leader reads validated receipt fields]
    R --> Q{Next route}
    Q -->|Verify| V[Dispatch a different worker]
    Q -->|Rework| D
    Q -->|Blocked| U
    Q -->|Deliver| F[Report status and artifact path]
```

1. Create a unique `TEAM_DIR` and initialize it.
2. Register only confirmed worker panes:

   ```bash
   teamctl.sh register-worker "<worker>" "<pane-id>"
   ```

3. Wait for CLI readiness without reading substantive pane output.
4. Write long contracts to `$TEAM_DIR/tasks/<id>.md`. Each contract must
   contain the confirmed objective, responsibility, method, inputs, allowed
   scope, acceptance criteria, dependencies, deadline, and artifact path.
5. Dispatch one physical line:

   ```bash
   teamctl.sh dispatch "<worker>" "<id>" \
     "Execute the confirmed contract at $TEAM_DIR/tasks/<id>.md."
   ```

   The helper automatically requires the worker to read the secondary skill and
   appends the artifact/receipt contract.

6. Keep one in-flight task per worker.
7. Wait only on control receipts:

   ```bash
   teamctl.sh wait 600 "<id>"
   teamctl.sh show-receipt "<id>"
   ```

8. Route `verify` and `review` to a worker other than the artifact author.
   Provide only the opaque artifact path; the leader does not open it.
9. For delivery, assign a worker to create the user-facing artifact. The leader
   reports the validated status and artifact path without reading or
   synthesizing its content.

Scheduler loops belong in a Bash file executed with `bash`; do not rely on
interactive zsh array behavior.

## Quick Reference

| Command                                      | Leader-visible effect                         |
| -------------------------------------------- | --------------------------------------------- |
| `init [name] [task]`                         | Create task, artifact, and receipt channels   |
| `ui <session>`                               | Apply session-scoped pane identity UI         |
| `layout <window> [main-width]`               | Leader left, workers evenly split right       |
| `register-worker <name> <pane-id>`           | Register one worker object                    |
| `dispatch <worker> <id> '<one-line prompt>'` | Inject worker skill and output contract       |
| `wait <timeout-s> <id>...`                   | Poll receipts without reading artifacts       |
| `show-receipt <id>`                          | Print validated control metadata              |
| `idle`                                       | List workers without an in-flight task        |
| `status`                                     | Show liveness and task state, never pane text |
| `worktree-register <name> [...]`             | Record one worker's worktree snapshot         |
| `worktree-update <name> [...]`               | Append that worker's new worktree state       |
| `worktree-board`                             | Show latest worktree control metadata         |
| `set-title [name] [task]`                    | Update the team window title                  |

## Orchestration Patterns

| Pattern            | Leader action                                                       |
| ------------------ | ------------------------------------------------------------------- |
| Fan-out            | Dispatch independent confirmed contracts to idle workers            |
| Pipeline           | Route an artifact path to the next worker after a completed receipt |
| Independent verify | Assign a different worker to inspect the prior artifact             |
| Judge panel        | Assign a worker to judge multiple opaque artifact paths             |
| Rework loop        | Route a failed verdict back to an implementation worker             |

Workers editing files in parallel need isolated git worktrees. Worktree setup
is itself a worker task unless it is purely tmux/team administration.

## Red Flags

- Leader opens anything under `artifacts/`
- Leader reads pane text or a raw receipt
- Leader says “I will quickly check/fix/summarize”
- Worker starts before reading the secondary skill
- Worker chooses a material method absent from the confirmed contract
- The artifact author verifies its own work
- Completion is inferred from pane text instead of an exact receipt sentinel

Any red flag means stop, restore the role boundary, and re-dispatch or escalate.

## Common Mistakes

| Mistake                              | Fix                                                      |
| ------------------------------------ | -------------------------------------------------------- |
| Leader reads a result to route it    | Route by validated receipt and opaque artifact path      |
| Secondary skill prescribes methods   | Put task-specific methods in the confirmed task contract |
| Worker asks questions in pane output | Write a bounded `blocked` receipt for leader escalation  |
| `capture-pane` collects answers      | Use it for neither results nor leader liveness reporting |
| `send-keys` mangles prompt text      | Use `send-keys -l`, wait 500 ms, then send `Enter`       |
| Fixed sleep implies completion       | Poll the exact receipt sentinel                          |
| Leader performs final synthesis      | Assign a delivery worker and return its artifact path    |
