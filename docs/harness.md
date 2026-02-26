# Harness Notes (Copied From Racha Issue-Fixer Daemon)

Scope: notes copied from `../Racha` issue-fixer daemon and CI automation for `codex` and `claude` backends only.

## Daemon Dispatch Flow

Source files:
- `../Racha/src/daemons/issues.nim`
- `../Racha/src/fixer/dispatcher.nim`
- `../Racha/src/fixer/utils.nim`
- `../Racha/src/fixer/constants.nim`

Behavior:
- Poll loop runs continuously (`PollIntervalMs = 10_000`).
- Daemon scans accessible repositories, fetches open issues, and filters to fixer labels.
- Issues are skipped if already `racha-processing`, already `racha-dispatch`, or already linked to an open PR.
- Backend selection is label-driven:
  - `claude-fixer` -> `claude`
  - `codex-fixer` -> `codex`
  - fallback default backend is `codex`
- Daemon marks issue as dispatched (`racha-dispatch`) and assigns to `racha`.
- Dispatcher creates a temporary dispatch branch in target repo with an empty commit.
- Dispatcher also creates a matching dispatch branch in workflow repo (`monolab/Racha`).
- Workflow is dispatched (`racha-fixer.yml`) with inputs:
  - `owner`, `repo`, `issue`, `backend`, `project_type`, `model`, `provider`

## CI Workflow Automation

Source file:
- `../Racha/.gitea/workflows/racha-fixer.yml`

Codex/Claude setup notes:
- Workflow is `workflow_dispatch` with `backend` defaulting to `codex`.
- CI installs Linux dependencies plus Node/npm and TypeScript.
- Codex handling in CI:
  - Downloads Rust codex binary directly (`codex-x86_64-unknown-linux-musl`).
  - Also installs `@openai/codex@native` with npm.
  - Includes retry/guard logic if `codex` command is missing.
- Claude handling in CI:
  - Installs `@anthropic-ai/claude-code` if `claude` command is missing.
- Codex config created at `~/.codex/config.toml`:
  - `web_search = "disabled"`
  - `forced_login_method = "api"`
  - `env_key = "OPENAI_API_KEY"`
- Runner environment verifies tool availability (`codex --version`, `claude --version`).
- Fixer run env includes:
  - `OPENAI_API_KEY`
  - `CODEX_API_KEY` (set equal to `OPENAI_API_KEY`)
  - `ANTHROPIC_API_KEY`
  - `CODEX_QUIET_MODE=1`

## Backend Execution Details

Source file:
- `../Racha/src/fixer/executor.nim`

### Codex

- Executor requires Rust codex-cli and validates version (`codex-cli >= 0.2.0`).
- TypeScript codex output format is treated as unsupported.
- Command shape:
  - `codex --model <model> exec --dangerously-bypass-approvals-and-sandbox <prompt>`
- For Nim/Metta project types, adds:
  - `--skip-git-repo-check`
- Default codex model:
  - `gpt-5.2-codex`
- Label-based codex model overrides:
  - `model-gpt-5.2-codex`
  - `model-gpt-5.3-codex`

### Claude

- Command shape:
  - `claude --dangerously-skip-permissions --verbose --add-dir /root/.nimble/ --add-dir /home/runner/.nimble/ --output-format stream-json --print --model <model>`
- Prompt is provided on stdin.
- Output is streamed and captured line-by-line.
- Default Claude model:
  - `claude-opus-4-6`
- Label-based Claude model overrides:
  - `model-claude-opus-4-6`
  - `model-claude-sonnet-4-5`
  - `model-claude-haiku-4-5`

## Extra Execution Notes

Source file:
- `../Racha/src/fixer/rachafix.nim`

- Fix prompt embeds project `AGENTS.md` when present.
- For Nim projects, fixer runs `nimble test` after backend execution.
- If tests fail, fixer invokes the backend a second time with a test-failure repair prompt.
- On success, changes are committed/pushed from a fix branch.
