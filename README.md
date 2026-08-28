# tmux Agent Teams

An open source Agent Skill for coordinating coding agents in tmux with strict
leader/worker role separation.

## Skill Architecture

| Skill                                                          | Loaded by | Purpose                                                    |
| -------------------------------------------------------------- | --------- | ---------------------------------------------------------- |
| [`tmux-agent-teams`](skills/tmux-agent-teams/SKILL.md)         | Leader    | Negotiate, schedule, route, and report control-plane state |
| [`tmux-agent-worker`](skills/tmux-agent-teams/worker/SKILL.md) | Worker    | Define worker interaction and output boundaries            |
| [`modes/`](skills/tmux-agent-teams/modes/INDEX.md)             | On match  | Add scenario-specific planning and lifecycle constraints   |

The worker skill is bundled inside the main package. The leader reads only the
primary skill. Every dispatch automatically tells the assigned worker to read
the secondary skill.

Task-specific implementation, investigation, review, and verification methods
are not hard-coded in either role. The leader proposes them to the user as part
of the roster and writes the confirmed choices into each task contract.

The main Skill reads the mode index when designing a team. If the user's
workflow matches one registered trigger, the Leader reads that mode before
proposing the roster. After confirmation, the selected mode is frozen to
`.teams/<team-name>/mode.md`, and every governed Worker reads the same snapshot.

| Included mode    | Trigger                                                                                                     |
| ---------------- | ----------------------------------------------------------------------------------------------------------- |
| `fix-feature-mr` | Multiple Workers own isolated fix/feature worktrees and branches, then deliver and review separate MRs/PRs. |

All runtime control files and intermediate coordination artifacts use isolated
project-local `.teams/<team-name>/` directories. `teamctl.sh teams` lists them,
and `teamctl.sh --team <team-name> ...` selects one without conflating teams in
the same repository.

## Persistent Team Sessions

The Leader records each installed runtime's session ID, working directory, and
tmux pane for itself and every Worker during team creation. A team cannot close
until this registry is complete. Runtime-specific launch, model, session, and
resume behavior lives under `runtimes/<name>/`.

`teamctl.sh close` persists lifecycle state and closes the tmux session.
`teamctl.sh resume` creates fresh panes and resumes each recorded runtime session.
Deleted Worker worktrees are skipped and reported in
`.teams/<team-name>/resume-report.tsv`; they do not prevent the remaining
sessions from resuming.

## Release Profiles

Both release variants are assembled from one commit, so optional runtime
support cannot drift from the common Team protocol.

| Profile    | Included runtimes             |
| ---------- | ----------------------------- |
| `standard` | Claude Code and Codex         |
| `with-agy` | Claude Code, Codex, and `agy` |

Create both archives and their checksum manifest:

```bash
scripts/package-releases.sh
```

## Install

List the skills in this repository:

```bash
npx skills add Realtyxxx/tmux-agent-teams --list
```

Install `tmux-agent-teams`:

```bash
npx skills add Realtyxxx/tmux-agent-teams --skill tmux-agent-teams
```

Install it globally for Codex and Claude Code:

```bash
npx skills add Realtyxxx/tmux-agent-teams \
  --skill tmux-agent-teams \
  --global \
  --agent codex \
  --agent claude-code
```

## Optional Task Board

`.teams/<team-name>/` control files (`board.tsv`, `flow.tsv`, `worktrees.tsv`,
receipts) are the board; `teamctl.sh status`, `worktree-board`, and
`show-receipt` read them directly with no extra dependency.

For a graphical view, install the separate
[`agent-board`](https://github.com/Realtyxxx/agent-board-skill) skill — it is
not bundled with either release profile:

```bash
git clone https://github.com/Realtyxxx/agent-board-skill
node agent-board-skill/bin/install.js --force
```

## Requirements

- Bash
- tmux
- At least one supported agent CLI
- Optional: the `agent-board` skill, only for the graphical task board

## Security

`tmux-agent-teams` can launch agent CLIs with their full-access flags after the
user confirms the team roster and work methods. The leader does not read worker
artifacts; it observes validated receipts and opaque artifact paths. Review the
generated roster, methods, permissions, and target panes before approving a
launch. Session resume does not silently reapply permission-bypass flags.

## License

[MIT](LICENSE)
