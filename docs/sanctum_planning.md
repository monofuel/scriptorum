# Scriptorium Interactive Planning

## Goal

Add an interactive multi-turn conversation mode to `scriptorium plan`, powered by Codex.
The one-shot `scriptorium plan <prompt>` path remains unchanged for automation.

## Current Behavior

- `scriptorium plan <prompt...>` runs one Codex execution via `updateSpecFromArchitect`
  in `src/scriptorium/orchestrator.nim`.
- It rewrites `spec.md` in one pass and commits if changed.
- There is no interactive loop; every invocation starts from a blank context.

## Target Behavior

- `scriptorium plan` (no args) opens a multi-turn terminal conversation with the Architect.
- Spec changes are committed automatically after each turn that modifies `spec.md`.
- `scriptorium plan <prompt...>` (with args) is unchanged.

## Interaction Model

The session is an orchestrator-driven REPL. Each turn:

1. Read user input from the terminal.
2. If input starts with `/`, dispatch to a command handler (see below).
3. Otherwise, build a Codex prompt: architect system prompt + current `spec.md`
   content + in-memory turn history + user message.
4. Run Codex one-shot via the existing harness (`runAgent`) with the plan worktree
   as the working directory.
5. Display Codex's text response.
6. If `spec.md` changed, commit it to the plan branch with a session turn message.
7. Loop.

Codex edits `spec.md` directly in the plan worktree using its native file tools.
No draft file, no explicit apply step. If the engineer runs `scriptorium plan`,
they are ready to make changes.
Turn history is kept in memory; no persistence for this phase.

## REPL Commands

| Command  | Effect                                                        |
|----------|---------------------------------------------------------------|
| `/show`  | Print the current contents of `spec.md`                      |
| `/quit`  | Exit the session (changes already committed are kept)         |
| `/help`  | Print available commands                                      |

## Scope

- Codex harness only.
- One active planning session at a time per workspace.
- In-memory conversation history (no persistence across restarts).

## V1 Trade-offs

These are known limitations accepted for MVP. Each has a clear future improvement path.

**Codex has full write access to the plan worktree.**
The working directory passed to Codex is the plan worktree, which contains `areas/`,
`tickets/`, `decisions/`, and `spec.md`. Codex can modify any of these with its file
tools. For V1 this is acceptable — the Architect is trusted and the plan branch is
append-friendly. Future: scope the working directory to a temp copy of just `spec.md`,
or restrict Codex's file tools to a whitelist of paths.

**No undo.** Commits happen automatically per turn. A bad turn is already in git history;
recovery requires a manual `git revert` on the plan branch. Future: add a `/undo` command
that reverts the most recent plan-session commit.

**Ctrl+D is not handled.** EOF on stdin has undefined behaviour in V1. Future: treat EOF
as equivalent to `/quit`.

**Shared plan worktree with a running orchestrator.** If `scriptorium run` is active
while `scriptorium plan` is running, both processes share the plan branch worktree. The
orchestrator can commit between planning turns, which may confuse the pre-turn snapshot
used to detect spec changes. Future: lock the plan worktree during a planning session, or
give `scriptorium plan` its own dedicated worktree checkout.

## Non-Goals

- Claude-code and typoi harness support (future).
- Session persistence and resume (future).
- Custom MCP tools or policy enforcement during planning sessions (future).
- Reworking orchestrator run-loop behavior.

## Implementation Plan

- [x] `SP-01` Add CLI mode split:
  - `scriptorium plan` (no args) → interactive mode.
  - `scriptorium plan <prompt...>` → existing one-shot path, unchanged.
  - Entry point: `src/scriptorium.nim`; one-shot path calls `updateSpecFromArchitect`.
  - Test: CLI parsing test verifies both routes.

- [x] `SP-02` Use plan worktree as Codex working directory:
  - Pass the existing plan branch worktree path as `workingDir` to `runAgent` each turn.
  - After each turn, compare `spec.md` content to the pre-turn snapshot; if changed,
    commit to the plan branch with message `scriptorium: plan session turn <N>`.
  - Test: unit test verifies a changed `spec.md` produces a commit and unchanged does not.

- [x] `SP-03` Add conversation loop and prompt assembly:
  - Maintain an in-memory seq of `(role, text)` turn pairs.
  - Build the Codex prompt from: architect system prompt + current `spec.md` content +
    prior turns + current user message.
  - Run `runAgent` for each user turn; display the last message as the response.
  - Test: unit test with a fake agent runner verifies prompt assembly and turn recording.

- [x] `SP-04` Add REPL command handlers:
  - `/show` — read and print current `spec.md`.
  - `/quit` — exit the session cleanly.
  - `/help` — print command list.
  - Test: unit tests for each handler.

- [ ] `SP-05` Add integration happy path:
  - Start an interactive session against a real plan branch fixture.
  - Feed two turns via piped stdin; assert responses are captured.
  - Verify the plan branch has a new commit after a turn that modifies `spec.md`.
  - Test: integration test using a low-cost Codex model.

## Testing Strategy

- `make test`:
  - CLI route parsing (SP-01).
  - Per-turn commit behavior: changed vs unchanged `spec.md` (SP-02).
  - Prompt assembly and turn recording (SP-03).
  - REPL command handlers (SP-04).

- `make integration-test`:
  - Full session with real Codex.
  - Verify spec commit is created after a turn that modifies `spec.md`.

## Rollout

- Phase 1: ship interactive mode; one-shot path unchanged.
- Phase 2: add session persistence so an in-progress session survives a restart.
- Phase 3: add Claude-code and typoi harness support.

## Definition of Done

- `scriptorium plan` (no args) opens an interactive Architect conversation via Codex.
- `scriptorium plan <prompt...>` still works for automation.
- Spec changes are committed automatically after each turn that modifies `spec.md`.
- Turns that produce no spec change make no commit.
- Unit and integration tests are green.
