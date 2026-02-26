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
Architect (1x, smart model)
  └── Manager (1x, mid-tier model)
        └── Coding Agent (1x, cheaper model)
```

This is a static hierarchy — no dynamic spawning yet. One of each, wired together.

### V1 Capabilities

- `sanctum --init` sets up a new workspace with a planning branch and base prompts
- `sanctum run` starts the orchestrator: Architect reads the current spec and drives work
- Architect decomposes a spec into tickets and writes them to the planning branch
- Manager polls for open tickets, assigns one to the Coding Agent, tracks progress
- Coding Agent works on the ticket in a git worktree and marks it done when finished
- Manager runs tests after each ticket completes; if tests fail, the ticket is reopened
- No merging agent yet — Manager handles the merge after tests pass
- Master must stay green; if it breaks, all work halts until it is fixed

### V1 Out of Scope

- Multiple concurrent coding agents
- Dynamic model promotion
- The merging agent (comes in V3)
- Statistics and logging (comes in V2)
- Token budgets


## Planning Branch

All planning artifacts live in a dedicated `sanctum/plan` git branch, separate from the
main codebase (similar to how `gh-pages` works). No database. Everything is a markdown
file, every state change is a git commit. Full audit trail for free.

### Branch Structure

```
/spec/
  overview.md          # The current master spec, written by the Architect
  decisions/           # Architecture Decision Records (ADRs)
    001-use-mcp.md
    002-no-database.md

/tickets/
  open/                # Ready to be worked on
    0001-scaffold-cli.md
  in-progress/         # Currently assigned to an agent
    0002-architect-agent.md
  done/                # Completed and merged
    0000-init-repo.md

/prompts/              # Canonical system prompts for each role
  architect.md
  manager.md
  coding_agent.md
  merging_agent.md     # Stubbed in V1, used in V3
```

### Ticket Format

Each ticket is a markdown file. Moving the file between `open/`, `in-progress/`, and
`done/` *is* the state machine — no extra tooling needed.

```markdown
# 0001 — Scaffold the CLI

**Status:** open
**Assigned:** —
**Worktree:** —

## Goal
Create the `sanctum` binary with `--init` and `run` subcommands.

## Acceptance Criteria
- [ ] `sanctum --init` creates a planning branch and base folder structure
- [ ] `sanctum run` starts a fully operational orchestrator loop
- [ ] Tests pass

## Notes
Keep it minimal. No config file needed yet.
```

### Workflow

1. Architect writes or updates `/spec/overview.md` and commits to `sanctum/plan`
2. Architect decomposes the spec into ticket files under `/tickets/open/`
3. Manager picks the next open ticket, moves it to `in-progress/`, sets assigned agent and worktree
4. Coding Agent checks out the ticket, works in its git worktree, then marks the ticket done
5. Manager runs tests; on pass, merges the worktree branch to master and moves ticket to `done/`
6. Loop repeats until no open tickets remain

If a coding agent gets stuck or tests keep failing, the ticket gets a `## Blockers` section
added and is escalated — moved back to `open/` with a note, and the Manager surfaces it to
the Architect. The Architect can update the spec or the ticket and requeue it.


## CLI — `sanctum`

```
sanctum --init [path]   Initialize a new sanctum workspace
sanctum run             Start the orchestrator (reads current spec, drives work)
sanctum status          Show ticket counts and current agent activity
sanctum plan            Open an interactive session with the Architect to update the spec
sanctum worktrees       List active git worktrees and which tickets they belong to
```

### `sanctum --init`

Sets up the workspace:
1. Creates the `sanctum/plan` branch (orphan — no shared history with main)
2. Writes the default folder structure (`spec/`, `tickets/open/`, `tickets/in-progress/`, `tickets/done/`, `prompts/`)
3. Copies base system prompts into `/prompts/`
4. Commits the skeleton to `sanctum/plan`
5. Prints next steps: "Edit spec/overview.md, then run `sanctum run`"

### `sanctum run`

The main loop:
1. Architect reads `spec/overview.md` and the current ticket state
2. If there are no open tickets, Architect decomposes the spec into new tickets
3. Manager picks the oldest open ticket and assigns it to the Coding Agent
4. Coding Agent works in a fresh worktree (`git worktree add`)
5. When the agent reports done, Manager runs tests
6. On pass: merge, move ticket to `done/`, loop
7. On fail: reopen ticket with failure notes, loop


## Agent Communication (MCP / stdio)

Agents communicate exclusively through stdio-based MCP servers. No sockets, no HTTP,
no shared memory. Simple and local.

### Topology

```
sanctum (orchestrator process)
  │
  ├── spawns Architect MCP server (stdin/stdout pipe)
  ├── spawns Manager MCP server (stdin/stdout pipe)
  └── spawns Coding Agent MCP server (stdin/stdout pipe)
```

The orchestrator is the message bus. Agents do not talk to each other directly — all
messages route up or down through the hierarchy via the orchestrator.

### Message Flow

- **Downward:** Orchestrator pushes tasks and context to agents (e.g., "here is the ticket, here is the spec excerpt")
- **Upward:** Agents push results, questions, or blockers back to the orchestrator
- **Escalation:** If a Coding Agent raises a blocker, Manager decides whether to handle it
  or escalate to Architect. Architect can revise the spec/ticket and requeue.

### Agent Tool Surface

Each agent gets a minimal MCP tool set appropriate to its role:

| Agent | Tools |
|---|---|
| Architect | read/write planning branch, create/update tickets, read spec |
| Manager | read/write ticket status, spawn worktree, run tests, merge branch |
| Coding Agent | read/write files in worktree, run tests, read assigned ticket |

Agents are otherwise sandboxed — a Coding Agent cannot touch the planning branch directly.


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

| Model | Provider | Notes |
|---|---|---|
| `grok-code-fast-1` | xAI API | Cheapest; best for high-volume or latency-sensitive work |
| `codex-mini` | OpenAI API (GPT-5.1) | Affordable; strong at code generation within tight scope |
| `claude-haiku-4-5` | Anthropic API | Pricier than the above two but well-integrated with Anthropic tooling |


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
