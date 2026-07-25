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

### Breaking Changes

- Existing integrations that read `results/<task-id>.md` must migrate to the new
  `artifacts/<task-id>.md` and `receipts/<task-id>.md` channels.
- Completion polling now accepts only an exact `DONE <task-id>` sentinel in the
  corresponding receipt.
- Team setup documentation now uses `register-worker` to make the registered
  object type explicit. The previous `register` command remains available as a
  compatibility alias.

### Validation

- Verified that leaders refuse to inspect or synthesize worker artifacts.
- Verified that workers block instead of inventing an unconfirmed work method.
- Validated receipt filtering, role-separated completion polling, tmux worktree
  metadata, Markdown formatting, and Bash syntax.
