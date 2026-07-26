# Changelog

## 2026-07-25

### New Features

- **Leader and worker roles:** tmux teams now use two explicit object types.
  Leaders manage user alignment, task graphs, scheduling, and escalation;
  workers own implementation, investigation, review, verification, integration,
  and delivery tasks.
- **Bundled worker interaction skill:** every dispatched worker is instructed to
  load the bundled worker skill before starting. The worker skill defines
  permissions and interaction rules without prescribing task-specific methods.
- **Per-run work design:** worker responsibilities, methods, tools, inputs, and
  acceptance criteria are confirmed with the user and recorded in each task
  contract.
- **Worktree control board:** workers can publish their own worktree, branch,
  merge-request, and status metadata without taking over team scheduling.
- **Scenario modes:** the main Skill can discover an optional workflow mode,
  read its additional constraints, and freeze the selected definition for all
  Workers. The first included mode covers multi-Worker fix/feature worktrees
  delivered through MRs or PRs.
- **Multiple teams per project:** every team now owns an isolated
  `.teams/<team-name>/` control directory and can be listed or selected by
  stable name.
- **Persistent team sessions:** Leaders record Claude Code and Codex session
  UUIDs during team creation. Closed teams can recreate panes and resume those
  sessions later.

### Improvements

- **Strict manager boundary:** leaders no longer implement, investigate, review,
  summarize, or directly inspect worker output, even under deadline pressure.
- **Separate information channels:** substantive output is stored in
  `artifacts/`, while leaders receive only bounded status metadata through
  `receipts/`.
- **Safer status reporting:** leader-visible commands report validated receipt,
  task, process, and worktree metadata without exposing pane text or artifact
  contents.
- **Independent verification:** review and verification are assigned to workers
  other than the artifact author, with final delivery produced as an opaque
  user-facing artifact.
- **Self-owned worktree rows:** worktree registration derives Worker identity
  from the verified current pane, validates MR/status transitions, and rejects
  active pane, directory, or repository-branch conflicts.
- **Project-local control plane:** runtime files and intermediate coordination
  artifacts now live under `.teams/<team-name>/`, with explicit legacy support
  for `.tmux-agent-team/`. Because a Worker's working directory can be its own
  worktree, every dispatch pins the absolute team directory instead of relying
  on the default.
- **Recoverable close/resume:** `close` requires a complete agent-session
  registry before terminating tmux. `resume` restores recorded UUIDs with fresh
  panes, skips deleted Worker worktrees, and persists a bounded resume report.
- **Safer resumed permissions:** session resume uses current CLI permission
  defaults and never silently reapplies permission-bypass flags.
- **Terminal worktree rows:** closing a row no longer requires a live checkout,
  so a Worker can finish its lifecycle in either order relative to
  `git worktree remove` and still release its seat.
- **Single-cause failures:** helpers used inside command substitutions report and
  return instead of exiting a subshell, so an uninitialized control directory is
  named once rather than surfacing as a follow-on lock or empty-field error.
- **Pane ownership by process:** a caller qualifies through the pane's
  controlling terminal or through descent from the pane's process, so an agent
  CLI's tool calls can self-register while an exported `TMUX_PANE` still cannot
  impersonate another Worker.
- **Protected team state:** `init` refuses to reset a control directory that
  already holds a registry or board, and `--force` clears the boards together
  with any frozen mode.
- **Board entry state:** registration must start at `working`, so a Worker cannot
  enter the board already in `review` or `merged`.

### Breaking Changes

- Existing integrations that read `results/<task-id>.md` must migrate to the new
  `artifacts/<task-id>.md` and `receipts/<task-id>.md` channels.
- Completion polling now accepts only an exact `DONE <task-id>` sentinel in the
  corresponding receipt.
- Team setup documentation now uses `register-worker` to make the registered
  object type explicit. The previous `register` command remains available as a
  compatibility alias.
- `worktree-register` and `worktree-update` no longer accept a Worker name,
  pane override, or directory change during updates.
- `init` no longer resets an initialized control directory without `--force`.
- New default control directories moved from `.tmux-agent-team/` to
  `.teams/<team-name>/`; explicit legacy `TEAM_DIR` values remain accepted.
- `close` now refuses teams whose Leader or Workers lack recorded CLI session
  UUIDs.

### Validation

- Verified that leaders refuse to inspect or synthesize worker artifacts.
- Verified that workers block instead of inventing an unconfirmed work method.
- Validated receipt filtering, role-separated completion polling, tmux worktree
  metadata, Markdown formatting, and Bash syntax.
- Verified in real tmux panes that a Worker self-registers without naming itself,
  cannot spoof another pane, cannot skip lifecycle states, and can close a
  worktree it already removed and then register the next one.
- Verified that dispatch pins the control directory, that an uninitialized
  control directory is reported by name, and that scenario modes stay inside the
  main Skill.
- Verified that a Worker registers from a terminal-less agent tool call, that a
  second `init` refuses to erase an active team while `--force` resets it, and
  that registration cannot start past `working`.
- Verified that two teams coexist in one project, that mode snapshots stay
  isolated by team, and that name-based selection reaches the intended state.
- Verified against real tmux panes that a closed team resumes the recorded
  Codex UUID while a deleted Claude Worker worktree is skipped and reported.
