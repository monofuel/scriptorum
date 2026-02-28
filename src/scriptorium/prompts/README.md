# Prompt Templates

All model-facing prompt text is centralized in this directory and bundled at compile time via `staticRead()`.

## Placeholder Style

- Placeholders use `{{UPPER_SNAKE_CASE}}` markers.
- Runtime renderers must provide all placeholders expected by a template.
- Rendering fails fast when placeholders are missing or unresolved.

## Templates

- `coding_agent.md`: coding-agent ticket execution prompt.
- `architect_areas.md`: Architect area generation prompt.
- `manager_tickets.md`: Manager ticket generation prompt.
- `plan_scope.md`: shared plan worktree and read-scope context.
- `architect_plan_oneshot.md`: one-shot `scriptorium plan <prompt>` prompt.
- `architect_plan_interactive.md`: per-turn interactive `scriptorium plan` prompt.
- `codex_retry_continuation.md`: retry continuation prompt for codex harness.
- `codex_retry_default_continuation.md`: default retry continuation sentence.
