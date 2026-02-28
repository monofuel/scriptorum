## Tests for the scriptorium CLI and core utilities.

import
  std/[algorithm, os, osproc, sequtils, strformat, strutils, tempfiles, unittest],
  jsony,
  scriptorium/[agent_runner, config, init, logging, orchestrator]

const
  OrchestratorTestBasePort = 19000

type
  StreamMessageJson = object
    `type`*: string
    text*: string

proc makeTestRepo(path: string) =
  ## Create a minimal git repository at path suitable for testing.
  if dirExists(path):
    removeDir(path)
  createDir(path)
  discard execCmdEx("git -C " & path & " init")
  discard execCmdEx("git -C " & path & " config user.email test@test.com")
  discard execCmdEx("git -C " & path & " config user.name Test")
  discard execCmdEx("git -C " & path & " commit --allow-empty -m initial")

proc runCmdOrDie(cmd: string) =
  ## Run a shell command and fail the test immediately if it exits non-zero.
  let (_, rc) = execCmdEx(cmd)
  doAssert rc == 0, cmd

proc normalizedPathForTest(path: string): string =
  ## Return an absolute path with forward slash separators for assertions.
  result = absolutePath(path).replace('\\', '/')

proc writeScriptoriumConfig(repoPath: string, cfg: Config) =
  ## Write one typed scriptorium.json payload for test configuration.
  writeFile(repoPath / "scriptorium.json", cfg.toJson())

proc writeOrchestratorEndpointConfig(repoPath: string, portOffset: int) =
  ## Write a unique local orchestrator endpoint configuration for one test.
  let basePort = OrchestratorTestBasePort + (getCurrentProcessId().int mod 1000)
  let orchestratorPort = basePort + portOffset
  var cfg = defaultConfig()
  cfg.endpoints.local = &"http://127.0.0.1:{orchestratorPort}"
  writeScriptoriumConfig(repoPath, cfg)

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

proc writeSpecInPlan(repoPath: string, content: string) =
  ## Replace spec.md on scriptorium/plan and commit the change.
  withPlanWorktree(repoPath, "write_spec", proc(planPath: string) =
    writeFile(planPath / "spec.md", content)
    runCmdOrDie("git -C " & quoteShell(planPath) & " add spec.md")
    runCmdOrDie("git -C " & quoteShell(planPath) & " commit -m test-write-spec")
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

proc withTempRepo(prefix: string, action: proc(repoPath: string)) =
  ## Create a temporary git repository, run action, and clean up afterwards.
  let repoPath = createTempDir(prefix, "", getTempDir())
  defer:
    removeDir(repoPath)
  makeTestRepo(repoPath)
  action(repoPath)

proc pendingQueueFiles(repoPath: string): seq[string] =
  ## Return pending merge-queue markdown entries sorted by file name.
  let files = planTreeFiles(repoPath)
  result = files.filterIt(it.startsWith("queue/merge/pending/") and it.endsWith(".md"))
  result.sort()

proc readPlanFile(repoPath: string, relPath: string): string =
  ## Read one file from the plan branch tree.
  let (output, rc) = execCmdEx(
    "git -C " & quoteShell(repoPath) & " show scriptorium/plan:" & relPath
  )
  doAssert rc == 0, relPath
  result = output

proc latestPlanCommits(repoPath: string, count: int): seq[string] =
  ## Return the latest commit subjects from the plan branch.
  let (output, rc) = execCmdEx(
    "git -C " & quoteShell(repoPath) & " log --format=%s -n " & $count & " scriptorium/plan"
  )
  doAssert rc == 0
  result = output.splitLines().filterIt(it.len > 0)

suite "scriptorium --init":
  test "creates scriptorium/plan branch":
    let tmp = getTempDir() / "scriptorium_test_init_branch"
    makeTestRepo(tmp)
    defer: removeDir(tmp)

    runInit(tmp, quiet = true)

    let (_, rc) = execCmdEx("git -C " & tmp & " rev-parse --verify scriptorium/plan")
    check rc == 0

  test "plan branch contains correct folder structure":
    let tmp = getTempDir() / "scriptorium_test_init_structure"
    makeTestRepo(tmp)
    defer: removeDir(tmp)

    runInit(tmp, quiet = true)

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

    runInit(tmp, quiet = true)
    expect ValueError:
      runInit(tmp, quiet = true)

  test "raises on non-git directory":
    let tmp = getTempDir() / "scriptorium_test_not_a_repo"
    createDir(tmp)
    defer: removeDir(tmp)

    expect ValueError:
      runInit(tmp, quiet = true)

suite "config":
  test "defaults to fake unit-test codex model for architect, coding, and manager roles":
    let cfg = defaultConfig()
    check cfg.models.architect == "codex-fake-unit-test-model"
    check cfg.models.coding == "codex-fake-unit-test-model"
    check cfg.models.manager == "codex-fake-unit-test-model"
    check cfg.reasoningEffort.architect == ""
    check cfg.reasoningEffort.coding == ""
    check cfg.reasoningEffort.manager == ""

  test "loads from scriptorium.json":
    let tmp = getTempDir() / "scriptorium_test_config"
    createDir(tmp)
    defer: removeDir(tmp)
    var writtenCfg = defaultConfig()
    writtenCfg.models.architect = "claude-opus-4-6"
    writtenCfg.models.coding = "grok-code-fast-1"
    writtenCfg.models.manager = "gpt-5.1-codex-mini"
    writtenCfg.reasoningEffort.architect = "medium"
    writtenCfg.reasoningEffort.coding = "high"
    writtenCfg.reasoningEffort.manager = "low"
    writtenCfg.endpoints.local = "http://localhost:1234/v1"
    writeScriptoriumConfig(tmp, writtenCfg)

    let cfg = loadConfig(tmp)
    check cfg.models.architect == "claude-opus-4-6"
    check cfg.models.coding == "grok-code-fast-1"
    check cfg.models.manager == "gpt-5.1-codex-mini"
    check cfg.reasoningEffort.architect == "medium"
    check cfg.reasoningEffort.coding == "high"
    check cfg.reasoningEffort.manager == "low"
    check cfg.endpoints.local == "http://localhost:1234/v1"

  test "manager model remains independent when manager is unset":
    let tmp = getTempDir() / "scriptorium_test_config_manager_independent"
    createDir(tmp)
    defer: removeDir(tmp)
    var writtenCfg = defaultConfig()
    writtenCfg.models.coding = "grok-code-fast-1"
    writtenCfg.models.manager = ""
    writtenCfg.reasoningEffort.coding = "high"
    writeScriptoriumConfig(tmp, writtenCfg)

    let cfg = loadConfig(tmp)
    check cfg.models.coding == "grok-code-fast-1"
    check cfg.models.manager == "codex-fake-unit-test-model"
    check cfg.reasoningEffort.coding == "high"
    check cfg.reasoningEffort.manager == ""

  test "missing file returns defaults":
    let tmp = getTempDir() / "scriptorium_test_config_missing"
    createDir(tmp)
    defer: removeDir(tmp)

    let cfg = loadConfig(tmp)
    check cfg.models.architect == "codex-fake-unit-test-model"
    check cfg.models.coding == "codex-fake-unit-test-model"
    check cfg.models.manager == "codex-fake-unit-test-model"
    check cfg.reasoningEffort.architect == ""
    check cfg.reasoningEffort.coding == ""
    check cfg.reasoningEffort.manager == ""

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
    var writtenCfg = defaultConfig()
    writtenCfg.endpoints.local = "http://localhost:1234/v1"
    writeScriptoriumConfig(tmp, writtenCfg)

    let endpoint = loadOrchestratorEndpoint(tmp)
    check endpoint.address == "localhost"
    check endpoint.port == 1234

  test "rejects endpoint missing host":
    expect ValueError:
      discard parseEndpoint("http:///v1")

suite "orchestrator plan spec update":
  test "updateSpecFromArchitect runs in plan worktree, reads repo path, and commits":
    let tmp = getTempDir() / "scriptorium_test_plan_update_spec"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)

    writeFile(tmp / "source-marker.txt", "alpha\n")
    runCmdOrDie("git -C " & quoteShell(tmp) & " add source-marker.txt")
    runCmdOrDie("git -C " & quoteShell(tmp) & " commit -m test-add-source-marker")
    var writtenCfg = defaultConfig()
    writtenCfg.reasoningEffort.architect = "high"
    writeScriptoriumConfig(tmp, writtenCfg)

    var callCount = 0
    var capturedFirstModel = ""
    var capturedFirstReasoningEffort = ""
    var capturedFirstWorkingDir = ""
    var capturedFirstRepoPath = ""
    var capturedFirstSpec = ""
    var capturedFirstUserRequest = ""
    proc fakeRunner(req: AgentRunRequest): AgentRunResult =
      ## Read source via repo path from prompt and update spec.md in plan worktree.
      inc callCount
      check req.heartbeatIntervalMs == 0
      check req.onEvent.isNil
      let repoPathMarker = "Repository root path (read project source files from here):\n"
      let repoPathMarkerIndex = req.prompt.find(repoPathMarker)
      doAssert repoPathMarkerIndex >= 0
      let repoPathStart = repoPathMarkerIndex + repoPathMarker.len
      let repoPathEnd = req.prompt.find('\n', repoPathStart)
      doAssert repoPathEnd > repoPathStart
      let repoPathFromPrompt = req.prompt[repoPathStart..<repoPathEnd].strip()
      let priorSpec = readFile(req.workingDir / "spec.md")
      let sourceMarker = readFile(repoPathFromPrompt / "source-marker.txt").strip()
      writeFile(req.workingDir / "spec.md", "# Revised Spec\n\n- marker: " & sourceMarker & "\n")

      if callCount == 1:
        capturedFirstModel = req.model
        capturedFirstReasoningEffort = req.reasoningEffort
        capturedFirstWorkingDir = req.workingDir
        capturedFirstRepoPath = repoPathFromPrompt
        capturedFirstSpec = priorSpec
        capturedFirstUserRequest = req.prompt

      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "Updated spec.",
        timeoutKind: "none",
      )

    let before = planCommitCount(tmp)
    let changed = updateSpecFromArchitect(tmp, "expand scope", fakeRunner)
    let after = planCommitCount(tmp)
    let unchanged = updateSpecFromArchitect(tmp, "expand scope", fakeRunner)
    let afterUnchanged = planCommitCount(tmp)
    let (specBody, specRc) = execCmdEx("git -C " & quoteShell(tmp) & " show scriptorium/plan:spec.md")
    let (logOutput, logRc) = execCmdEx("git -C " & quoteShell(tmp) & " log --oneline -1 scriptorium/plan")

    check changed
    check not unchanged
    check callCount == 2
    check capturedFirstModel == "codex-fake-unit-test-model"
    check capturedFirstReasoningEffort == "high"
    check capturedFirstWorkingDir != tmp
    check capturedFirstRepoPath == tmp
    check "Run `scriptorium plan`" in capturedFirstSpec
    check "expand scope" in capturedFirstUserRequest
    check "AGENTS.md" in capturedFirstUserRequest
    check "Only edit spec.md in this working directory." in capturedFirstUserRequest
    check "If the request is discussion, analysis, or questions, reply directly and do not edit spec.md." in capturedFirstUserRequest
    check "Only edit spec.md when the engineer is asking to change plan content." in capturedFirstUserRequest
    check after == before + 1
    check afterUnchanged == after
    check specRc == 0
    check specBody == "# Revised Spec\n\n- marker: alpha\n"
    check logRc == 0
    check "scriptorium: update spec from architect" in logOutput

  test "updateSpecFromArchitect rejects writes outside spec.md":
    let tmp = getTempDir() / "scriptorium_test_plan_out_of_scope"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)

    proc fakeRunner(req: AgentRunRequest): AgentRunResult =
      ## Write to spec.md and one out-of-scope path to trigger guard failure.
      writeFile(req.workingDir / "spec.md", "# Updated Spec\n")
      writeFile(req.workingDir / "areas/01-out-of-scope.md", "# Bad write\n")
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "done",
        timeoutKind: "none",
      )

    let before = planCommitCount(tmp)
    expect ValueError:
      discard updateSpecFromArchitect(tmp, "expand scope", fakeRunner)
    let after = planCommitCount(tmp)
    let files = planTreeFiles(tmp)

    check after == before
    check "areas/01-out-of-scope.md" notin files

  test "updateSpecFromArchitect recovers stale managed deterministic worktree conflicts":
    let tmp = getTempDir() / "scriptorium_test_plan_stale_temp_conflict"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)

    var managedPlanPath = ""
    proc bootstrapRunner(req: AgentRunRequest): AgentRunResult =
      ## Capture the deterministic managed plan worktree path.
      managedPlanPath = req.workingDir
      writeFile(req.workingDir / "spec.md", "# Updated Spec\n\n- bootstrap\n")
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "done",
        timeoutKind: "none",
      )
    discard updateSpecFromArchitect(tmp, "bootstrap managed path", bootstrapRunner)
    check managedPlanPath.len > 0
    check "/worktrees/plan" in normalizedPathForTest(managedPlanPath)

    runCmdOrDie("git -C " & quoteShell(tmp) & " worktree add " & quoteShell(managedPlanPath) & " scriptorium/plan")
    defer:
      discard execCmdEx("git -C " & quoteShell(tmp) & " worktree remove --force " & quoteShell(managedPlanPath))
      discard execCmdEx("git -C " & quoteShell(tmp) & " worktree prune")
      if dirExists(managedPlanPath):
        removeDir(managedPlanPath)
    removeDir(managedPlanPath)

    proc fakeRunner(req: AgentRunRequest): AgentRunResult =
      ## Update spec.md in the recovered deterministic worktree.
      writeFile(req.workingDir / "spec.md", "# Updated Spec\n\n- recovered\n")
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "done",
        timeoutKind: "none",
      )

    let changed = updateSpecFromArchitect(tmp, "recover stale temp", fakeRunner)
    let worktrees = gitWorktreePaths(tmp)

    check changed
    check managedPlanPath notin worktrees

  test "updateSpecFromArchitect keeps non-managed plan worktree conflicts intact":
    let tmp = getTempDir() / "scriptorium_test_plan_manual_conflict"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)

    let manualPath = getTempDir() / "scriptorium_manual_plan_conflict"
    if dirExists(manualPath):
      removeDir(manualPath)
    runCmdOrDie("git -C " & quoteShell(tmp) & " worktree add " & quoteShell(manualPath) & " scriptorium/plan")
    defer:
      discard execCmdEx("git -C " & quoteShell(tmp) & " worktree remove --force " & quoteShell(manualPath))
      discard execCmdEx("git -C " & quoteShell(tmp) & " worktree prune")
      if dirExists(manualPath):
        removeDir(manualPath)

    var runnerCalls = 0
    proc fakeRunner(req: AgentRunRequest): AgentRunResult =
      ## Track invocations; this runner should not be called on add conflict.
      inc runnerCalls
      discard req
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "",
        timeoutKind: "none",
      )

    var errorMessage = ""
    try:
      discard updateSpecFromArchitect(tmp, "conflict", fakeRunner)
    except IOError as err:
      errorMessage = err.msg

    let worktrees = gitWorktreePaths(tmp)
    check runnerCalls == 0
    check "already used by worktree" in errorMessage
    check manualPath in worktrees

  test "updateSpecFromArchitect fails fast when planner lock is held":
    let tmp = getTempDir() / "scriptorium_test_plan_lock_busy"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)

    var managedPlanPath = ""
    proc bootstrapRunner(req: AgentRunRequest): AgentRunResult =
      ## Capture deterministic plan path so tests can derive lock location.
      managedPlanPath = req.workingDir
      writeFile(req.workingDir / "spec.md", "# Updated Spec\n\n- bootstrap\n")
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "done",
        timeoutKind: "none",
      )
    discard updateSpecFromArchitect(tmp, "bootstrap lock path", bootstrapRunner)
    check managedPlanPath.len > 0

    let managedRepoRoot = parentDir(parentDir(managedPlanPath))
    let lockPath = managedRepoRoot / "locks/repo.lock"
    createDir(parentDir(lockPath))
    createDir(lockPath)
    let pidPath = lockPath / "pid"
    let currentPid = getCurrentProcessId()
    writeFile(pidPath, $currentPid & "\n")
    defer:
      if fileExists(pidPath):
        removeFile(pidPath)
      if dirExists(lockPath):
        removeDir(lockPath)

    var runnerCalls = 0
    proc fakeRunner(req: AgentRunRequest): AgentRunResult =
      ## Track invocations; lock contention should fail before runner starts.
      inc runnerCalls
      discard req
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "",
        timeoutKind: "none",
      )

    var errorMessage = ""
    try:
      discard updateSpecFromArchitect(tmp, "blocked by lock", fakeRunner)
    except IOError as err:
      errorMessage = err.msg

    check runnerCalls == 0
    check "another planner/manager is active" in errorMessage

suite "orchestrator invariants":
  test "ticket state invariant fails when same ticket exists in multiple state directories":
    let tmp = getTempDir() / "scriptorium_test_invariant_duplicate_ticket_states"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")
    addTicketToPlan(tmp, "done", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

    expect ValueError:
      validateTicketStateInvariant(tmp)

  test "transition commit invariant passes for orchestrator-managed state moves":
    let tmp = getTempDir() / "scriptorium_test_invariant_transition_pass"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

    discard assignOldestOpenTicket(tmp)
    validateTransitionCommitInvariant(tmp)

  test "transition commit invariant fails for non-orchestrator ticket move commit":
    let tmp = getTempDir() / "scriptorium_test_invariant_transition_fail"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")
    moveTicketStateInPlan(tmp, "open", "in-progress", "0001-first.md")

    expect ValueError:
      validateTransitionCommitInvariant(tmp)

  test "simulated crash during ticket move keeps prior valid state":
    let tmp = getTempDir() / "scriptorium_test_invariant_no_partial_move_on_crash"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")
    let before = planCommitCount(tmp)

    expect IOError:
      withPlanWorktree(tmp, "simulated_crash_partial_move", proc(planPath: string) =
        moveFile(
          planPath / "tickets/open/0001-first.md",
          planPath / "tickets/in-progress/0001-first.md",
        )
        raise newException(IOError, "simulated crash before commit")
      )

    let files = planTreeFiles(tmp)
    let after = planCommitCount(tmp)
    check "tickets/open/0001-first.md" in files
    check "tickets/in-progress/0001-first.md" notin files
    check after == before
    validateTicketStateInvariant(tmp)

suite "orchestrator planning bootstrap":
  test "loads spec from plan branch":
    let tmp = getTempDir() / "scriptorium_test_plan_load_spec"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)

    let spec = loadSpecFromPlan(tmp)
    check "Run `scriptorium plan`" in spec

  test "missing spec raises error":
    let tmp = getTempDir() / "scriptorium_test_plan_missing_spec"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    removeSpecFromPlan(tmp)

    expect ValueError:
      discard loadSpecFromPlan(tmp)

  test "areas missing is true for blank plan and false when area exists":
    let tmp = getTempDir() / "scriptorium_test_areas_missing"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)

    check areasMissing(tmp)
    addAreaToPlan(tmp, "01-cli.md", "# Area 01\n")
    check not areasMissing(tmp)

  test "sync areas calls architect with configured model and spec":
    let tmp = getTempDir() / "scriptorium_test_sync_areas_call"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    var writtenCfg = defaultConfig()
    writtenCfg.models.architect = "claude-opus-4-6"
    writeScriptoriumConfig(tmp, writtenCfg)

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
    runInit(tmp, quiet = true)

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
    runInit(tmp, quiet = true)
    addAreaToPlan(tmp, "01-cli.md", "# Area 01\n")
    addAreaToPlan(tmp, "02-core.md", "# Area 02\n")
    addTicketToPlan(tmp, "open", "0001-cli-ticket.md", "# Ticket\n\n**Area:** 01-cli\n")

    let needed = areasNeedingTickets(tmp)
    check "areas/02-core.md" in needed
    check "areas/01-cli.md" notin needed

  test "sync tickets calls manager with configured manager model":
    let tmp = getTempDir() / "scriptorium_test_sync_tickets_call"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    addAreaToPlan(tmp, "01-cli.md", "# Area 01\n\n## Scope\n- CLI\n")
    var writtenCfg = defaultConfig()
    writtenCfg.models.coding = "grok-code-fast-1"
    writtenCfg.models.manager = "gpt-5.1-codex-mini"
    writeScriptoriumConfig(tmp, writtenCfg)

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
    check capturedModel == "gpt-5.1-codex-mini"
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
    runInit(tmp, quiet = true)
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
    runInit(tmp, quiet = true)
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
    runInit(tmp, quiet = true)
    addTicketToPlan(tmp, "open", "0002-second.md", "# Ticket 2\n\n**Area:** b\n")
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

    let oldest = oldestOpenTicket(tmp)
    check oldest == "tickets/open/0001-first.md"

  test "assign moves ticket to in-progress in one commit":
    let tmp = getTempDir() / "scriptorium_test_assign_transition"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
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
    runInit(tmp, quiet = true)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

    let assignment = assignOldestOpenTicket(tmp)
    let normalizedWorktreePath = normalizedPathForTest(assignment.worktree)
    let normalizedManagedRoot = normalizedPathForTest(getTempDir() / "scriptorium")
    let normalizedRepoPath = normalizedPathForTest(tmp)
    check assignment.worktree.len > 0
    check assignment.branch == "scriptorium/ticket-0001"
    check assignment.worktree in gitWorktreePaths(tmp)
    check normalizedWorktreePath.startsWith(normalizedManagedRoot & "/")
    check not normalizedWorktreePath.startsWith(normalizedRepoPath & "/")

    let (ticketContent, rc) = execCmdEx(
      "git -C " & quoteShell(tmp) & " show scriptorium/plan:tickets/in-progress/0001-first.md"
    )
    check rc == 0
    check ("**Worktree:** " & assignment.worktree) in ticketContent

  test "cleanup removes stale ticket worktrees":
    let tmp = getTempDir() / "scriptorium_test_cleanup_worktree"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
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
    runInit(tmp, quiet = true)
    addTicketToPlan(tmp, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")
    var writtenCfg = defaultConfig()
    writtenCfg.reasoningEffort.coding = "high"
    writeScriptoriumConfig(tmp, writtenCfg)

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
        stdout: toJson(StreamMessageJson(`type`: "message", text: "done")),
        logFile: assignment.worktree / ".scriptorium/logs/0001/attempt-01.jsonl",
        lastMessageFile: assignment.worktree / ".scriptorium/logs/0001/attempt-01.last_message.txt",
        lastMessage: "Implemented the ticket.",
        timeoutKind: "none",
      )

    let runResult = executeAssignedTicket(tmp, assignment, fakeRunner)
    let after = planCommitCount(tmp)

    check callCount == 1
    check capturedRequest.model == "codex-fake-unit-test-model"
    check capturedRequest.reasoningEffort == "high"
    check capturedRequest.workingDir == assignment.worktree
    check capturedRequest.ticketId == "0001"
    check "Ticket 1" in capturedRequest.prompt
    check tmp in capturedRequest.prompt
    check "AGENTS.md" in capturedRequest.prompt
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
    runInit(tmp, quiet = true)
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
    runInit(tmp, quiet = true)

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
    runInit(tmp, quiet = true)
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
    runInit(tmp, quiet = true)
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
    runInit(tmp, quiet = true)
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

suite "orchestrator final v1 flow":
  test "blank spec tick skips orchestration and does not invoke agents":
    let tmp = getTempDir() / "scriptorium_test_v1_36_blank_spec_guard"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    addPassingMakefile(tmp)
    writeOrchestratorEndpointConfig(tmp, 21)

    var callCount = 0
    proc fakeRunner(request: AgentRunRequest): AgentRunResult =
      ## Count calls to verify no architect/manager/coding runner executes.
      inc callCount
      discard request
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "",
        timeoutKind: "none",
      )

    let before = planCommitCount(tmp)
    runOrchestratorForTicks(tmp, 1, fakeRunner)
    let after = planCommitCount(tmp)

    check callCount == 0
    check after == before

  test "runArchitectAreas commits files written by mocked architect runner":
    let tmp = getTempDir() / "scriptorium_test_v1_37_run_architect_areas"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    writeSpecInPlan(tmp, "# Spec\n\nBuild area files.\n")
    var writtenCfg = defaultConfig()
    writtenCfg.reasoningEffort.architect = "high"
    writeScriptoriumConfig(tmp, writtenCfg)

    var callCount = 0
    var capturedRequest = AgentRunRequest()
    proc fakeRunner(request: AgentRunRequest): AgentRunResult =
      ## Write one area file directly into areas/ from the plan worktree.
      inc callCount
      capturedRequest = request
      writeFile(request.workingDir / "areas/01-arch.md", "# Area 01\n")
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "areas written",
        timeoutKind: "none",
      )

    let before = planCommitCount(tmp)
    let changed = runArchitectAreas(tmp, fakeRunner)
    let after = planCommitCount(tmp)
    let files = planTreeFiles(tmp)

    check changed
    check callCount == 1
    check capturedRequest.ticketId == "architect-areas"
    check capturedRequest.model == "codex-fake-unit-test-model"
    check capturedRequest.reasoningEffort == "high"
    check tmp in capturedRequest.prompt
    check "AGENTS.md" in capturedRequest.prompt
    check "areas/01-arch.md" in files
    check after == before + 1

  test "runManagerTickets commits ticket files written by mocked manager runner":
    let tmp = getTempDir() / "scriptorium_test_v1_38_run_manager_tickets"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    writeSpecInPlan(tmp, "# Spec\n\nCreate tickets from areas.\n")
    addAreaToPlan(tmp, "01-core.md", "# Area 01\n\n## Scope\n- Core\n")
    var writtenCfg = defaultConfig()
    writtenCfg.reasoningEffort.coding = "low"
    writtenCfg.reasoningEffort.manager = "high"
    writeScriptoriumConfig(tmp, writtenCfg)

    var callCount = 0
    var capturedRequest = AgentRunRequest()
    var capturedPromptRepoPath = ""
    proc fakeRunner(request: AgentRunRequest): AgentRunResult =
      ## Write one ticket file directly into tickets/open/ for the target area.
      inc callCount
      capturedRequest = request
      let repoPathMarker = "Repository root path (read project source files from here):\n"
      let markerIndex = request.prompt.find(repoPathMarker)
      doAssert markerIndex >= 0
      let repoPathStart = markerIndex + repoPathMarker.len
      let repoPathEnd = request.prompt.find('\n', repoPathStart)
      doAssert repoPathEnd > repoPathStart
      capturedPromptRepoPath = request.prompt[repoPathStart..<repoPathEnd].strip()
      writeFile(
        request.workingDir / "tickets/open/0001-core-task.md",
        "# Ticket 1\n\n**Area:** 01-core\n",
      )
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "tickets written",
        timeoutKind: "none",
      )

    let before = planCommitCount(tmp)
    let changed = runManagerTickets(tmp, fakeRunner)
    let after = planCommitCount(tmp)
    let files = planTreeFiles(tmp)

    check changed
    check callCount == 1
    check capturedRequest.ticketId == "manager-01-core"
    check capturedRequest.model == "codex-fake-unit-test-model"
    check capturedRequest.reasoningEffort == "high"
    check capturedPromptRepoPath == tmp
    check "AGENTS.md" in capturedRequest.prompt
    check "Only edit files under tickets/open/ in this working directory." in capturedRequest.prompt
    check "tickets/open/0001-core-task.md" in files
    check after == before + 1

  test "runManagerTickets rejects writes outside tickets/open":
    let tmp = getTempDir() / "scriptorium_test_manager_write_guard"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    writeSpecInPlan(tmp, "# Spec\n\nCreate tickets from areas.\n")
    addAreaToPlan(tmp, "01-core.md", "# Area 01\n\n## Scope\n- Core\n")

    proc fakeRunner(request: AgentRunRequest): AgentRunResult =
      ## Write an out-of-scope plan file to trigger the manager write guard.
      writeFile(
        request.workingDir / "tickets/open/0001-core-task.md",
        "# Ticket 1\n\n**Area:** 01-core\n",
      )
      writeFile(request.workingDir / "areas/99-out-of-scope.md", "# Bad write\n")
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "tickets written",
        timeoutKind: "none",
      )

    let before = planCommitCount(tmp)
    expect ValueError:
      discard runManagerTickets(tmp, fakeRunner)
    let after = planCommitCount(tmp)
    let files = planTreeFiles(tmp)

    check after == before
    check "tickets/open/0001-core-task.md" notin files
    check "areas/99-out-of-scope.md" notin files

  test "runManagerTickets rejects repository root mutations":
    let tmp = getTempDir() / "scriptorium_test_manager_repo_guard"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    writeSpecInPlan(tmp, "# Spec\n\nCreate tickets from areas.\n")
    addAreaToPlan(tmp, "01-core.md", "# Area 01\n\n## Scope\n- Core\n")

    proc fakeRunner(request: AgentRunRequest): AgentRunResult =
      ## Write one repo-root file to trigger the manager repo mutation guard.
      writeFile(
        request.workingDir / "tickets/open/0001-core-task.md",
        "# Ticket 1\n\n**Area:** 01-core\n",
      )
      writeFile(tmp / "manager-out-of-scope.txt", "bad write\n")
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "tickets written",
        timeoutKind: "none",
      )

    let before = planCommitCount(tmp)
    expect ValueError:
      discard runManagerTickets(tmp, fakeRunner)
    let after = planCommitCount(tmp)
    let files = planTreeFiles(tmp)

    check after == before
    check "tickets/open/0001-core-task.md" notin files
    check fileExists(tmp / "manager-out-of-scope.txt")

  test "runOrchestratorForTicks drives spec to done in one bounded tick with mocked runners":
    let tmp = getTempDir() / "scriptorium_test_v1_39_full_cycle_tick"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)
    addPassingMakefile(tmp)
    writeSpecInPlan(tmp, "# Spec\n\nDeliver one full-flow ticket.\n")
    writeOrchestratorEndpointConfig(tmp, 22)

    var callOrder: seq[string] = @[]
    proc fakeRunner(request: AgentRunRequest): AgentRunResult =
      ## Emulate architect, manager, and coding agent by ticketId role markers.
      callOrder.add(request.ticketId)
      case request.ticketId
      of "architect-areas":
        writeFile(
          request.workingDir / "areas/01-full-flow.md",
          "# Area 01\n\n## Goal\n- Full flow.\n",
        )
        result = AgentRunResult(
          backend: harnessCodex,
          exitCode: 0,
          attempt: 1,
          attemptCount: 1,
          lastMessage: "areas done",
          timeoutKind: "none",
        )
      of "manager-01-full-flow":
        writeFile(
          request.workingDir / "tickets/open/0001-full-flow.md",
          "# Ticket 1\n\n**Area:** 01-full-flow\n",
        )
        result = AgentRunResult(
          backend: harnessCodex,
          exitCode: 0,
          attempt: 1,
          attemptCount: 1,
          lastMessage: "tickets done",
          timeoutKind: "none",
        )
      of "0001":
        writeFile(request.workingDir / "flow-output.txt", "done\n")
        runCmdOrDie("git -C " & quoteShell(request.workingDir) & " add flow-output.txt")
        runCmdOrDie("git -C " & quoteShell(request.workingDir) & " commit -m test-v1-39-flow-output")
        result = AgentRunResult(
          backend: harnessCodex,
          exitCode: 0,
          attempt: 1,
          attemptCount: 1,
          lastMessage: "Done.\nsubmit_pr(\"ship flow\")",
          timeoutKind: "none",
        )
      else:
        raise newException(ValueError, "unexpected runner ticket id: " & request.ticketId)

    runOrchestratorForTicks(tmp, 1, fakeRunner)

    let files = planTreeFiles(tmp)
    check callOrder == @["architect-areas", "manager-01-full-flow", "0001"]
    check "areas/01-full-flow.md" in files
    check "tickets/done/0001-full-flow.md" in files
    check "tickets/open/0001-full-flow.md" notin files
    check "tickets/in-progress/0001-full-flow.md" notin files
    check "queue/merge/pending/0001-0001.md" notin files

    let (masterFile, masterRc) = execCmdEx("git -C " & quoteShell(tmp) & " show master:flow-output.txt")
    check masterRc == 0
    check masterFile.strip() == "done"

    validateTicketStateInvariant(tmp)
    validateTransitionCommitInvariant(tmp)

suite "interactive planning":
  test "prompt assembly includes spec, history, and user message":
    let repoPath = "/tmp/repo"
    let spec = "# Spec\n\n- feature A\n"
    let history = @[
      PlanTurn(role: "engineer", text: "add feature B"),
      PlanTurn(role: "architect", text: "Added feature B to spec."),
    ]
    let userMsg = "add feature C"

    let prompt = buildInteractivePlanPrompt(repoPath, spec, history, userMsg)

    check repoPath in prompt
    check spec.strip() in prompt
    check "add feature B" in prompt
    check "Added feature B to spec." in prompt
    check "add feature C" in prompt
    check "AGENTS.md" in prompt
    check "Only edit spec.md in this working directory." in prompt
    check "If the engineer is discussing or asking questions, reply directly and do not edit spec.md." in prompt
    check "Only edit spec.md when the engineer asks to change plan content." in prompt

  test "turn commits when spec changes":
    let tmp = getTempDir() / "scriptorium_test_interactive_commit"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)

    var callCount = 0
    var capturedWorkingDir = ""
    var capturedPrompt = ""
    proc fakeRunner(req: AgentRunRequest): AgentRunResult =
      ## Write new content to spec.md and return a deterministic result.
      inc callCount
      capturedWorkingDir = req.workingDir
      capturedPrompt = req.prompt
      check req.heartbeatIntervalMs > 0
      check not req.onEvent.isNil
      req.onEvent(AgentStreamEvent(kind: agentEventReasoning, text: "reading spec", rawLine: ""))
      req.onEvent(AgentStreamEvent(kind: agentEventTool, text: "read_file (started)", rawLine: ""))
      writeFile(req.workingDir / "spec.md", "# Updated Spec\n\n- new item\n")
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "Updated spec.",
        timeoutKind: "none",
      )

    var msgIdx = 0
    proc fakeInput(): string =
      ## Yield one message then raise EOFError.
      if msgIdx >= 1:
        raise newException(EOFError, "done")
      inc msgIdx
      result = "hello"

    runInteractivePlanSession(tmp, fakeRunner, fakeInput, quiet = true)

    let (logOutput, logRc) = execCmdEx(
      "git -C " & quoteShell(tmp) & " log --oneline scriptorium/plan"
    )
    check logRc == 0
    check "plan session turn 1" in logOutput
    check callCount == 1
    check capturedWorkingDir != tmp
    check tmp in capturedPrompt
    check "AGENTS.md" in capturedPrompt

  test "turn makes no commit when spec unchanged":
    let tmp = getTempDir() / "scriptorium_test_interactive_no_commit"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)

    proc fakeRunner(req: AgentRunRequest): AgentRunResult =
      ## Return a result without modifying spec.md.
      discard req
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "No changes needed.",
        timeoutKind: "none",
      )

    var msgIdx = 0
    proc fakeInput(): string =
      ## Yield one message then raise EOFError.
      if msgIdx >= 1:
        raise newException(EOFError, "done")
      inc msgIdx
      result = "hello"

    let before = planCommitCount(tmp)
    runInteractivePlanSession(tmp, fakeRunner, fakeInput, quiet = true)
    let after = planCommitCount(tmp)

    check after == before

  test "/show, /help, /quit do not invoke runner":
    let tmp = getTempDir() / "scriptorium_test_interactive_commands"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)

    var callCount = 0
    proc fakeRunner(req: AgentRunRequest): AgentRunResult =
      ## Count invocations; should never be called for slash commands.
      inc callCount
      discard req
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "",
        timeoutKind: "none",
      )

    let cmds = @["/show", "/help", "/quit"]
    var cmdIdx = 0
    proc fakeInput(): string =
      ## Yield slash commands in sequence, then EOF.
      if cmdIdx >= cmds.len:
        raise newException(EOFError, "done")
      result = cmds[cmdIdx]
      inc cmdIdx

    runInteractivePlanSession(tmp, fakeRunner, fakeInput, quiet = true)

    check callCount == 0

  test "turn rejects writes outside spec.md":
    let tmp = getTempDir() / "scriptorium_test_interactive_out_of_scope"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)

    proc fakeRunner(req: AgentRunRequest): AgentRunResult =
      ## Write one out-of-scope file in the plan worktree.
      writeFile(req.workingDir / "spec.md", "# Updated Spec\n")
      writeFile(req.workingDir / "areas/02-out-of-scope.md", "# Nope\n")
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "done",
        timeoutKind: "none",
      )

    var msgIdx = 0
    proc fakeInput(): string =
      ## Yield one message then raise EOFError.
      if msgIdx >= 1:
        raise newException(EOFError, "done")
      inc msgIdx
      result = "hello"

    let before = planCommitCount(tmp)
    expect ValueError:
      runInteractivePlanSession(tmp, fakeRunner, fakeInput, quiet = true)
    let after = planCommitCount(tmp)
    let files = planTreeFiles(tmp)

    check after == before
    check "areas/02-out-of-scope.md" notin files

  test "interrupt-style input exits session cleanly":
    let tmp = getTempDir() / "scriptorium_test_interactive_interrupt"
    makeTestRepo(tmp)
    defer: removeDir(tmp)
    runInit(tmp, quiet = true)

    var runnerCalls = 0
    proc fakeRunner(req: AgentRunRequest): AgentRunResult =
      ## Track runner invocations; interrupted input should stop before agent calls.
      inc runnerCalls
      discard req
      result = AgentRunResult(
        backend: harnessCodex,
        exitCode: 0,
        attempt: 1,
        attemptCount: 1,
        lastMessage: "",
        timeoutKind: "none",
      )

    var inputCalls = 0
    proc fakeInput(): string =
      ## Simulate interrupted terminal input.
      inc inputCalls
      raise newException(IOError, "interrupted by signal")

    let before = planCommitCount(tmp)
    runInteractivePlanSession(tmp, fakeRunner, fakeInput, quiet = true)
    let after = planCommitCount(tmp)

    check inputCalls == 1
    check runnerCalls == 0
    check after == before

suite "orchestrator agent enqueue with fakes":
  test "agent run enqueues exactly one merge request with metadata":
    withTempRepo("scriptorium_test_enqueue_metadata_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addPassingMakefile(repoPath)
      addTicketToPlan(repoPath, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

      let assignment = assignOldestOpenTicket(repoPath)
      proc fakeRunner(request: AgentRunRequest): AgentRunResult =
        ## Return a deterministic run output that requests submit_pr.
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
          lastMessage: "Done.\nsubmit_pr(\"ship it\")",
          timeoutKind: "none",
        )

      discard executeAssignedTicket(repoPath, assignment, fakeRunner)

      let queueFiles = pendingQueueFiles(repoPath)
      check queueFiles.len == 1
      check queueFiles[0] == "queue/merge/pending/0001-0001.md"

      let queueEntry = readPlanFile(repoPath, queueFiles[0])
      check "**Ticket:** tickets/in-progress/0001-first.md" in queueEntry
      check "**Ticket ID:** 0001" in queueEntry
      check "**Summary:** ship it" in queueEntry
      check "**Branch:** scriptorium/ticket-0001" in queueEntry
      check ("**Worktree:** " & assignment.worktree) in queueEntry
    )

  test "orchestrator tick assigns and executes before merge queue processing":
    withTempRepo("scriptorium_test_tick_assign_execute_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addPassingMakefile(repoPath)
      writeSpecInPlan(repoPath, "# Spec\n\nDrive orchestrator tick.\n")
      addTicketToPlan(repoPath, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")
      addTicketToPlan(repoPath, "open", "0002-second.md", "# Ticket 2\n\n**Area:** b\n")

      let firstAssignment = assignOldestOpenTicket(repoPath)
      discard enqueueMergeRequest(repoPath, firstAssignment, "first summary")

      let fakeBinDir = createTempDir("scriptorium_test_fake_codex_", "", getTempDir())
      defer:
        removeDir(fakeBinDir)
      let fakeCodexPath = fakeBinDir / "codex"
      let fakeScript = "#!/usr/bin/env bash\n" &
        "set -euo pipefail\n" &
        "last_message=\"\"\n" &
        "while [[ $# -gt 0 ]]; do\n" &
        "  case \"$1\" in\n" &
        "    --output-last-message) last_message=\"$2\"; shift 2 ;;\n" &
        "    *) shift ;;\n" &
        "  esac\n" &
        "done\n" &
        "cat >/dev/null\n" &
        "printf '{\"type\":\"message\",\"text\":\"ok\"}\\n'\n" &
        "printf 'done\\n' > \"$last_message\"\n"
      writeFile(fakeCodexPath, fakeScript)
      setFilePermissions(fakeCodexPath, {fpUserRead, fpUserWrite, fpUserExec})

      let oldPath = getEnv("PATH", "")
      putEnv("PATH", fakeBinDir & ":" & oldPath)
      defer:
        putEnv("PATH", oldPath)

      writeOrchestratorEndpointConfig(repoPath, 0)
      runOrchestratorForTicks(repoPath, 1)

      let files = planTreeFiles(repoPath)
      check "tickets/done/0001-first.md" in files
      check "tickets/in-progress/0002-second.md" in files
      check pendingQueueFiles(repoPath).len == 0

      let commits = latestPlanCommits(repoPath, 3)
      check commits.len == 3
      check commits[0] == "scriptorium: complete ticket 0001"
      check commits[1] == "scriptorium: record agent run 0002-second"
      check commits[2] == "scriptorium: assign ticket 0002-second"
    )

  test "end-to-end happy path from spec to done":
    withTempRepo("scriptorium_test_e2e_happy_path_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addPassingMakefile(repoPath)

      var architectCalls = 0
      var managerCalls = 0
      proc architectGenerator(model: string, spec: string): seq[AreaDocument] =
        ## Return one deterministic area document from spec input.
        inc architectCalls
        check model == "codex-fake-unit-test-model"
        check "Run `scriptorium plan`" in spec
        result = @[
          AreaDocument(
            path: "01-e2e.md",
            content: "# Area 01\n\n## Goal\n- Validate V1 happy path.\n",
          )
        ]

      let syncedAreas = syncAreasFromSpec(repoPath, architectGenerator)
      check syncedAreas
      check architectCalls == 1

      proc managerGenerator(model: string, areaPath: string, areaContent: string): seq[TicketDocument] =
        ## Return one deterministic ticket for the generated area.
        inc managerCalls
        check model == "codex-fake-unit-test-model"
        check areaPath == "areas/01-e2e.md"
        check "Validate V1 happy path." in areaContent
        result = @[
          TicketDocument(
            slug: "e2e-happy-path",
            content: "# Ticket 1\n\nImplement end-to-end flow.\n",
          )
        ]

      let syncedTickets = syncTicketsFromAreas(repoPath, managerGenerator)
      check syncedTickets
      check managerCalls == 1

      let filesAfterPlanning = planTreeFiles(repoPath)
      check "areas/01-e2e.md" in filesAfterPlanning
      check "tickets/open/0001-e2e-happy-path.md" in filesAfterPlanning

      let assignment = assignOldestOpenTicket(repoPath)
      check assignment.inProgressTicket == "tickets/in-progress/0001-e2e-happy-path.md"
      writeFile(assignment.worktree / "e2e-output.txt", "done\n")
      runCmdOrDie("git -C " & quoteShell(assignment.worktree) & " add e2e-output.txt")
      runCmdOrDie("git -C " & quoteShell(assignment.worktree) & " commit -m test-e2e-ticket-output")
      let (ticketHead, ticketHeadRc) = execCmdEx("git -C " & quoteShell(assignment.worktree) & " rev-parse HEAD")
      doAssert ticketHeadRc == 0

      proc fakeRunner(request: AgentRunRequest): AgentRunResult =
        ## Return a deterministic successful output that requests merge submission.
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
          lastMessage: "Done.\nsubmit_pr(\"ship e2e\")",
          timeoutKind: "none",
        )

      discard executeAssignedTicket(repoPath, assignment, fakeRunner)
      let pending = pendingQueueFiles(repoPath)
      check pending.len == 1
      check pending[0] == "queue/merge/pending/0001-0001.md"

      let processed = processMergeQueue(repoPath)
      check processed
      check pendingQueueFiles(repoPath).len == 0

      let finalFiles = planTreeFiles(repoPath)
      check "tickets/done/0001-e2e-happy-path.md" in finalFiles
      check "tickets/open/0001-e2e-happy-path.md" notin finalFiles
      check "tickets/in-progress/0001-e2e-happy-path.md" notin finalFiles

      let (masterOutput, masterRc) = execCmdEx("git -C " & quoteShell(repoPath) & " show master:e2e-output.txt")
      check masterRc == 0
      check masterOutput.strip() == "done"

      let (_, ancestorRc) = execCmdEx(
        "git -C " & quoteShell(repoPath) & " merge-base --is-ancestor " & ticketHead.strip() & " master"
      )
      check ancestorRc == 0

      validateTicketStateInvariant(repoPath)
      validateTransitionCommitInvariant(repoPath)
    )

  test "one-shot plan runner reads repo path context and commits spec only":
    withTempRepo("scriptorium_test_oneshot_plan_runner_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      writeFile(repoPath / "source-marker.txt", "integration-marker\n")
      runCmdOrDie("git -C " & quoteShell(repoPath) & " add source-marker.txt")
      runCmdOrDie("git -C " & quoteShell(repoPath) & " commit -m test-add-source-marker")

      var callCount = 0
      var capturedPrompt = ""
      var capturedRepoPath = ""
      proc fakeRunner(request: AgentRunRequest): AgentRunResult =
        ## Read the repo path from prompt context and update spec.md in plan worktree.
        inc callCount
        capturedPrompt = request.prompt
        let repoPathMarker = "Repository root path (read project source files from here):\n"
        let markerIndex = request.prompt.find(repoPathMarker)
        doAssert markerIndex >= 0
        let pathStart = markerIndex + repoPathMarker.len
        let pathEnd = request.prompt.find('\n', pathStart)
        doAssert pathEnd > pathStart
        let repoPathFromPrompt = request.prompt[pathStart..<pathEnd].strip()
        capturedRepoPath = repoPathFromPrompt
        let marker = readFile(repoPathFromPrompt / "source-marker.txt").strip()
        writeFile(request.workingDir / "spec.md", "# Integration Spec\n\n- marker: " & marker & "\n")

        result = AgentRunResult(
          backend: harnessCodex,
          command: @["codex", "exec"],
          exitCode: 0,
          attempt: 1,
          attemptCount: 1,
          stdout: "",
          logFile: request.workingDir / ".scriptorium/logs/plan-spec/attempt-01.jsonl",
          lastMessageFile: request.workingDir / ".scriptorium/logs/plan-spec/attempt-01.last_message.txt",
          lastMessage: "Updated spec",
          timeoutKind: "none",
        )

      let changed = updateSpecFromArchitect(repoPath, "sync source marker", fakeRunner)

      check changed
      check callCount == 1
      check capturedRepoPath == repoPath
      check "AGENTS.md" in capturedPrompt
      check "Only edit spec.md in this working directory." in capturedPrompt

      let specBody = readPlanFile(repoPath, "spec.md")
      check "# Integration Spec" in specBody
      check "- marker: integration-marker" in specBody

      let files = planTreeFiles(repoPath)
      check "spec.md" in files
      check "areas/01-out-of-scope.md" notin files

      let commits = latestPlanCommits(repoPath, 1)
      check commits.len == 1
      check commits[0] == "scriptorium: update spec from architect"
    )

suite "logging":
  test "initLog creates directory and file":
    let tmpDir = createTempDir("scriptorium_log_test_", "")
    defer: removeDir(tmpDir)
    let fakeRepo = tmpDir / "myproject"
    createDir(fakeRepo)
    initLog(fakeRepo)
    defer: closeLog()
    check logFilePath.len > 0
    check fileExists(logFilePath)
    check "/tmp/scriptorium/myproject/" in logFilePath
    check "run_" in logFilePath

  test "logInfo writes timestamped line to file":
    let tmpDir = createTempDir("scriptorium_log_test_", "")
    defer: removeDir(tmpDir)
    let fakeRepo = tmpDir / "testproj"
    createDir(fakeRepo)
    initLog(fakeRepo)
    logInfo("hello from test")
    closeLog()
    let content = readFile(logFilePath)
    check "[INFO]" in content
    check "hello from test" in content

  test "log levels write correct labels":
    let tmpDir = createTempDir("scriptorium_log_test_", "")
    defer: removeDir(tmpDir)
    let fakeRepo = tmpDir / "leveltest"
    createDir(fakeRepo)
    initLog(fakeRepo)
    logDebug("dbg msg")
    logWarn("wrn msg")
    logError("err msg")
    closeLog()
    let content = readFile(logFilePath)
    check "[DEBUG] dbg msg" in content
    check "[WARN] wrn msg" in content
    check "[ERROR] err msg" in content

  test "log without initLog does not crash":
    closeLog()
    logInfo("should just echo, not crash")
