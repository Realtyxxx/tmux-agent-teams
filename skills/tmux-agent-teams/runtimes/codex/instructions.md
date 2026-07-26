# Codex Runtime

## Launch

```bash
command codex --dangerously-bypass-approvals-and-sandbox
```

Use `-m <model> -c 'model_reasoning_effort="<level>"'` only when the user
confirmed a launch-scoped override. Otherwise keep the CLI defaults.

Codex assigns the session UUID. Its tool subprocesses expose the current value
as `CODEX_THREAD_ID`; return only that UUID through bounded control metadata and
record it in the Team agent registry. Resume uses
`codex resume -C <working-dir> <uuid>` and the current CLI permission defaults.

Read-only discovery commands:

```bash
command codex --version
command codex debug models
command codex doctor --json
```

Do not use `/model` automation or modify the user's Codex configuration during
Team setup.
