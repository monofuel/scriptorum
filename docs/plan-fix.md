# Plan Fix: Consistent Planning Execution Model

## Problem

Current behavior is inconsistent:

- `scriptorium plan <prompt>` (one-shot) runs Architect with repo root as working dir.
- `scriptorium plan` (interactive) runs Architect with plan worktree as working dir.

This split is confusing and makes planning behavior drift between modes.

## Target Behavior

- Architect always runs with `workingDir = plan worktree`.
- Architect is told the repo root path so it can read project source.
- Architect plan mode can only mutate planning artifacts (for `plan`, only `spec.md`).
- One-shot and interactive planning use the same execution model.

## Design Direction

- Run Architect from plan worktree in both modes so writes to `spec.md` land naturally.
- Pass the repo root path to the Architect prompt so it can read project source files.
- No snapshot or copy — just two paths: workdir (plan worktree) for writes, repo path for reads.
- Enforce write guards: after Architect runs, reject any changes outside the allowed set.

## Implementation Plan

- [ ] `PF-01` Lock current behavior with tests before refactor.
  - Add tests that assert current one-shot and interactive working-dir behavior so the migration is explicit.

- [ ] `PF-02` Unify working dir to plan worktree.
  - Change one-shot planning to use `workingDir = plan worktree` (matching interactive).
  - Pass repo root path to the Architect prompt so it can read source files.
  - Remove any code that sets one-shot working dir to repo root.

- [ ] `PF-03` Add write guards.
  - After Architect execution, check which files were modified.
  - For `scriptorium plan`, allow `spec.md` changes only.
  - If Architect edits out-of-scope files, fail with clear error.
  - Implement guards as a configurable allowlist (not hardcoded to `spec.md`) so future commands can define their own allowed set.

- [ ] `PF-04` Update Architect prompt scaffolding.
  - Include repo root path in prompt context.
  - Instruct Architect to read project source from that path and only edit `spec.md` in the working dir.

- [ ] `PF-05` Add tests for new behavior.
  - Both modes use plan worktree as working dir.
  - Architect can read project source files via repo path.
  - Out-of-scope edits are rejected by write guards.
  - Integration test: fixture repo with a source marker, stub Architect reads it from repo path and writes to `spec.md`, assert commit on `scriptorium/plan`.

- [ ] `PF-06` Clean up.
  - Remove legacy working-dir branching logic.
  - Update README and command docs.

## Acceptance Criteria

- [ ] One-shot and interactive planning use the same workdir model.
- [ ] Architect can read project state in both modes.
- [ ] Planning mode cannot silently mutate non-plan files.
- [ ] `make test` passes.
