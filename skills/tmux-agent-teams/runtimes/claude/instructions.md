# Claude Runtime

## Launch

```bash
command claude --dangerously-skip-permissions --model opus
```

When no model is explicitly specified by the user, default to `--model opus`.
Consult `models.yaml` for available models and supported effort levels.
Use `--model <model> --effort <level>` when the user confirmed a
launch-scoped override.

Generate a UUID before launch and pass it with `--session-id <uuid>`. Record the
same UUID in the Team agent registry. Resume uses `claude --resume <uuid>` and
the current CLI permission defaults.

Read-only discovery commands:

```bash
command claude --version
command claude --help
```

Do not launch an interactive session only to enumerate models, and never modify
the user's Claude configuration during Team setup.
