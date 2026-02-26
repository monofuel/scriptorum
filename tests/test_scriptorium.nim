## Tests for the scriptorium CLI and core utilities.

import
  std/[os, osproc, sequtils, strutils, unittest],
  scriptorium/[agent_runner, config, init, orchestrator]

const
  CliBinaryName = "scriptorium_test_cli"
let
  ProjectRoot = getCurrentDir()
var
  cliBinaryPath = ""

proc makeTestRepo(path: string) =
  ## Create a minimal git repository at path suitable for testing.
  createDir(path)
  discard execCmdEx("git -C " & path & " init")
  discard execCmdEx("git -C " & path & " config user.email test@test.com")
  discard execCmdEx("git -C " & path & " config user.name Test")
  discard execCmdEx("git -C " & path & " commit --allow-empty -m initial")

proc runCmdOrDie(cmd: string) =
  ## Run a shell command and fail the test immediately if it exits non-zero.
  let (_, rc) = execCmdEx(cmd)
  doAssert rc == 0, cmd

proc ensureCliBinary(): string =
  ## Build and cache the scriptorium CLI binary for command-output tests.
  if cliBinaryPath.len == 0:
    cliBinaryPath = getTempDir() / CliBinaryName
    runCmdOrDie(
      "nim c -o:" & quoteShell(cliBinaryPath) & " " & quoteShell(ProjectRoot / "src/scriptorium.nim")
    )
  result = cliBinaryPath

proc runCliInRepo(repoPath: string, args: string): tuple[output: string, exitCode: int] =
  ## Run the compiled CLI in repoPath and return output and exit code.
  let command = "cd " & quoteShell(repoPath) & " && " & quoteShell(ensureCliBinary()) & " " & args
  result = execCmdEx(command)

proc withPlanWorktree(repoPath: string, suffix: string, action: proc(planPath: string)) =
  ## Open scriptorium/plan in a temporary worktree for direct test mutations.
  let tmpPlan = getTempDir() / ("scriptorium_test_plan_" & suffix)
  if dirExists(tmpPlan):
    removeDir(tmpPlan)

  runCmdOrDie("git -C " & quoteShell(repoPath) & " worktree add " & quoteShell(tmpPlan) & " scriptorium/plan")
  defer:
    discard execCmdEx("git -C " & quoteShell(repoPath) & " worktree remove --force " & quoteShell(tmpPlan))

  action(tmpPlan)

proc removeSpecFromPlan(repoPath: string) =
  ## Remove spec.md from scriptorium/plan and commit the change.
  withPlanWorktree(repoPath, "remove_spec", proc(planPath: string) =
    runCmdOrDie("git -C " & quoteShell(planPath) & " rm spec.md")
    runCmdOrDie("git -C " & quoteShell(planPath) & " commit -m test-remove-spec")
  )

proc addAreaToPlan(repoPath: string, fileName: string, content: string) =
  ## Add one area markdown file to scriptorium/plan and commit the change.
  withPlanWorktree(repoPath, "add_area", proc(planPath: string) =
    let relPath = "areas/" & fileName
    writeFile(planPath / relPath, content)
    runCmdOrDie("git -C " & quoteShell(planPath) & " add " & quoteShell(relPath))
    runCmdOrDie("git -C " & quoteShell(planPath) & " commit -m test-add-area")
  )

proc addTicketToPlan(repoPath: string, state: string, fileName: string, content: string) =
  ## Add one ticket file to a plan ticket state directory and commit it.
  withPlanWorktree(repoPath, "add_ticket", proc(planPath: string) =
    let relPath = "tickets" / state / fileName
    writeFile(planPath / relPath, content)
    runCmdOrDie("git -C " & quoteShell(planPath) & " add " & quoteShell(relPath))
    runCmdOrDie("git -C " & quoteShell(planPath) & " commit -m test-add-ticket")
  )

proc moveTicketStateInPlan(repoPath: string, fromState: string, toState: string, fileName: string) =
  ## Move a ticket file from one state directory to another and commit.
  withPlanWorktree(repoPath, "move_ticket_state", proc(planPath: string) =
    let fromPath = "tickets" / fromState / fileName
    let toPath = "tickets" / toState / fileName
    moveFile(planPath / fromPath, planPath / toPath)
    runCmdOrDie("git -C " & quoteShell(planPath) & " add -A " & quoteShell("tickets"))
    runCmdOrDie("git -C " & quoteShell(planPath) & " commit -m test-move-ticket")
  )

proc planCommitCount(repoPath: string): int =
  ## Return the commit count reachable from the plan branch.
  let (output, rc) = execCmdEx("git -C " & quoteShell(repoPath) & " rev-list --count scriptorium/plan")
  doAssert rc == 0
  result = parseInt(output.strip())

proc planTreeFiles(repoPath: string): seq[string] =
  ## Return file paths from the plan branch tree.
  let (output, rc) = execCmdEx("git -C " & quoteShell(repoPath) & " ls-tree -r --name-only scriptorium/plan")
  doAssert rc == 0
  result = output.splitLines().filterIt(it.len > 0)

proc gitWorktreePaths(repoPath: string): seq[string] =
  ## Return absolute paths from git worktree list.
  let (output, rc) = execCmdEx("git -C " & quoteShell(repoPath) & " worktree list --porcelain")
  doAssert rc == 0
  for line in output.splitLines():
    if line.startsWith("worktree "):
      result.add(line["worktree ".len..^1].strip())

proc addPassingMakefile(repoPath: string) =
  ## Add a Makefile with a passing `make test` target and commit it on master.
  writeFile(repoPath / "Makefile", "test:\n\t@echo PASS\n")
  runCmdOrDie("git -C " & quoteShell(repoPath) & " add Makefile")
  runCmdOrDie("git -C " & quoteShell(repoPath) & " commit -m test-add-passing-makefile")

proc addFailingMakefile(repoPath: string) =
  ## Add a Makefile with a failing `make test` target and commit it on master.
  writeFile(repoPath / "Makefile", "test:\n\t@echo FAIL\n\t@false\n")
  runCmdOrDie("git -C " & quoteShell(repoPath) & " add Makefile")
  runCmdOrDie("git -C " & quoteShell(repoPath) & " commit -m test-add-failing-makefile")

suite "scriptorium --init":
  test "creates scriptorium/plan branch":
    let tmp = getTempDir() / "scriptorium_test_init_branch"
    makeTestRepo(tmp)
    defer: removeDir(tmp)

    runInit(tmp)

    let (_, rc) = execCmdEx("git -C " & tmp & " rev-parse --verify scriptorium/plan")
    check rc == 0

  test "plan branch contains correct folder structure":
    let tmp = getTempDir() / "scriptorium_test_init_structure"
    makeTestRepo(tmp)
    defer: removeDir(tmp)

    runInit(tmp)

    let (files, _) = execCmdEx("git -C " & tmp & " ls-tree -r --name-only scriptorium/plan")
    check "spec.md" in files
    check "areas/.gitkeep" in files
    check "tickets/open/.gitkeep" in files
    check "tickets/in-progress/.gitkeep" in files
    check "tickets/done/.gitkeep" in files
    check "decisions/.gitkeep" in files

  test "raises on already initialized workspace":
    let tmp = getTempDir() / "scriptorium_test_init_dupe"
    makeTestRepo(tmp)
    defer: removeDir(tmp)

    runInit(tmp)
    expect ValueError:
      runInit(tmp)

  test "raises on non-git directory":
    let tmp = getTempDir() / "scriptorium_test_not_a_repo"
    createDir(tmp)
    defer: removeDir(tmp)

    expect ValueError:
      runInit(tmp)

suite "config":
  test "defaults to fake unit-test codex model for both roles":
    let cfg = defaultConfig()
    check cfg.models.architect == "codex-fake-unit-test-model"
    check cfg.models.coding == "codex-fake-unit-test-model"

  test "loads from scriptorium.json":
    let tmp = getTempDir() / "scriptorium_test_config"
    createDir(tmp)
    defer: removeDir(tmp)
    writeFile(tmp / "scriptorium.json", """{"models":{"architect":"claude-opus-4-6","coding":"grok-code-fast-1"},"endpoints":{"local":"http://localhost:1234/v1"}}""")

    let cfg = loadConfig(tmp)
    check cfg.models.architect == "claude-opus-4-6"
    check cfg.models.coding == "grok-code-fast-1"
    check cfg.endpoints.local == "http://localhost:1234/v1"

  test "missing file returns defaults":
    let tmp = getTempDir() / "scriptorium_test_config_missing"
    createDir(tmp)
    defer: removeDir(tmp)

    let cfg = loadConfig(tmp)
    check cfg.models.architect == "codex-fake-unit-test-model"
    check cfg.models.coding == "codex-fake-unit-test-model"

  test "harness routing":
    check harness("claude-opus-4-6") == harnessClaudeCode
    check harness("claude-haiku-4-5") == harnessClaudeCode
    check harness("codex-fake-unit-test-model") == harnessCodex
    check harness("gpt-4o") == harnessCodex
    check harness("grok-code-fast-1") == harnessTypoi
    check harness("local/qwen3.5-35b-a3b") == harnessTypoi

suite "orchestrator endpoint":
  test "empty endpoint falls back to default":
    let endpoint = parseEndpoint("")
    check endpoint.address == "127.0.0.1"
    check endpoint.port == 8097

  test "parses endpoint from config value":
    let tmp = getTempDir() / "scriptorium_test_orchestrator_endpoint"
    createDir(tmp)
    defer: removeDir(tmp)
    writeFile(tmp / "scriptorium.json", """{"endpoints":{"local":"http://localhost:1234/v1"}}""")

    let endpoint = loadOrchestratorEndpoint(tmp)
    check endpoint.address == "localhost"
    check endpoint.port == 1234

  test "rejects endpoint missing host":
    expect ValueError:
      discard parseEndpoint("http:///v1")

suite "scriptorium CLI":
  test "status command prints ticket counts and active agent snapshot":
    let tmp = getTempDir() / "scriptorium_test_cli_status"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")
    addTicketToPlan(
      tmp,
      "in-progress",
      "0002-second.md",
      "# Ticket 2\n\n**Area:** b\n\n**Worktree:** /tmp/worktree-0002\n",
    )

    let (output, rc) = runCliInRepo(tmp, "status")
    let expected =
      "Open: 1\n" &
      "In Progress: 1\n" &
      "Done: 0\n" &
      "Active Agent Ticket: 0002 (tickets/in-progress/0002-second.md)\n" &
      "Active Agent Branch: scriptorium/ticket-0002\n" &
      "Active Agent Worktree: /tmp/worktree-0002\n"

    check rc == 0
    check output == expected

  test "worktrees command lists active ticket worktrees":
    let tmp = getTempDir() / "scriptorium_test_cli_worktrees"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addTicketToPlan(
      tmp,
      "in-progress",
      "0002-second.md",
      "# Ticket 2\n\n**Area:** b\n\n**Worktree:** /tmp/worktree-0002\n",
    )
    addTicketToPlan(
      tmp,
      "in-progress",
      "0001-first.md",
      "# Ticket 1\n\n**Area:** a\n\n**Worktree:** /tmp/worktree-0001\n",
    )

    let (output, rc) = runCliInRepo(tmp, "worktrees")
    let expected =
      "WORKTREE\tTICKET\tBRANCH\n" &
      "/tmp/worktree-0001\t0001\tscriptorium/ticket-0001\n" &
      "/tmp/worktree-0002\t0002\tscriptorium/ticket-0002\n"

    check rc == 0
    check output == expected

suite "orchestrator plan spec update":
  test "updateSpecFromArchitect writes spec and commits with mocked updater":
    let tmp = getTempDir() / "scriptorium_test_plan_update_spec"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)

    var callCount = 0
    var capturedFirstModel = ""
    var capturedFirstSpec = ""
    var capturedFirstPrompt = ""
    proc updater(model: string, currentSpec: string, prompt: string): string =
      ## Return a deterministic updated spec document for plan command tests.
      inc callCount
      if callCount == 1:
        capturedFirstModel = model
        capturedFirstSpec = currentSpec
        capturedFirstPrompt = prompt
      result = "# Revised Spec\n\n- item\n"

    let before = planCommitCount(tmp)
    let changed = updateSpecFromArchitect(tmp, "expand scope", updater)
    let after = planCommitCount(tmp)
    let unchanged = updateSpecFromArchitect(tmp, "expand scope", updater)
    let afterUnchanged = planCommitCount(tmp)
    let (specBody, specRc) = execCmdEx("git -C " & quoteShell(tmp) & " show scriptorium/plan:spec.md")
    let (logOutput, logRc) = execCmdEx("git -C " & quoteShell(tmp) & " log --oneline -1 scriptorium/plan")

    check changed
    check not unchanged
    check callCount == 2
    check capturedFirstModel == "codex-fake-unit-test-model"
    check "Run `scriptorium plan`" in capturedFirstSpec
    check capturedFirstPrompt == "expand scope"
    check after == before + 1
    check afterUnchanged == after
    check specRc == 0
    check specBody == "# Revised Spec\n\n- item\n"
    check logRc == 0
    check "scriptorium: update spec from architect" in logOutput

suite "orchestrator planning bootstrap":
  test "loads spec from plan branch":
    let tmp = getTempDir() / "scriptorium_test_plan_load_spec"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)

    let spec = loadSpecFromPlan(tmp)
    check "Run `scriptorium plan`" in spec

  test "missing spec raises error":
    let tmp = getTempDir() / "scriptorium_test_plan_missing_spec"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    removeSpecFromPlan(tmp)

    expect ValueError:
      discard loadSpecFromPlan(tmp)

  test "areas missing is true for blank plan and false when area exists":
    let tmp = getTempDir() / "scriptorium_test_areas_missing"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)

    check areasMissing(tmp)
    addAreaToPlan(tmp, "01-cli.md", "# Area 01\n")
    check not areasMissing(tmp)

  test "sync areas calls architect with configured model and spec":
    let tmp = getTempDir() / "scriptorium_test_sync_areas_call"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    writeFile(tmp / "scriptorium.json", """{"models":{"architect":"claude-opus-4-6"}}""")

    var callCount = 0
    var capturedModel = ""
    var capturedSpec = ""
    proc generator(model: string, spec: string): seq[AreaDocument] =
      ## Capture architect invocation arguments and return one area.
      inc callCount
      capturedModel = model
      capturedSpec = spec
      result = @[
        AreaDocument(path: "01-cli.md", content: "# Area 01\n\n## Scope\n- CLI\n")
      ]

    let synced = syncAreasFromSpec(tmp, generator)
    check synced
    check callCount == 1
    check capturedModel == "claude-opus-4-6"
    check "Run `scriptorium plan`" in capturedSpec

    let (files, rc) = execCmdEx("git -C " & quoteShell(tmp) & " ls-tree -r --name-only scriptorium/plan")
    check rc == 0
    check "areas/01-cli.md" in files

  test "sync areas is idempotent on second run":
    let tmp = getTempDir() / "scriptorium_test_sync_areas_idempotent"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)

    var callCount = 0
    proc generator(model: string, spec: string): seq[AreaDocument] =
      ## Return stable area output for idempotence checks.
      inc callCount
      discard model
      discard spec
      result = @[
        AreaDocument(path: "01-cli.md", content: "# Area 01\n\n## Scope\n- CLI\n")
      ]

    let before = planCommitCount(tmp)
    let firstSync = syncAreasFromSpec(tmp, generator)
    let afterFirst = planCommitCount(tmp)
    let secondSync = syncAreasFromSpec(tmp, generator)
    let afterSecond = planCommitCount(tmp)

    check firstSync
    check not secondSync
    check callCount == 1
    check afterFirst == before + 1
    check afterSecond == afterFirst

suite "orchestrator manager ticket bootstrap":
  test "areas needing tickets excludes areas with open or in-progress work":
    let tmp = getTempDir() / "scriptorium_test_areas_needing_tickets"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addAreaToPlan(tmp, "01-cli.md", "# Area 01\n")
    addAreaToPlan(tmp, "02-core.md", "# Area 02\n")
    addTicketToPlan(tmp, "open", "0001-cli-ticket.md", "# Ticket\n\n**Area:** 01-cli\n")

    let needed = areasNeedingTickets(tmp)
    check "areas/02-core.md" in needed
    check "areas/01-cli.md" notin needed

  test "sync tickets calls manager with configured coding model":
    let tmp = getTempDir() / "scriptorium_test_sync_tickets_call"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addAreaToPlan(tmp, "01-cli.md", "# Area 01\n\n## Scope\n- CLI\n")
    writeFile(tmp / "scriptorium.json", """{"models":{"coding":"grok-code-fast-1"}}""")

    var callCount = 0
    var capturedModel = ""
    var capturedAreaPath = ""
    var capturedAreaContent = ""
    proc generator(model: string, areaPath: string, areaContent: string): seq[TicketDocument] =
      ## Capture manager invocation arguments and return one ticket.
      inc callCount
      capturedModel = model
      capturedAreaPath = areaPath
      capturedAreaContent = areaContent
      result = @[
        TicketDocument(slug: "cli-bootstrap", content: "# Ticket 1\n")
      ]

    let before = planCommitCount(tmp)
    let synced = syncTicketsFromAreas(tmp, generator)
    let after = planCommitCount(tmp)

    check synced
    check callCount == 1
    check capturedModel == "grok-code-fast-1"
    check capturedAreaPath == "areas/01-cli.md"
    check "## Scope" in capturedAreaContent
    check after == before + 1

    let files = planTreeFiles(tmp)
    check "tickets/open/0001-cli-bootstrap.md" in files

    let (logOutput, rc) = execCmdEx(
      "git -C " & quoteShell(tmp) & " log --oneline -1 scriptorium/plan"
    )
    check rc == 0
    check "scriptorium: create tickets from areas" in logOutput

  test "ticket IDs are monotonic based on existing highest ID":
    let tmp = getTempDir() / "scriptorium_test_ticket_id_monotonic"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addAreaToPlan(tmp, "01-cli.md", "# Area 01\n")
    addAreaToPlan(tmp, "02-core.md", "# Area 02\n")
    addTicketToPlan(tmp, "done", "0042-already-done.md", "# Done Ticket\n\n**Area:** old\n")

    proc generator(model: string, areaPath: string, areaContent: string): seq[TicketDocument] =
      ## Return one ticket per area for monotonic ID checks.
      discard model
      discard areaPath
      discard areaContent
      result = @[
        TicketDocument(slug: "next-task", content: "# New Ticket\n")
      ]

    discard syncTicketsFromAreas(tmp, generator)

    let files = planTreeFiles(tmp)
    check "tickets/open/0043-next-task.md" in files
    check "tickets/open/0044-next-task.md" in files

  test "sync tickets is idempotent on second run":
    let tmp = getTempDir() / "scriptorium_test_sync_tickets_idempotent"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addAreaToPlan(tmp, "01-cli.md", "# Area 01\n")

    var callCount = 0
    proc generator(model: string, areaPath: string, areaContent: string): seq[TicketDocument] =
      ## Return stable ticket output for idempotence checks.
      inc callCount
      discard model
      discard areaPath
      discard areaContent
      result = @[
        TicketDocument(slug: "stable-task", content: "# Stable Ticket\n")
      ]

    let before = planCommitCount(tmp)
    let firstSync = syncTicketsFromAreas(tmp, generator)
    let afterFirst = planCommitCount(tmp)
    let secondSync = syncTicketsFromAreas(tmp, generator)
    let afterSecond = planCommitCount(tmp)

    check firstSync
    check not secondSync
    check callCount == 1
    check afterFirst == before + 1
    check afterSecond == afterFirst

suite "orchestrator ticket assignment":
  test "oldest open ticket picks the lowest numeric ID":
    let tmp = getTempDir() / "scriptorium_test_oldest_open_ticket"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addTicketToPlan(tmp, "open", "0002-second.md", "# Ticket 2\n\n**Area:** b\n")
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

    let oldest = oldestOpenTicket(tmp)
    check oldest == "tickets/open/0001-first.md"

  test "assign moves ticket to in-progress in one commit":
    let tmp = getTempDir() / "scriptorium_test_assign_transition"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

    let before = planCommitCount(tmp)
    let assignment = assignOldestOpenTicket(tmp)
    let after = planCommitCount(tmp)
    let files = planTreeFiles(tmp)

    check assignment.openTicket == "tickets/open/0001-first.md"
    check assignment.inProgressTicket == "tickets/in-progress/0001-first.md"
    check "tickets/in-progress/0001-first.md" in files
    check "tickets/open/0001-first.md" notin files
    check after == before + 1

  test "assign creates worktree and writes worktree metadata":
    let tmp = getTempDir() / "scriptorium_test_assign_worktree"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

    let assignment = assignOldestOpenTicket(tmp)
    check assignment.worktree.len > 0
    check assignment.branch == "scriptorium/ticket-0001"
    check assignment.worktree in gitWorktreePaths(tmp)

    let (ticketContent, rc) = execCmdEx(
      "git -C " & quoteShell(tmp) & " show scriptorium/plan:tickets/in-progress/0001-first.md"
    )
    check rc == 0
    check ("**Worktree:** " & assignment.worktree) in ticketContent

  test "cleanup removes stale ticket worktrees":
    let tmp = getTempDir() / "scriptorium_test_cleanup_worktree"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

    let assignment = assignOldestOpenTicket(tmp)
    moveTicketStateInPlan(tmp, "in-progress", "done", "0001-first.md")

    let removed = cleanupStaleTicketWorktrees(tmp)
    check assignment.worktree in removed
    check assignment.worktree notin gitWorktreePaths(tmp)

suite "orchestrator coding agent execution":
  test "executeAssignedTicket runs agent and appends run summary":
    let tmp = getTempDir() / "scriptorium_test_execute_assigned_ticket"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

    let assignment = assignOldestOpenTicket(tmp)
    let before = planCommitCount(tmp)

    var callCount = 0
    var capturedRequest = AgentRunRequest()
    proc fakeRunner(request: AgentRunRequest): AgentRunResult =
      ## Capture one request and return a deterministic successful run result.
      inc callCount
      capturedRequest = request
      result = AgentRunResult(
        backend: harnessCodex,
        command: @["codex", "exec"],
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        stdout: """{"type":"message","text":"done"}""",
        logFile: assignment.worktree / ".scriptorium/logs/0001/attempt-01.jsonl",
        lastMessageFile: assignment.worktree / ".scriptorium/logs/0001/attempt-01.last_message.txt",
        lastMessage: "Implemented the ticket.",
        timeoutKind: "none",
      )

    let runResult = executeAssignedTicket(tmp, assignment, fakeRunner)
    let after = planCommitCount(tmp)

    check callCount == 1
    check capturedRequest.model == "codex-fake-unit-test-model"
    check capturedRequest.workingDir == assignment.worktree
    check capturedRequest.ticketId == "0001"
    check "Ticket 1" in capturedRequest.prompt
    check runResult.exitCode == 0
    check after == before + 1

    let (ticketContent, ticketRc) = execCmdEx(
      "git -C " & quoteShell(tmp) & " show scriptorium/plan:tickets/in-progress/0001-first.md"
    )
    check ticketRc == 0
    check "## Agent Run" in ticketContent
    check "- Model: codex-fake-unit-test-model" in ticketContent
    check "- Exit Code: 0" in ticketContent

    let (commitOutput, commitRc) = execCmdEx(
      "git -C " & quoteShell(tmp) & " log --oneline -1 scriptorium/plan"
    )
    check commitRc == 0
    check "scriptorium: record agent run 0001-first" in commitOutput

  test "executeAssignedTicket enqueues merge request from submit_pr":
    let tmp = getTempDir() / "scriptorium_test_execute_assigned_enqueue"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addPassingMakefile(tmp)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

    let assignment = assignOldestOpenTicket(tmp)
    let before = planCommitCount(tmp)
    proc fakeRunner(request: AgentRunRequest): AgentRunResult =
      ## Return a deterministic run result that asks to submit a PR.
      discard request
      result = AgentRunResult(
        backend: harnessCodex,
        command: @["codex", "exec"],
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        stdout: "",
        logFile: assignment.worktree / ".scriptorium/logs/0001/attempt-01.jsonl",
        lastMessageFile: assignment.worktree / ".scriptorium/logs/0001/attempt-01.last_message.txt",
        lastMessage: "Work complete.\nsubmit_pr(\"ship it\")",
        timeoutKind: "none",
      )

    discard executeAssignedTicket(tmp, assignment, fakeRunner)
    let after = planCommitCount(tmp)
    let files = planTreeFiles(tmp)

    check after == before + 2
    check "queue/merge/pending/0001-0001.md" in files
    let (queueEntry, queueRc) = execCmdEx(
      "git -C " & quoteShell(tmp) & " show scriptorium/plan:queue/merge/pending/0001-0001.md"
    )
    check queueRc == 0
    check "**Summary:** ship it" in queueEntry
    check "**Branch:** scriptorium/ticket-0001" in queueEntry

suite "orchestrator merge queue":
  test "ensureMergeQueueInitialized is idempotent":
    let tmp = getTempDir() / "scriptorium_test_merge_queue_init"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)

    let before = planCommitCount(tmp)
    let first = ensureMergeQueueInitialized(tmp)
    let afterFirst = planCommitCount(tmp)
    let second = ensureMergeQueueInitialized(tmp)
    let afterSecond = planCommitCount(tmp)
    let files = planTreeFiles(tmp)

    check first
    check not second
    check afterFirst == before + 1
    check afterSecond == afterFirst
    check "queue/merge/pending/.gitkeep" in files
    check "queue/merge/active.md" in files

  test "processMergeQueue handles one item per call":
    let tmp = getTempDir() / "scriptorium_test_merge_queue_single_flight"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addPassingMakefile(tmp)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")
    addTicketToPlan(tmp, "open", "0002-second.md", "# Ticket 2\n\n**Area:** b\n")

    let firstAssignment = assignOldestOpenTicket(tmp)
    let secondAssignment = assignOldestOpenTicket(tmp)
    discard enqueueMergeRequest(tmp, firstAssignment, "first summary")
    discard enqueueMergeRequest(tmp, secondAssignment, "second summary")

    let processed = processMergeQueue(tmp)
    let files = planTreeFiles(tmp)
    let queueFiles = files.filterIt(it.startsWith("queue/merge/pending/") and it.endsWith(".md"))

    check processed
    check "tickets/done/0001-first.md" in files
    check "tickets/in-progress/0002-second.md" in files
    check queueFiles.len == 1
    check queueFiles[0] == "queue/merge/pending/0002-0002.md"

  test "processMergeQueue success path merges to master and moves ticket to done":
    let tmp = getTempDir() / "scriptorium_test_merge_queue_success"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addPassingMakefile(tmp)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

    let assignment = assignOldestOpenTicket(tmp)
    writeFile(assignment.worktree / "ticket-output.txt", "done\n")
    runCmdOrDie("git -C " & quoteShell(assignment.worktree) & " add ticket-output.txt")
    runCmdOrDie("git -C " & quoteShell(assignment.worktree) & " commit -m ticket-output")
    discard enqueueMergeRequest(tmp, assignment, "merge me")

    let processed = processMergeQueue(tmp)
    let files = planTreeFiles(tmp)
    check processed
    check "tickets/done/0001-first.md" in files
    check "queue/merge/pending/0001-0001.md" notin files

    let (masterFile, masterRc) = execCmdEx("git -C " & quoteShell(tmp) & " show master:ticket-output.txt")
    check masterRc == 0
    check masterFile.strip() == "done"

    let (ticketContent, ticketRc) = execCmdEx(
      "git -C " & quoteShell(tmp) & " show scriptorium/plan:tickets/done/0001-first.md"
    )
    check ticketRc == 0
    check "## Merge Queue Success" in ticketContent

  test "processMergeQueue failure path reopens ticket with failure note":
    let tmp = getTempDir() / "scriptorium_test_merge_queue_failure"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp)
    addFailingMakefile(tmp)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

    let assignment = assignOldestOpenTicket(tmp)
    discard enqueueMergeRequest(tmp, assignment, "expected failure")
    let processed = processMergeQueue(tmp)
    let files = planTreeFiles(tmp)

    check processed
    check "tickets/open/0001-first.md" in files
    check "tickets/in-progress/0001-first.md" notin files
    check "queue/merge/pending/0001-0001.md" notin files

    let (ticketContent, ticketRc) = execCmdEx(
      "git -C " & quoteShell(tmp) & " show scriptorium/plan:tickets/open/0001-first.md"
    )
    check ticketRc == 0
    check "## Merge Queue Failure" in ticketContent
