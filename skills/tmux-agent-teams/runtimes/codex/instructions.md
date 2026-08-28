# Codex Runtime

## Launch

```bash
command codex --dangerously-bypass-approvals-and-sandbox
```

When no model is explicitly specified by the user, keep the CLI defaults (e.g. `gpt-5.6-sol`).
Consult `models.yaml` for available models and supported reasoning effort levels.
Use `-m <model> -c 'model_reasoning_effort="<level>"'` only when the user
confirmed a launch-scoped override.

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
