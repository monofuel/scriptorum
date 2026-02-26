# the_sanctum

- the "cathedral" of agent orchestration


## rough plan


have a top level tool, `sanctum` with commands like `sanctum --init` to create a workspace
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

- agents can work entirely through stdio MCP servers. very simple, all runs local.
- messages would only flow up/down through the heirarchy
  - coding agents could ask questions that filter up through the managers, answers filter back down
  - some problems might require the plans be adjusted (eg: maybe a library doesn't support a feature we thought it had and we have to change things up)

- should work interchangeably with codex, claude-code, or my own typoi cli agent tool.

- in contrast to gastown, the sanctum would be very opinionated with my own opinions.
- as an agent orchestrator, it should be capable of making the 'v2' version of itself, or v3, v4, and so on.

- we should probably have a folder like ./prompts/ that contains the base system prompts for the agents, like architect.md, manager.md, coding_agent.md, merging_agent.md, etc.

- the sanctum should perform it's own upgrades to ensure it is working.
- we should have unit tests and small integration tests.
  - eg: architect tests, manager tests, coding agent tests, merging agent tests.

- V1 will be MVP. a minimal agent orchestrator that can manage itself.
  - probably just have a static heirarchy of 1 architect, 1 manager, and 1 coding agent.
- V2 should have statistics and logging (eg: how often do certain models get stuck, what types of task fail) we should also do predictions on how hard a task is and how long it will take and record how long it actually took.
- V3 should introduce the merging agent.
  - coding agents should work on their own branches and the merging agent should merge to master.
  - merging agent should ensure tests pass and also perform code review.


## V1 — MVP

The north star for V1: **it must be capable of building V2 on its own, given the V2 spec.**

This defines the minimum bar. V1 doesn't need to be elegant or fast — it needs to be
correct enough that an Architect can read a spec, decompose it into tickets, a coding agent
can execute those tickets, and the result passes tests. If V1 can do that for a non-trivial
spec (its own V2), it is done.

### V1 Agent Hierarchy

```
Orchestrator (code — event loop + task queue)
  ├── Architect (1x, large model — planning only)
  └── Coding Agent (1x, small model — execution only)
```

The Manager from the rough plan is replaced by the orchestrator itself in V1. Ticket
assignment, test runs, merges, and state transitions are deterministic code — no agent
judgment needed. A Manager agent can be reintroduced in a later version if dynamic
management decisions are required.

### V1 Capabilities

- `sanctum --init` sets up a new workspace with a planning branch and base prompts
- `sanctum run` starts the orchestrator event loop
- Orchestrator invokes Architect when there are no open tickets; Architect decomposes the spec and creates tickets via MCP tools
- Orchestrator assigns the oldest open ticket to the Coding Agent and manages the worktree
- Coding Agent works on the ticket and calls `report_done()` or `report_blocker()` when finished
- Orchestrator runs tests, merges on pass, reopens on fail — all in code
- Master must stay green; if it breaks, all work halts until it is fixed

### V1 Out of Scope

- Multiple concurrent coding agents
- Dynamic model promotion
- The merging agent (comes in V3)
- Statistics and logging (comes in V2)
- Token budgets


## Agent Prompts

System prompts for each agent role (`architect`, `coding_agent`, etc.) live in the
sanctum source tree under `prompts/` and are embedded into the binary at compile time
using Nim's `staticRead`. They are not stored in the plan branch and are not configurable
at runtime — changing a prompt means cutting a new release of sanctum.

This keeps the plan branch purely about the current project's state. Prompts are code,
not data.


## Planning Branch

All planning artifacts live in a dedicated `sanctum/plan` git branch, separate from the
main codebase (similar to how `gh-pages` works). No database. Everything is a markdown
file, every state change is a git commit. Full audit trail for free.

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
`sanctum plan` and has a conversation with the Architect, which produces or revises
`spec.md`. The Architect owns this file; no other agent modifies it.

A minimal spec.md:

```markdown
# the_sanctum — V2 Spec

## Goal
A self-upgrading agent orchestrator. Given this spec, a running V1 instance should
be able to produce a working V2.

## Requirements
- Parallel coding agents (up to N, configured in sanctum.toml)
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

In V1, with no Manager agents, the orchestrator itself handles area decomposition and
creates tickets directly from each area file. Manager agents are introduced later.

### Ticket Format

Each ticket is a markdown file. Moving the file between `open/`, `in-progress/`, and
`done/` *is* the state machine — no extra tooling needed.

```markdown
# 0001 — Scaffold the CLI

**Area:** 01-cli
**Worktree:** —

## Goal
Create the `sanctum` binary with `--init` and `run` subcommands.

## Acceptance Criteria
- [ ] `sanctum --init` creates the plan branch and folder structure
- [ ] `sanctum run` starts a fully operational orchestrator loop
- [ ] Tests pass

## Notes
(appended by orchestrator as work progresses)
```

### Workflow

Agents never commit to `sanctum/plan` directly. All plan branch mutations go through the
orchestrator's task queue. Agents only call simple MCP tools; the orchestrator enacts the
consequences in deterministic code.

1. User runs `sanctum plan` → interactive conversation with Architect → Architect calls `submit_spec(content)` → orchestrator writes and commits `spec.md`
2. Architect calls `create_area(...)` for each domain → orchestrator writes area files and commits
3. Orchestrator (or Manager agent in later versions) reads each area and calls `create_ticket(...)` → orchestrator writes ticket files into `tickets/open/` and commits
4. Orchestrator picks the oldest open ticket, creates a code worktree, moves ticket to `in-progress/`
5. Coding Agent works in its worktree; if stuck, calls `report_blocker(reason)` → orchestrator annotates the ticket and escalates
6. Coding Agent calls `report_done()` → orchestrator enqueues: run tests → on pass: merge + move ticket to `done/` → on fail: annotate + move back to `open/`
7. Loop repeats until no open tickets remain

No agent decides when to run tests, when to merge, or when to move a ticket. Those are
automatic consequences triggered by code, not by agent judgment.


## CLI — `sanctum`

```
sanctum --init [path]      Initialize a new sanctum workspace
sanctum --import [path]    Adopt an existing repo (later version)
sanctum run                Start the orchestrator (reads current spec, drives work)
sanctum status             Show ticket counts and current agent activity
sanctum plan               Conversation with the Architect to build or revise spec.md
sanctum worktrees          List active git worktrees and which tickets they belong to
```

### `sanctum --init`

Sets up the workspace:
1. Creates the `sanctum/plan` branch (orphan — no shared history with main)
2. Writes the folder structure (`areas/`, `tickets/open/`, `tickets/in-progress/`, `tickets/done/`, `decisions/`)
3. Writes a blank `spec.md` placeholder
4. Commits the skeleton to `sanctum/plan`
5. Prints next steps: "Run `sanctum plan` to build your spec with the Architect"

No prompts are written — they are compiled into the binary.

### `sanctum --import` *(later version)*

Bootstraps sanctum onto an existing git repository that wasn't started with `sanctum --init`.
The challenge: `spec.md` and the area files don't exist yet, but the codebase does.
The Architect must reverse-engineer them from what's already there.

Adoption process:
1. Orchestrator creates the `sanctum/plan` branch and folder structure (same as `--init`)
2. Orchestrator does a shallow crawl of the repo — file tree, README, existing docs, test
   structure — and passes a summary to the Architect as context
3. Architect reads the codebase and drafts `spec.md` describing what the project *is* and
   what it *does*, as if writing the spec after the fact
4. Architect decomposes the codebase into area files — one per logical domain found in the
   existing code — documenting what each area covers and what its current state is
5. User reviews via `sanctum plan` and iterates with the Architect until the spec and areas
   accurately reflect the codebase
6. From this point, `sanctum run` works normally — new tickets are written against a known
   baseline rather than a blank slate

The adopted spec is a description of reality, not a wishlist. Any gaps or problems the
Architect identifies during adoption should be noted in the relevant area file so they can
be ticketed and addressed later.

### `sanctum run`

Starts the orchestrator event loop. The loop is pure code — agents don't drive it.

1. Orchestrator checks out `sanctum/plan` into a dedicated worktree (read/write by orchestrator only)
2. Orchestrator reads ticket state; if no open tickets, invokes Architect to decompose the spec
3. Orchestrator picks the oldest open ticket, creates a code worktree, commits ticket to `in-progress/`
4. Orchestrator invokes the Coding Agent with the ticket contents as context
5. Agent works; any MCP tool calls (`report_done`, `report_blocker`, `add_note`) enqueue tasks in the orchestrator
6. Orchestrator drains the task queue: runs tests, merges, updates ticket state, commits to plan — all in code
7. Loop back to step 2


## Orchestrator & Task Queue

The orchestrator is a simple event loop with a serial task queue. It is the only process
that writes to `sanctum/plan` or performs git operations. Agents never touch the plan
branch — they only call MCP tools that enqueue tasks in the orchestrator.

**The rule:** agents report facts; the orchestrator enacts consequences in code.

### Task Queue Operations

All mutations to the plan branch and worktrees go through the queue. The orchestrator
processes them one at a time, in order.

| Task | Triggered by | Effect |
|---|---|---|
| `write_spec(content)` | Architect MCP call | Writes `spec/overview.md`, commits to `sanctum/plan` |
| `create_ticket(spec)` | Architect MCP call | Writes ticket file into `tickets/open/`, commits |
| `assign_ticket(id)` | Orchestrator (automatic) | Moves ticket to `in-progress/`, creates code worktree, commits |
| `annotate_ticket(id, note)` | Any agent MCP call | Appends note to ticket file, commits |
| `run_tests(ticket_id)` | Orchestrator (automatic, after `report_done`) | Runs test suite in the worktree |
| `merge_branch(ticket_id)` | Orchestrator (automatic, after tests pass) | Merges worktree branch to main |
| `close_ticket(id)` | Orchestrator (automatic, after merge) | Moves ticket to `done/`, commits, cleans up worktree |
| `reopen_ticket(id, reason)` | Orchestrator (automatic, after tests fail) | Moves ticket back to `open/`, appends failure notes, commits |
| `escalate_ticket(id, reason)` | Orchestrator (automatic, after `report_blocker`) | Annotates ticket with blocker, surfaces to Architect |

Chaining is done in code. When `run_tests` completes, the orchestrator enqueues either
`merge_branch` or `reopen_ticket` based on the exit code — no agent decides this.

### Plan Branch Worktree

The orchestrator maintains a dedicated worktree for `sanctum/plan`, separate from all code
worktrees. It is the only writer. Agents can read ticket contents (passed to them as
context by the orchestrator) but cannot write to this worktree.


## Agent Communication (MCP / stdio)

Agents communicate with the orchestrator exclusively through stdio-based MCP servers.
No sockets, no HTTP, no shared memory. Each agent is spawned as a subprocess with a
pipe to the orchestrator. Agents do not talk to each other.

### Topology

```
sanctum (orchestrator + task queue)
  │
  ├── plan worktree (sanctum/plan) — orchestrator only
  │
  ├── spawns Architect (stdin/stdout pipe)
  ├── spawns Coding Agent (stdin/stdout pipe)
  └── code worktrees — one per active ticket
```

The Manager role from the original design is absorbed into the orchestrator for V1.
The logic for picking tickets, running tests, and merging is deterministic code, not
an agent — a Manager agent adds little value over a simple loop when the rules are fixed.
It can be reintroduced in a later version if dynamic management decisions are needed.

### Agent MCP Tools

Agents get a small set of simple, atomic tools. Each tool enqueues one task in the
orchestrator and returns immediately. Agents do not wait for the consequence — they just
report and continue or finish.

**Architect tools:**

| Tool | Arguments | Effect |
|---|---|---|
| `submit_spec(content)` | Markdown string | Enqueues `write_spec` |
| `create_ticket(title, goal, acceptance_criteria, notes)` | Structured fields | Enqueues `create_ticket` |
| `add_note(ticket_id, note)` | Text | Enqueues `annotate_ticket` |

**Coding Agent tools:**

| Tool | Arguments | Effect |
|---|---|---|
| `report_done()` | — | Enqueues `run_tests` → chains to merge or reopen |
| `report_blocker(reason)` | Text | Enqueues `escalate_ticket` |
| `add_note(ticket_id, note)` | Text | Enqueues `annotate_ticket` |

Coding Agents also get standard file and shell tools scoped to their worktree (read, write,
run commands). They cannot access the plan worktree or other code worktrees.


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

Harness selection is automatic based on `sanctum.toml`:

```toml
[models]
architect = "claude-opus-4-6"    # → claude-code
manager   = "local/qwen3.5-35b-a3b"  # → codex (OpenAI-compatible endpoint)
coding    = "grok-code-fast-1"   # → typoi
```

The orchestrator spawns the harness as a subprocess, passes the ticket contents and worktree
path as context, and communicates via the harness's stdio MCP interface.


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

### Local Model Integration

The orchestrator supports an OpenAI-compatible endpoint so that locally hosted models
(e.g., via LM Studio) can be swapped in per role. Configuration lives in a
`sanctum.toml` at the workspace root:

```toml
[models]
architect = "claude-opus-4-6"
manager   = "local/qwen3.5-35b-a3b"    # hits LM Studio at http://localhost:1234/v1
coding    = "claude-haiku-4-5"
```
