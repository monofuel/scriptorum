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

- in contract to gastown, the sanctum would be very opinionated with my own opinions.
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
