# tmux Agent Teams

An open source Agent Skill for coordinating coding agents in tmux with strict
leader/worker role separation.

## Skill Architecture

| Skill                                                          | Loaded by | Purpose                                                    |
| -------------------------------------------------------------- | --------- | ---------------------------------------------------------- |
| [`tmux-agent-teams`](skills/tmux-agent-teams/SKILL.md)         | Leader    | Negotiate, schedule, route, and report control-plane state |
| [`tmux-agent-worker`](skills/tmux-agent-teams/worker/SKILL.md) | Worker    | Define worker interaction and output boundaries            |

The worker skill is bundled inside the main package. The leader reads only the
primary skill. Every dispatch automatically tells the assigned worker to read
the secondary skill.

Task-specific implementation, investigation, review, and verification methods
are not hard-coded in either role. The leader proposes them to the user as part
of the roster and writes the confirmed choices into each task contract.

## Branches

| Branch     | Supported agent CLIs           |
| ---------- | ------------------------------ |
| `main`     | Claude Code and Codex.         |
| `with-agy` | Claude Code, Codex, and `agy`. |

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

## Requirements

- Bash
- tmux
- At least one supported agent CLI

## Security

`tmux-agent-teams` can launch agent CLIs with their full-access flags after the
user confirms the team roster and work methods. The leader does not read worker
artifacts; it observes validated receipts and opaque artifact paths. Review the
generated roster, methods, permissions, and target panes before approving a
launch.

## License

[MIT](LICENSE)
