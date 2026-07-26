# Claude Runtime

## Launch

```bash
command claude --dangerously-skip-permissions
```

Use `--model <model> --effort <level>` only when the user confirmed a
launch-scoped override. Otherwise keep the CLI defaults.

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
