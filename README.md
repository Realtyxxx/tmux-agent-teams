# tmux Agent Teams

An open source Agent Skill for coordinating coding agents in tmux.

## Skills

| Skill                                          | Purpose                                                                                      |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------- |
| [`tmux-agent-teams`](skills/tmux-agent-teams/) | Coordinate Claude Code and Codex workers in tmux panes with mailbox-based result collection. |

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
user confirms the team roster. Review the generated roster and target panes
before approving a launch.

## License

[MIT](LICENSE)
