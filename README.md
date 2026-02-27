# scriptorium

- the "cathedral" of agent orchestration


## rough plan


have a top level tool, `scriptorium` with commands like `scriptorium --init` to create a workspace
- you work with 'the architect' (mayor, top manager) to create a spec
- the spec gets built out into a larger concrete plan
- strict heirarchy
- managers manage coding agents

- use git worktrees
- a dedicated 'merging' agent that does code review, ensure it matches the spec, runs tests and merges to master
- must ensure master is always passing on tests. tests must pass before merging to master to keep it green. if master fails, everything has to hault, perhaps have an agent that fixess broken master?

- everything is iterative.
- architect makes a master plan, which gets broken up into docs, which eventually filter down into code.
- smart agents have to handle planning, can rely on cheaper agents as it goes down
- would like to take advantage of my locally hosted gpt oss 20b and 120b
- perhaps if agents get stuck, they could get 'promoted' to smarter models

- potential later features: maybe managers could have budgets? token budgets, weighted on token prices for smarter models?
- could have a dedicated planning branch separate from the rest of the project (eg: like how github pages are separate) that is the database
- no real database, everything is just markdown files committed in the special planning branch and tracked in git.

- agents can work entirely through MCP servers. very simple, all runs local.
- messages would only flow up/down through the heirarchy
  - coding agents could ask questions that filter up through the managers, answers filter back down
  - some problems might require the plans be adjusted (eg: maybe a library doesn't support a feature we thought it had and we have to change things up)

- should work interchangeably with codex, claude-code, or my own typoi cli agent tool.

- in contrast to gastown, the scriptorium would be very opinionated with my own opinions.
- as an agent orchestrator, it should be capable of making the 'v2' version of itself, or v3, v4, and so on.

- we should probably have a folder like ./prompts/ that contains the base system prompts for the agents, like architect.md, manager.md, coding_agent.md, merging_agent.md, etc.

- the scriptorium should perform it's own upgrades to ensure it is working.
- we should have unit tests and small integration tests.
  - eg: architect tests, manager tests, coding agent tests, merging agent tests.

- V1 will be MVP. a minimal agent orchestrator that can manage itself.
  - probably just have a static heirarchy of 1 architect, 1 manager, and 1 coding agent.
- V2 should have statistics and logging (eg: how often do certain models get stuck, what types of task fail) we should also do predictions on how hard a task is and how long it will take and record how long it actually took.
- V3 should introduce the merger agent.
  - the merger agent inserts a code review step into the merge queue, between tests passing and merging to master.
  - merger agent checks that the code matches the ticket spec and meets quality standards before approving.


## V1 — MVP

The north star for V1: **it must be capable of building V2 on its own, given the V2 spec.**

This defines the minimum bar. V1 doesn't need to be elegant or fast — it needs to be
correct enough that an Architect can read a spec, decompose it into tickets, a coding agent
can execute those tickets, and the result passes tests. If V1 can do that for a non-trivial
spec (its own V2), it is done.

### V1 Agent Hierarchy

```
Orchestrator (code — HTTP MCP server, event loop, task queue, merge queue)
  ├── Architect (1x, large model — spec → areas)
  ├── Manager  (1x, medium model — area → tickets)
  └── Coding Agent (1x, small model — ticket → code)
```

All three agents communicate with the orchestrator over HTTP MCP. The orchestrator is the
sole source of order and locking — no agent touches the plan branch or the filesystem
directly.

### V1 Capabilities

- `scriptorium --init` sets up a new workspace with a planning branch and blank `spec.md`
- `scriptorium run` starts the orchestrator daemon: HTTP MCP server + event loop
- Architect is invoked when areas are missing; it reads `spec.md` and creates area files
- Manager is invoked per area when that area has no open tickets; it reads the area file and creates tickets
- Orchestrator assigns the oldest open ticket to a Coding Agent and manages the worktree
- Coding Agent works on the ticket and calls `submit_pr()` when finished
- Merge queue: merge master into branch → `make test` → fast-forward merge to master on pass, reopen on fail
- Master must stay green; if it breaks, all work halts until it is fixed

### V1 Out of Scope

- Multiple concurrent coding agents
- Dynamic model promotion
- The merger agent and code review (comes in V3)
- Statistics and logging (comes in V2)
- Token budgets

### V1 Operational Rules

- `scriptorium.json` is the only runtime config file in V1. `scriptorium.toml` is not supported.
- The orchestrator is the only writer to `scriptorium/plan`.
- Every ticket state transition is a single git commit authored by the orchestrator.
- A ticket is always in exactly one state directory (`open/`, `in-progress/`, or `done/`).
- There is no "partially moved ticket" state in V1.


## Implementation

scriptorium is written in **Nim**. Key libraries:

- **MCPort** — MCP client/server over HTTP. Used for the orchestrator's MCP server and
  for any agent harness that needs to act as an MCP client.
- **jsony** — fast JSON parsing/serialization. Used for `scriptorium.json` config and all
  internal structured data.

Tests are always run with **`make test`**. The project being managed by scriptorium must have
a `Makefile` with a `test` target. scriptorium does not support configurable test commands —
`make test` is the contract.


## Agent Prompts

System prompts for each agent role (`architect`, `manager`, `coding_agent`, etc.) live in
the scriptorium source tree under `prompts/` and are embedded into the binary at compile time
using Nim's `staticRead`. They are not stored in the plan branch and are not configurable
at runtime — changing a prompt means cutting a new release of scriptorium.

This keeps the plan branch purely about the current project's state. Prompts are code,
not data.


## Planning Branch

All planning artifacts live in a dedicated `scriptorium/plan` git branch, separate from the
main codebase (similar to how `gh-pages` works). No database. Everything is a markdown
file, every state change is a git commit. Full audit trail for free.

Plan state is commit-based: if the commit exists, the state change exists; if not, the
previous commit state remains authoritative.

### Branch Structure

```
spec.md                    # Top-level spec; built by Architect in conversation with user

/areas/                    # Spec broken into focused domains; one per Manager assignment
  01-cli.md
  02-orchestrator.md
  03-agent-system.md

/tickets/
  open/                    # Ready to be worked on
    0001-scaffold-cli.md
  in-progress/             # Currently assigned to a Coding Agent
    0002-architect-agent.md
  done/                    # Completed and merged
    0000-init-repo.md

/decisions/                # Architecture Decision Records (ADRs)
  001-use-mcp.md
  002-no-database.md
  003-prompts-compiled-in.md
```

`spec.md` is the single source of truth for the project's intent. Areas are derived from
it and serve as the unit of work at the Manager level. Tickets are derived from areas and
serve as the unit of work at the Coding Agent level.

### spec.md

The top-level spec is a plain markdown document that describes what the project is, what
it must do, and what done looks like. It is written collaboratively — the user runs
`scriptorium plan` and has a conversation with the Architect, which produces or revises
`spec.md`. The Architect owns this file; no other agent modifies it.

A minimal spec.md:

```markdown
# the_scriptorium — V2 Spec

## Goal
A self-upgrading agent orchestrator. Given this spec, a running V1 instance should
be able to produce a working V2.

## Requirements
- Parallel coding agents (up to N, configured in scriptorium.json)
- Statistics collection per ticket (model used, time taken, pass/fail)
- Prediction of task difficulty based on ticket content

## Out of Scope
- UI
- Remote execution

## Done When
- All requirements have passing tests
- V1 can run against this spec and produce a V2 binary that passes its own test suite
```

### Area Files

After `spec.md` is settled, the Architect decomposes it into area files. Each area is a
focused slice of the spec that a Manager can own end-to-end. Areas contain enough context
for a Manager to create tickets without referring back to the full spec constantly.

```markdown
# Area 02 — Orchestrator

## Summary
Extend the orchestrator to support parallel coding agents.

## Context from spec
See spec.md §Requirements — parallel coding agents.

## Scope
- Worker pool with configurable concurrency
- Ticket locking (prevent two agents claiming the same ticket)
- Graceful shutdown when all tickets are done

## Out of Scope
- Statistics (Area 03)
```

The Manager agent is invoked by the orchestrator once per area when that area has no open
or in-progress tickets. It reads the area file and creates tickets via the `create_ticket`
MCP tool. The Architect owns areas; the Manager owns tickets within an area.

### Ticket Format

Each ticket is a markdown file. Moving the file between `open/`, `in-progress/`, and
`done/` *is* the state machine — no extra tooling needed.

```markdown
# 0001 — Scaffold the CLI

**Area:** 01-cli
**Worktree:** —

## Goal
Create the `scriptorium` binary with `--init` and `run` subcommands.

## Acceptance Criteria
- [ ] `scriptorium --init` creates the plan branch and folder structure
- [ ] `scriptorium run` starts a fully operational orchestrator loop
- [ ] Tests pass

## Notes
(appended by orchestrator as work progresses)
```

### Workflow

Agents never commit to `scriptorium/plan` directly. All plan branch mutations go through the
orchestrator's task queue. Agents only call simple MCP tools; the orchestrator enacts the
consequences in deterministic code.

1. User runs `scriptorium plan` → interactive conversation with Architect → Architect calls `submit_spec(content)` → orchestrator writes and commits `spec.md`
2. Architect calls `create_area(...)` for each domain → orchestrator writes area files and commits
3. Manager is spawned per area → reads area file, calls `create_ticket(...)` via HTTP MCP → orchestrator writes ticket files into `tickets/open/` and commits
4. Orchestrator picks the oldest open ticket, creates a code worktree, moves ticket to `in-progress/`
5. Coding Agent works in its worktree; if stuck, calls `ask_manager(question)` → escalates up the chain as needed
6. Coding Agent calls `submit_pr(summary)` → PR enters merge queue → orchestrator merges master into branch, runs tests → on pass: fast-forward merge to master, ticket moves to `done/` → on fail: ticket moves back to `open/` with failure notes
7. Loop repeats until no open tickets remain

No agent decides when to run tests, when to merge, or when to move a ticket. Those are
automatic consequences triggered by code, not by agent judgment.


## CLI — `scriptorium`

```
scriptorium --init [path]      Initialize a new scriptorium workspace
scriptorium --import [path]    Adopt an existing repo (later version)
scriptorium run                Start the orchestrator (reads current spec, drives work)
scriptorium status             Show ticket counts and current agent activity
scriptorium plan               Interactive Architect conversation to build or revise spec.md
scriptorium plan <prompt>      One-shot: ask the Architect to revise spec.md
scriptorium worktrees          List active git worktrees and which tickets they belong to
```

### `scriptorium --init`

Sets up the workspace:
1. Creates the `scriptorium/plan` branch (orphan — no shared history with main)
2. Writes the folder structure (`areas/`, `tickets/open/`, `tickets/in-progress/`, `tickets/done/`, `decisions/`)
3. Writes a blank `spec.md` placeholder
4. Commits the skeleton to `scriptorium/plan`
5. Prints next steps: "Run `scriptorium plan` to build your spec with the Architect"

No prompts are written — they are compiled into the binary.

### `scriptorium --import` *(later version)*

Bootstraps scriptorium onto an existing git repository that wasn't started with `scriptorium --init`.
The challenge: `spec.md` and the area files don't exist yet, but the codebase does.
The Architect must reverse-engineer them from what's already there.

Adoption process:
1. Orchestrator creates the `scriptorium/plan` branch and folder structure (same as `--init`)
2. Orchestrator does a shallow crawl of the repo — file tree, README, existing docs, test
   structure — and passes a summary to the Architect as context
3. Architect reads the codebase and drafts `spec.md` describing what the project *is* and
   what it *does*, as if writing the spec after the fact
4. Architect decomposes the codebase into area files — one per logical domain found in the
   existing code — documenting what each area covers and what its current state is
5. User reviews via `scriptorium plan` and iterates with the Architect until the spec and areas
   accurately reflect the codebase
6. From this point, `scriptorium run` works normally — new tickets are written against a known
   baseline rather than a blank slate

The adopted spec is a description of reality, not a wishlist. Any gaps or problems the
Architect identifies during adoption should be noted in the relevant area file so they can
be ticketed and addressed later.

### `scriptorium run`

Starts the orchestrator as a long-running daemon. It runs forever, printing structured
logs, and should be left running in a terminal or managed by a process supervisor. It does
not exit on its own — kill it to stop it.

Main loop:
1. Bind HTTP MCP server on a random localhost port (via MCPort)
2. Check out `scriptorium/plan` into a dedicated worktree (orchestrator only)
3. If `spec.md` is empty or missing, log `WAITING: no spec — run 'scriptorium plan'` and idle
4. If `spec.md` exists but has no areas, spawn Architect — pass `spec.md` via stdin; Architect creates areas via HTTP MCP tools, then exits
5. For each area with no open or in-progress tickets, spawn a Manager — pass area file + spec excerpt via stdin; Manager creates tickets via HTTP MCP tools, then exits
6. Pick the oldest open ticket, create a code worktree, move ticket to `in-progress/`
7. Spawn the Coding Agent harness — pass ticket + area context + spec excerpt via stdin; `scriptorium_MCP_URL` and `scriptorium_SESSION_TOKEN` via env
8. Agent works; all tool calls arrive at the HTTP MCP server; orchestrator drains task queue continuously
9. On `submit_pr`: PR enters merge queue → merge master into branch → `make test` → fast-forward merge to master on pass, reopen ticket on fail
10. Loop back to step 4

If an escalation reaches the Architect and the Architect cannot resolve it, the daemon logs
`BLOCKED: waiting for user — run 'scriptorium plan'` and idles until the block is cleared.
All other tickets continue if they are unaffected by the block.

### `scriptorium plan`

`scriptorium plan` (no args) opens a multi-turn interactive conversation with the Architect
in the terminal. Each turn, you type a message; the Architect reads and optionally edits
`spec.md` directly in the plan worktree. If `spec.md` changes, it is committed automatically
after that turn. Type `/quit` to exit; `/show` to print the current spec; `/help` for a
command list.

`scriptorium plan <prompt>` is the one-shot automation path: a single Architect call
rewrites `spec.md` and commits if the content changed.

The interactive mode is the primary — and ideally only — interface between the human
engineer and the scriptorium system. The user should be able to describe what they want in
plain language and trust the Architect to translate it into spec changes, new areas, and
updated tickets.

The Architect in `scriptorium plan` has full read access to the plan branch: current `spec.md`,
all area files, all tickets (open, in-progress, done), and any pending escalations. It can
call `submit_spec`, `create_area`, and `add_note` during the conversation, which take
effect immediately on the plan branch.

Typical uses:
- Initial spec creation: "here's what I want to build, help me write the spec"
- Mid-project revision: "the auth library doesn't support X, we need to rethink area 03"
- Clearing a block: reviewing a pending escalation and telling the Architect how to resolve it
- Status check: "what's in progress right now and what's blocked?"

`scriptorium plan` exits when the user ends the conversation. `scriptorium run` picks up any
changes to the plan branch automatically on its next loop iteration.


## Orchestrator & Task Queue

The orchestrator is a simple event loop with a serial task queue. It is the only process
that writes to `scriptorium/plan` or performs git operations. Agents never touch the plan
branch — they only call MCP tools that enqueue tasks in the orchestrator.

**The rule:** agents report facts; the orchestrator enacts consequences in code.

### Task Queue Operations

All mutations to the plan branch and worktrees go through the queue. The orchestrator
processes them one at a time, in order.

| Task | Triggered by | Effect |
|---|---|---|
| `write_spec(content)` | `submit_spec` MCP call from Architect | Writes `spec.md`, commits to `scriptorium/plan` |
| `write_area(content)` | `create_area` MCP call from Architect | Writes area file under `areas/`, commits |
| `create_ticket(spec)` | `create_ticket` MCP call from Manager | Writes ticket file into `tickets/open/`, commits |
| `assign_ticket(id)` | Orchestrator (automatic) | Moves ticket to `in-progress/`, creates code worktree, commits |
| `annotate_ticket(id, note)` | Any agent MCP call | Appends note to ticket file, commits |
| `enqueue_pr(ticket_id, summary)` | `submit_pr` MCP call from Coding Agent | Adds the PR to the serial merge queue |
| `close_ticket(id)` | Orchestrator (automatic, after successful merge) | Moves ticket to `done/`, commits, cleans up worktree |
| `reopen_ticket(id, reason)` | Orchestrator (automatic, after merge queue failure) | Moves ticket back to `open/`, appends failure notes, commits |
| `escalate(id, question)` | Orchestrator (after exhausting lower levels) | Records question on ticket; invokes Architect or blocks for user |

### Merge Queue

The orchestrator maintains a single serial merge queue, separate from but fed by the
main task queue. PRs are processed one at a time in submission order. This guarantees
that every PR is tested against up-to-date master and that master is never in an
ambiguous state.

For each PR in the queue:

```
1. Merge current master into the worktree branch
     └─ if merge conflict → reopen_ticket with conflict details, skip to next PR
2. Run tests in the worktree
     └─ if fail → reopen_ticket with test output, skip to next PR
3. Fast-forward merge worktree branch into master
4. close_ticket — commit plan update, clean up worktree
```

In V1, all PRs are auto-approved. No human review, no agent review. If tests pass after
merging master, the code lands. The merger agent introduced in V3 will insert a code
review step between steps 2 and 3.

V1 merge policy is intentionally strict:
- One merge-queue attempt per submitted PR.
- No automatic retry on merge conflict or failing tests.
- On failure, the ticket is reopened with notes and must be resubmitted after fixes.

### Escalation Path

Problems bubble up through the hierarchy until they reach a level that can handle them.
The goal is to resolve issues as low as possible using code or the appropriate agent,
and only block the whole system as a last resort.

```
Coding Agent
  │  calls ask_manager(question)
  ▼
Orchestrator (Manager role — code)
  │  checks if question can be answered from ticket/area/spec context
  │  if yes: answer returned directly, no agent invoked
  │  if no:
  ▼
Architect agent
  │  reads full plan context, attempts to answer or revise spec/area
  │  if resolved: answer flows back down to Coding Agent
  │  if not resolvable (ambiguous requirement, missing info, etc.):
  ▼
BLOCKED — daemon logs "BLOCKED: run 'scriptorium plan'"
  │  other unaffected tickets continue
  │  user runs scriptorium plan, discusses with Architect
  ▼
Block cleared — Architect calls answer_escalation(ticket_id, answer)
  │  answer passed back to waiting Coding Agent
  ▼
Work resumes
```

Escalations are recorded on the ticket file so there is a permanent log of what was
asked, what was tried, and how it was resolved.

### Plan Branch Worktree

The orchestrator maintains a dedicated worktree for `scriptorium/plan`, separate from all code
worktrees. It is the only writer. Agents receive ticket contents via stdin when spawned —
they never read the plan worktree directly.


## Agent Communication (HTTP MCP)

All agents — Architect, Manager, and Coding Agent — communicate with the orchestrator
exclusively over HTTP MCP. The orchestrator runs a single HTTP MCP server on a random
localhost port at startup. Every agent harness is given the server URL via the
`scriptorium_MCP_URL` and `scriptorium_SESSION_TOKEN` environment variables when spawned.

The MCP library used is **MCPort**, a Nim library for MCP client/server over HTTP.

Centralising all communication through one HTTP MCP server means the orchestrator has
a single chokepoint for ordering, locking, and logging — no agent can race another.
Agents do not talk to each other or touch the filesystem outside their own worktree.

### Topology

```
Orchestrator (HTTP MCP server — MCPort)
  │   localhost, random port, all agents connect here
  │
  ├── plan worktree  (scriptorium/plan — orchestrator only)
  │
  ├── Architect harness subprocess
  │     context delivered via stdin; tools called over HTTP MCP
  │
  ├── Manager harness subprocess (one per area being decomposed)
  │     context delivered via stdin; tools called over HTTP MCP
  │
  └── Coding Agent harness subprocess (one per active ticket)
        context delivered via stdin; tools called over HTTP MCP
        └── code worktree (scoped to this agent)
```

### Session Tokens

Each spawned subprocess receives a unique session token. The orchestrator uses this token
to route incoming MCP tool calls to the correct agent context — which ticket, which area,
which worktree. This is how multi-agent operation in V2 stays safe without any extra
locking in the agents themselves.

### Agent MCP Tools

**Architect:**

| Tool | Arguments | Effect |
|---|---|---|
| `submit_spec(content)` | Markdown string | Enqueues `write_spec` — writes `spec.md` and commits |
| `create_area(title, summary, scope, out_of_scope)` | Structured fields | Enqueues `write_area` — writes area file and commits |
| `add_note(ticket_id, note)` | Text | Enqueues `annotate_ticket` |
| `answer_escalation(ticket_id, answer)` | Text | Resolves a blocked escalation; answer flows back to the waiting agent |

**Manager:**

| Tool | Arguments | Effect |
|---|---|---|
| `create_ticket(title, goal, acceptance_criteria, notes)` | Structured fields | Enqueues `create_ticket` — writes ticket file into `tickets/open/` and commits |
| `add_note(ticket_id, note)` | Text | Enqueues `annotate_ticket` |
| `ask_architect(question)` | Text | Escalates a question up to the Architect; blocks until answered |

**Coding Agent:**

| Tool | Arguments | Effect |
|---|---|---|
| `run_tests()` | — | Runs `make test` in the worktree; returns exit code and output |
| `submit_pr(summary)` | Text | Enqueues the PR in the merge queue. Merge queue merges master into branch, runs `make test`, fast-forward merges to master on pass, reopens ticket on fail. Agent may call `run_tests()` first to fail fast before queuing. |
| `ask_manager(question)` | Text | Escalates a question to the Manager; blocks until answered |
| `add_note(note)` | Text | Enqueues `annotate_ticket` |

Coding Agents also receive standard file and shell tools from their harness, scoped to
their worktree. They have no access to the plan worktree or other agents' worktrees.


## Models

Models are grouped into three tiers. Each tier maps to a role in the hierarchy.

### Pricing Reference

All prices per 1M tokens. Sorted by input cost within each tier.

| Model | Tier | Input | Output | Cached Input | Notes |
|---|---|---|---|---|---|
| `grok-code-fast-1` | Small | $0.20 | $1.50 | $0.02 | Cheapest overall; excellent for high-volume coding |
| `codex-mini` (GPT-5.1) | Small | $0.25 | $2.00 | $0.025 | Affordable; widely supported across tooling |
| `claude-haiku-4-5` | Small | $1.00 | $5.00 | $0.10 | 4–5× pricier than the top two small models |
| `claude-sonnet-4-6` | Medium | $3.00 | $15.00 | $0.30 | Solid mid-tier balance of speed and capability |
| `codex-5.3` (GPT-5.3) | Large | $1.75 | $14.00 | $0.175 | Best price/performance in the large tier |
| `claude-opus-4-6` | Large | $5.00 | $25.00 | $0.50 | Most expensive; strongest reasoning on hard tasks |
| `qwen3.5-35b-a3b` | Medium | local | local | — | MoE; low active parameter cost, runs in LM Studio |

### Large — Architect

Reserved for planning, spec decomposition, and any decision that affects the whole project.
These models are expensive; the Architect should do focused, high-value work and delegate
everything else.

| Model | Provider | Notes |
|---|---|---|
| `claude-opus-4-6` | Anthropic API | Primary default for Architect |
| `codex-5.3` | OpenAI API | Alternative; best price/performance in the large tier |

### Medium — Manager

Coordination, ticket management, test evaluation, and merge decisions. Tasks are
structured enough that a mid-tier model handles them well without burning budget.

| Model | Provider | Notes |
|---|---|---|
| `claude-sonnet-4-6` | Anthropic API | Reliable; good balance of speed and quality |
| `qwen3.5-35b-a3b` | LM Studio (local) | MoE model; low active parameter cost, runs locally |

### Small — Coding Agent

Narrow, well-scoped execution tasks: implement the ticket, run tests, report done.
These models run the most frequently, so cost per call matters.

| Model | Provider | Harness | Notes |
|---|---|---|---|
| `grok-code-fast-1` | xAI API | `typoi` | Cheapest; best for high-volume or latency-sensitive work |
| `codex-mini` | OpenAI API (GPT-5.1) | `codex` | Affordable; strong at code generation within tight scope |
| `claude-haiku-4-5` | Anthropic API | `claude-code` | Pricier than the above two but well-integrated with Anthropic tooling |


### Coding Agent Harnesses

The Coding Agent is not invoked directly as an API call — it is spawned as a subprocess
running a coding CLI tool. The orchestrator selects the harness based on the configured
model.

| Harness | Supported Models | Notes |
|---|---|---|
| `claude-code` | All Anthropic models (`claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5`) | Official Anthropic CLI |
| `codex` | All OpenAI models (`codex-5.3`, `codex-mini`) and `qwen3.5-35b-a3b` | Requires a fully compliant Responses API endpoint with `previous_response_id` support — llama.cpp llama-server does not qualify |
| `typoi` | Any model; **sole support for `grok-code-fast-1`** | Custom CLI agent harness; used when no other harness supports the model |

Harness selection is automatic based on the model name in `scriptorium.json`:

```json
{
  "models": {
    "architect": "claude-opus-4-6",
    "coding": "grok-code-fast-1"
  }
}
```

- `claude-*` → `claude-code`
- `codex-*` or `gpt-*` or a local model on an OpenAI-compatible endpoint → `codex` (requires Responses API with `previous_response_id`)
- `grok-*` or anything else → `typoi`

The orchestrator spawns the harness as a subprocess, writes the ticket + context to its
stdin, and communicates via the harness's stdio MCP interface.


## Model Routing

The hierarchy maps naturally to model tiers. Smarter (more expensive) models handle
planning and ambiguity; cheaper models handle well-defined execution tasks.

### Default Routing

| Role | Tier | Default Model |
|---|---|---|
| Architect | Large | `claude-opus-4-6` |
| Manager | Medium | `claude-sonnet-4-6` |
| Coding Agent | Small | `claude-haiku-4-5` |

### Promotion

If an agent reports it is stuck (e.g., repeated failed attempts, explicit escalation),
it can be promoted to the next model tier for that ticket. Promotion is logged in the
ticket file so the cost is visible. This is a manual escape hatch in V1; V2 will track
patterns and suggest automatic promotion thresholds.

### Configuration — `scriptorium.json`

All configuration lives in `scriptorium.json` at the workspace root. Parsed at startup using
the Nim `jsony` library. No TOML, no YAML.

```json
{
  "models": {
    "architect": "claude-opus-4-6",
    "coding": "grok-code-fast-1"
  },
  "endpoints": {
    "local": "http://localhost:1234/v1"
  }
}
```

Model names prefixed with `local/` (e.g. `"local/qwen3.5-35b-a3b"`) are routed to the
`endpoints.local` URL. All other names are routed to their provider's default API endpoint.
