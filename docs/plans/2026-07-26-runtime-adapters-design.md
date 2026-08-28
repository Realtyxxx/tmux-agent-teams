# Runtime Adapters and Release Profiles

## Decision

Maintain one source branch for the team protocol. Keep optional `agy` support in
the repository, but exclude it from the standard Claude/Codex release by using
explicit release profiles.

## Architecture

The common package retains team state, tmux orchestration, worktree ownership,
task receipts, close, and resume policy. CLI-specific behavior moves under
`runtimes/<name>/`.

```text
skills/tmux-agent-teams/
├── SKILL.md
├── teamctl.sh
├── runtimes/
│   ├── claude/
│   │   ├── runtime.sh
│   │   ├── instructions.md
│   │   └── models.yaml
│   ├── codex/
│   │   ├── runtime.sh
│   │   ├── instructions.md
│   │   └── models.yaml
│   └── agy/
│       ├── runtime.sh
│       ├── instructions.md
│       └── models.yaml
└── worker/
    └── SKILL.md

packaging/profiles/
    ├── standard.files
    └── with-agy.files

scripts/
    └── package-releases.sh
```

`teamctl.sh` resolves only fixed runtime names and sources only
`$SCRIPT_DIR/runtimes/<name>/runtime.sh`. User input never becomes a source
path. A runtime exposes capability metadata plus namespaced helpers for session
ID validation and resume-command construction.

## Runtime Capabilities

| Runtime | Launch instructions | Session UUID | Resume      |
| ------- | ------------------- | ------------ | ----------- |
| Claude  | Included            | Supported    | Supported   |
| Codex   | Included            | Supported    | Supported   |
| agy     | Optional            | Unsupported  | Unsupported |

An `agy` Worker is recorded as non-resumable. Closing a team remains possible;
resume skips that Worker with `unsupported-resume` in the bounded report. An
`agy` Leader blocks resume because a resumed team must have a live Leader.

## Release Assembly

A tracked `scripts/package-releases.sh` packages a selected commit, not the
working tree. Both variants use the same commit and common-file list:

- `standard`: common files plus Claude and Codex runtimes.
- `with-agy`: the standard profile plus the agy runtime and model catalog.

Archive names contain the profile and 12-character commit. The script writes
`SHA256SUMS` and rejects:

- tracked working-tree changes;
- files absent from the selected commit;
- `agy` paths or text in the standard archive;
- a missing agy runtime or model catalog in the `with-agy` archive;
- core-file hash differences between variants.

Generated archives stay under ignored `release/`. The script and profile
manifests are tracked.

## Validation

Tests cover:

1. Runtime discovery and fixed-path loading.
2. Claude and Codex resume command construction.
3. Unsupported agy resume behavior for Leaders and Workers.
4. Exact profile membership.
5. Standard archive exclusion of every agy-specific file and marker.
6. Identical common-file hashes across release variants.
7. Existing team, worktree, receipt, and resume scenarios.
