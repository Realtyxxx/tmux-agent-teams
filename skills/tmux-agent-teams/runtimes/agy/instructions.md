# agy Runtime

## Launch

```bash
command agy --dangerously-skip-permissions
```

Select models only from `model-catalog.json`. Use `--model "<exact name>"` for a
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
