# scriptorium

Git-native agent orchestration for software projects.

Scriptorium keeps planning and execution state in Git, runs a strict Architect -> Manager -> Coding workflow, and merges work only when `master` stays green.

## Status

What V1 ships:
- CLI commands: `--init`, `run`, `status`, `plan`, `worktrees`, `--version`, `--help`
- Dedicated planning branch: `scriptorium/plan`
- Automated flow: `spec.md` -> `areas/` -> `tickets/` -> code worktrees -> merge queue
- Merge safety: merge `master` into ticket branch, run `make test`, then merge or reopen
- Master-health gate: if `master` is red, orchestration halts
- Codex harness with retries, timeout handling, JSONL logging, and integration tests

## Core workflow

At a high level:

1. Engineer creates or revises `spec.md` with `scriptorium plan`.
2. Orchestrator reads `spec.md` and generates `areas/*.md` (Architect).
3. Orchestrator generates `tickets/open/*.md` from areas (Manager).
4. Oldest open ticket is assigned to a deterministic `/tmp/scriptorium/<repo-key>/worktrees/tickets/<ticket>/` worktree and moved to `tickets/in-progress/`.
5. Coding agent implements the ticket and signals completion via `submit_pr("...")`.
6. Merge queue processes one item at a time:
   - merge `master` into ticket branch
   - run `make test` in ticket worktree
   - on pass: fast-forward merge to `master`, move ticket to `tickets/done/`
   - on fail: move ticket back to `tickets/open/` and append failure notes

If `spec.md` is missing or still the placeholder, the loop idles and logs:
`WAITING: no spec — run 'scriptorium plan'`

## Quick start

### 1) Prerequisites

- Nim >= 2.0.0
- Git
- `make`
- Codex CLI for integration/e2e codex runs (`npm i -g @openai/codex`)

### 2) Build

```bash
nimby sync -g nimby.lock
make build
```

### 3) Initialize a repo

From your project root:

```bash
scriptorium --init
```

This creates the orphan branch `scriptorium/plan` with base planning structure.

### 4) Configure models (optional but recommended)

Create `scriptorium.json` in repo root:

```json
{
  "models": {
    "architect": "gpt-5.1-codex-mini",
    "coding": "gpt-5.1-codex-mini",
    "manager": "gpt-5.1-codex-mini"
  },
  "reasoning_effort": {
    "architect": "medium",
    "coding": "high",
    "manager": "high"
  },
  "endpoints": {
    "local": "http://127.0.0.1:8097"
  }
}
```

Notes:
- `endpoints.local` defaults to `http://127.0.0.1:8097` when omitted.
- Model routing is prefix-based:
  - `gpt-*` / `codex-*` -> codex harness
  - `claude-*` -> claude-code harness (routing exists)
  - anything else -> typoi harness (routing exists)
- V1 implementation is codex-first; non-codex backends are reserved for future implementation.

### 5) Build the spec

Interactive mode:

```bash
scriptorium plan
```

One-shot mode:

```bash
scriptorium plan "Add CI checks for merge queue invariants"
```

Planning execution model (both modes):
- Architect runs in a deterministic `/tmp/scriptorium/<repo-key>/worktrees/plan` worktree.
- Prompt includes repo-root path so Architect can read project source.
- Post-run write guard allows only `spec.md`; any other file edits fail the command.
- Planner/manager writes are single-flight via `/tmp/scriptorium/<repo-key>/locks/repo.lock`; concurrent planner/manager runs fail fast.

Interactive planning commands:
- `/show` prints current `spec.md`
- `/help` lists commands
- `/quit` exits

### 6) Run orchestrator

```bash
scriptorium run
```

### 7) Logging

`scriptorium run` writes a human-readable log file per session to:

```text
/tmp/scriptorium/{project_name}/run_{datetime}.log
```

- `{project_name}` is the repo directory name (e.g. `scriptorium`)
- `{datetime}` is a UTC timestamp like `2026-02-28T14-30-00Z`
- The directory is created automatically on startup

Every log line is written to both stdout and the log file with the format:

```text
[2026-02-28T14:30:00Z] [INFO] orchestrator listening on http://127.0.0.1:8097
```

Log levels: `DEBUG`, `INFO`, `WARN`, `ERROR`. Logged events include orchestrator startup, tick activity, architect/manager/coding-agent results, merge queue processing, master health checks, and shutdown signals.

To follow a live session:

```bash
tail -f /tmp/scriptorium/myproject/run_*.log
```

## CLI reference

```text
scriptorium --init [path]    Initialize workspace
scriptorium run              Start orchestrator daemon
scriptorium status           Show ticket counts and active agent info
scriptorium plan             Interactive Architect planning session
scriptorium plan <prompt>    One-shot spec update
scriptorium worktrees        List active ticket worktrees
scriptorium --version        Print version
scriptorium --help           Show help
```

## Plan branch layout

`scriptorium/plan` is the planning database. State is files + commits.

```text
spec.md
areas/
tickets/
  open/
  in-progress/
  done/
decisions/
queue/
  merge/
    pending/
    active.md
```

Key invariants:
- A ticket exists in exactly one state directory.
- Ticket state transitions are single orchestrator commits.
- No partial ticket moves are allowed.

## Testing

Local unit tests:

```bash
make test
```

- Runs `tests/test_*.nim`
- No network/API keys required

Integration tests:

```bash
make integration-test
```

- Runs `tests/integration_*.nim`
- Uses real codex execution for codex harness coverage
- Requires:
  - `codex` binary on `PATH`
  - Auth via either:
    - `OPENAI_API_KEY` or `CODEX_API_KEY`, or
    - OAuth file at `~/.codex/auth.json` (or `CODEX_AUTH_FILE` override)

## CI

- `.github/workflows/build.yml`
  - Trigger: `push`, `pull_request`
  - Runs: `make test`

- `.github/workflows/integration.yml`
  - Trigger: `push` to `master`, `workflow_dispatch`
  - Installs `@openai/codex`
  - Verifies `codex exec --help` includes `--json`
  - Runs: `make integration-test`
  - Uses repo secret `OPENAI_API_KEY` (also mapped to `CODEX_API_KEY`)

This split keeps PR CI safe while still running key-backed integration coverage on trusted `master` pushes.

## Future plans

Near-term:
- Finish deeper interactive planning integration coverage (multi-turn real codex session assertions).
- Improve planning session ergonomics (session persistence/resume).

V2 direction:
- Parallel coding agents with robust ticket locking.
- Better observability: per-ticket timings, model usage, and failure analytics.
- Cost/performance controls (model policies and budget-aware routing).

V3 direction:
- Add a dedicated merger/reviewer agent in the queue before final merge.
- Enforce spec conformance and code quality checks as a first-class review gate.

Longer horizon:
- Expand backend support beyond codex-first operation (claude-code and typoi execution paths).
- Richer interactive architect workflows with stronger MCP tool orchestration.

## License

MIT. See `LICENSE`.
