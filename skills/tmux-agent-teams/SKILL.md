---
name: tmux-agent-teams
description: "Use when a confirmed team of external coding-agent runtimes must cooperate in tmux panes, especially when the current agent must remain a manager and substantive work must stay isolated in worker artifacts. Triggers: 多个 agent 协作, tmux 面板编排, leader worker, agent team, multi-agent tmux."
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

| Plane          | Path                          | Producer | Reader                   | Content                           |
| -------------- | ----------------------------- | -------- | ------------------------ | --------------------------------- |
| Task contract  | `$TEAM_DIR/tasks/<id>.md`     | Leader   | Assigned worker          | Confirmed work instructions       |
| Work artifact  | `$TEAM_DIR/artifacts/<id>.md` | Worker   | Other assigned workers   | Findings, code review, synthesis  |
| Receipt        | `$TEAM_DIR/receipts/<id>.md`  | Worker   | Leader through `teamctl` | Bounded status metadata           |
| Task board     | `$TEAM_DIR/board.tsv`         | Helper   | Leader                   | Assignment and completion state   |
| Worktree board | `$TEAM_DIR/worktrees.tsv`     | Worker   | Leader and workers       | Path, branch, MR, and state       |
| Agent registry | `$TEAM_DIR/agents.tsv`        | Leader   | Lifecycle helper         | Runtime session IDs and work dirs |
| Resume report  | `$TEAM_DIR/resume-report.tsv` | Helper   | Leader and user          | Resumed and skipped agent rows    |
| Mode snapshot  | `$TEAM_DIR/mode.md`           | Helper   | Leader and workers       | Selected scenario constraints     |

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
| Runtime and model    | Installed adapter plus launch-scoped model choice         |
| Artifact destination | The work product another worker or the user will consume  |

The secondary skill defines only interaction. It does not choose technical
methods. The leader proposes methods from the user's request, asks the user to
resolve material choices, and records confirmed methods in each task contract.

If the user changes scope or method, update the design and obtain confirmation
before dispatching affected tasks.

## Scenario Mode Selection

Modes extend this generic protocol with constraints for a recognizable team
workflow. They never replace its permissions, confirmation gates, mailbox
contracts, pane ownership, or safety rules.

Before designing the roster:

1. Read [`modes/INDEX.md`](modes/INDEX.md).
2. Match the user's request against the trigger descriptions.
3. If exactly one mode matches, read `modes/<mode>/MODE.md` completely and
   include the selected mode in the team design.
4. If multiple modes plausibly match, present the matching names and let the
   user select one before reading and applying it.
5. If no mode matches, continue with the generic protocol.

When the user explicitly names a registered mode, select and read that mode
directly. A mode is active only after its `MODE.md` has been read; recognizing a
trigger from the index is not enough.

After the user confirms the team design and `teamctl.sh init` succeeds, freeze
the selected mode for the team:

```bash
TEAM_DIR="$PWD/.teams/<team-name>" \
  bash /path/to/tmux-agent-teams/modes/apply-mode.sh "<mode>"
```

This creates the immutable runtime snapshot
`.teams/<team-name>/mode.md`. Every Worker governed by the mode must read that
snapshot before starting its task.
Do not apply a mode when using the generic protocol, and do not switch modes
inside an active team directory.

## Runtime and Model Policy

List the adapters installed in the current package:

```bash
teamctl.sh runtimes
```

Before proposing or launching a runtime, read the reported
`runtimes/<name>/instructions.md` completely. It owns that CLI's launch
command, session-ID strategy, resume capability, model flags, and discovery
commands. Never infer those details from another runtime.

Use launch-scoped model flags only. Never type `/model` or edit persistent CLI
configuration. If the user does not name a model, use the runtime's documented
default. If the user names a model, follow the runtime instructions and its
optional catalog. A missing or unusable cache is a user decision point; never
refresh it automatically.

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
TEAM_DIR=$(teamctl.sh init "<team-name>" "<task-summary>")
TEAM_DIR="$TEAM_DIR" teamctl.sh ui "<session>"
TEAM_DIR="$TEAM_DIR" teamctl.sh layout "<window>"
```

New teams use the project Git root's `.teams/<team-name>/` directory. The name
is the stable selector for `teamctl.sh --team <team-name> ...`; `teamctl.sh
teams` lists every team in the project. `init` refuses to replace an existing
team. Resetting on purpose requires `--force`, which clears its registries and
boards and drops any frozen mode.

## Agent Session Registry

The leader MUST record every runtime while creating the team, before
dispatching substantive work. Resumable runtimes record their session UUID;
non-resumable runtimes use session ID `-`. `close` refuses an incomplete
roster.

```bash
TEAM_DIR="$TEAM_DIR" teamctl.sh register-leader \
  "<leader>" "<pane-id>" "<runtime>" "<session-uuid|->" "<working-dir>"
TEAM_DIR="$TEAM_DIR" teamctl.sh register-worker "<worker>" "<pane-id>"
TEAM_DIR="$TEAM_DIR" teamctl.sh record-agent-session \
  worker "<worker>" "<runtime>" "<session-uuid|->" "<working-dir>"
```

Follow the selected runtime instructions to obtain its session ID. During pane
bootstrap, return only that ID through bounded control metadata, then let the
leader call `record-agent-session`. Do not scrape the pane or a transcript for
an ID.

The registry stores role, stable name, runtime, session ID, canonical working
directory, pane ID, and lifecycle state. All registered agents must belong to
the same tmux session.

## Team Close and Resume

```mermaid
flowchart LR
    A[Active team] -->|close| C[Closed team]
    C -->|resume| R{Agent input available?}
    R -->|Leader unavailable| B[Resume blocked]
    R -->|Worker input or resume capability missing| S[Worker skipped and reported]
    R -->|Available| P[Fresh pane resumes session]
    P --> A
    S --> A
```

`teamctl.sh close` persists `closed` state before terminating the recorded tmux
session. `teamctl.sh resume` asks each installed runtime adapter to construct
its resume command. Resume does not reapply permission-bypass flags; current
CLI permission defaults apply.

For a Worker with a worktree-board row, that recorded worktree is the resume
directory. If it has been deleted, the Worker is skipped and reported as
`missing-worktree`; a non-resumable Worker is skipped as
`unsupported-resume`; other resumable agents still start. A missing,
non-resumable, or unavailable Leader runtime blocks resume. Every attempt writes
`$TEAM_DIR/resume-report.tsv`. A resumed Worker also gets a new worktree-board
snapshot that binds its existing lifecycle row to the fresh pane ID.

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

1. Run `init <team-name> ...` and use its returned
   `<project-root>/.teams/<team-name>` path as `TEAM_DIR`. Every runtime control
   file and intermediate coordination artifact stays under that team
   directory.
2. Register the leader session and each confirmed worker pane. Record every
   Worker session UUID before dispatch:

   ```bash
   TEAM_DIR="$TEAM_DIR" teamctl.sh register-worker "<worker>" "<pane-id>"
   TEAM_DIR="$TEAM_DIR" teamctl.sh record-agent-session \
     worker "<worker>" "<runtime>" "<session-id>" "<working-dir>"
   ```

3. Wait for CLI readiness without reading substantive pane output.
4. Write long contracts to `$TEAM_DIR/tasks/<id>.md`. Each contract must
   contain the confirmed objective, responsibility, method, inputs, allowed
   scope, acceptance criteria, dependencies, deadline, and artifact path.
5. Dispatch one physical line:

   ```bash
   TEAM_DIR="$TEAM_DIR" teamctl.sh dispatch "<worker>" "<id>" \
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

| Command                                                 | Leader-visible effect                         |
| ------------------------------------------------------- | --------------------------------------------- |
| `runtimes`                                              | List installed adapters and resume capability |
| `init <name> [task] [--force]`                          | Create `.teams/<name>` control channels       |
| `teams`                                                 | List project team names and lifecycle states  |
| `--team <name> <command>`                               | Select one project team                       |
| `ui <session>`                                          | Apply session-scoped pane identity UI         |
| `layout <window> [main-width]`                          | Leader left, workers evenly split right       |
| `register-leader <name> <pane> <runtime> <id> [dir]`    | Record the Leader runtime and session         |
| `register-worker <name> <pane> [<runtime> <id> [dir]]`  | Register a Worker and optional session        |
| `record-agent-session <role> <name> <runtime> <id> ...` | Add session metadata after pane bootstrap     |
| `close`                                                 | Persist state and close the team tmux session |
| `resume`                                                | Resume recorded IDs and report skipped agents |
| `dispatch <worker> <id> '<one-line prompt>'`            | Inject worker skill and output contract       |
| `wait <timeout-s> <id>...`                              | Poll receipts without reading artifacts       |
| `show-receipt <id>`                                     | Print validated control metadata              |
| `idle`                                                  | List workers without an in-flight task        |
| `status`                                                | Show liveness and task state, never pane text |
| `worktree-register [--dir path] [...]`                  | Self-register the calling Worker's worktree   |
| `worktree-update [--mr id] [--status state]`            | Append the calling Worker's new state         |
| `worktree-board`                                        | Show latest worktree control metadata         |
| `set-title [name] [task]`                               | Update the team window title                  |

## Worktree Board Protocol

Workers invoke worktree commands from their own registered tmux panes. The helper
derives the Worker and pane ID from the calling process, so callers cannot supply
another identity. A caller is accepted when its controlling terminal is the
pane's terminal, or when it descends from the pane's process, which is how an
agent CLI's tool calls qualify. Exporting `TMUX_PANE` satisfies neither. Each
visible row contains:

| Field              | Source                                              |
| ------------------ | --------------------------------------------------- |
| Worker             | Reverse lookup of the calling pane in `workers.tsv` |
| Pane ID            | Current verified tmux pane                          |
| MR ID              | Worker-supplied `!<number>`, `#<number>`, or `-`    |
| Worktree directory | Canonical Git top-level directory                   |
| Branch             | Current attached branch                             |
| Status             | Validated lifecycle state                           |

Identity comes from the pane, but the control directory does not. A Worker's
working directory may be its own worktree, where the project owner's
`.teams/<team-name>/` control directory does not exist, so every dispatch pins
the absolute control directory and Workers pass it explicitly:

```bash
TEAM_DIR="<control-dir>" teamctl.sh worktree-register \
  --dir "<absolute-worktree-path>"
TEAM_DIR="<control-dir>" teamctl.sh worktree-update --mr '!123' --status review
teamctl.sh worktree-board
```

The lifecycle is:

```mermaid
stateDiagram-v2
    [*] --> working
    working --> blocked
    blocked --> working
    working --> review
    review --> working
    review --> merged
    working --> closed
    blocked --> closed
    review --> closed
    merged --> closed
```

Registration always starts at `working`; a Worker cannot enter the board at a
later state. `review` and `merged` require an MR/PR ID. A Worker can have only
one active row. Active rows cannot reuse another Worker's pane, directory, or branch from
the same repository. A `closed` row is immutable and releases those resources
for a later registration.

Every state except `closed` is verified against the live checkout, so the
recorded directory must still be a Git worktree on an attached branch. `closed`
is exempt: removing the worktree is a normal end of its lifecycle, so a row can
be closed before or after `git worktree remove` and keeps the directory and
branch recorded at registration time.

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
