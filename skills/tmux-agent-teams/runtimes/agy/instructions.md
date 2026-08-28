# agy Runtime

## Launch

```bash
command agy --dangerously-skip-permissions
```

When no model is explicitly specified by the user, default to `--model "Gemini 3.7 Flash (High)"`.
Select models from `models.yaml`. Use `--model "<exact name>"` for a
launch-scoped override. Model-cache refresh remains manual and requires an
explicit user request.

This runtime does not expose a stable session UUID or resume command. Register
it with session ID `-`. A closed agy Worker is skipped with
`unsupported-resume`; an agy Leader cannot resume a Team.

Read-only discovery commands:

```bash
command agy --version
command agy models
```

Do not use `/model` automation or modify the user's agy configuration during
Team setup.
