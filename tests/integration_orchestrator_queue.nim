## Integration tests for orchestrator merge-queue flows on local fixture repositories.

import
  std/[algorithm, os, osproc, sequtils, strformat, strutils, tempfiles, unittest],
  scriptorium/[agent_runner, config, init, orchestrator]

const
  OrchestratorBasePort = 18000

proc runCmdOrDie(cmd: string) =
  ## Run a shell command and fail immediately when it exits non-zero.
  let (output, rc) = execCmdEx(cmd)
  doAssert rc == 0, cmd & "\n" & output

proc makeTestRepo(path: string) =
  ## Create a minimal git repository at path suitable for integration tests.
  if dirExists(path):
    removeDir(path)
  createDir(path)
  runCmdOrDie("git -C " & quoteShell(path) & " init")
  runCmdOrDie("git -C " & quoteShell(path) & " config user.email test@test.com")
  runCmdOrDie("git -C " & quoteShell(path) & " config user.name Test")
  runCmdOrDie("git -C " & quoteShell(path) & " commit --allow-empty -m initial")

proc withTempRepo(prefix: string, action: proc(repoPath: string)) =
  ## Create a temporary git repository, run action, and clean up afterwards.
  let repoPath = createTempDir(prefix, "", getTempDir())
  defer:
    removeDir(repoPath)
  makeTestRepo(repoPath)
  action(repoPath)

proc withPlanWorktree(repoPath: string, suffix: string, action: proc(planPath: string)) =
  ## Open scriptorium/plan in a temporary worktree for direct fixture mutations.
  let planPath = createTempDir("scriptorium_integration_plan_" & suffix & "_", "", getTempDir())
  removeDir(planPath)
  defer:
    if dirExists(planPath):
      removeDir(planPath)

  runCmdOrDie("git -C " & quoteShell(repoPath) & " worktree add " & quoteShell(planPath) & " scriptorium/plan")
  defer:
    discard execCmdEx("git -C " & quoteShell(repoPath) & " worktree remove --force " & quoteShell(planPath))

  action(planPath)

proc addTicketToPlan(repoPath: string, state: string, fileName: string, content: string) =
  ## Add one ticket markdown file to a state directory and commit it.
  withPlanWorktree(repoPath, "add_ticket", proc(planPath: string) =
    let relPath = "tickets" / state / fileName
    writeFile(planPath / relPath, content)
    runCmdOrDie("git -C " & quoteShell(planPath) & " add " & quoteShell(relPath))
    runCmdOrDie("git -C " & quoteShell(planPath) & " commit -m integration-add-ticket")
  )

proc addPassingMakefile(repoPath: string) =
  ## Add a passing make target for queue-processing tests.
  writeFile(repoPath / "Makefile", "test:\n\t@echo PASS\n")
  runCmdOrDie("git -C " & quoteShell(repoPath) & " add Makefile")
  runCmdOrDie("git -C " & quoteShell(repoPath) & " commit -m integration-add-passing-makefile")

proc addFailingMakefile(repoPath: string) =
  ## Add a failing make target for queue-processing tests.
  writeFile(repoPath / "Makefile", "test:\n\t@echo FAIL\n\t@false\n")
  runCmdOrDie("git -C " & quoteShell(repoPath) & " add Makefile")
  runCmdOrDie("git -C " & quoteShell(repoPath) & " commit -m integration-add-failing-makefile")

proc planTreeFiles(repoPath: string): seq[string] =
  ## Return tracked file paths from the plan branch tree.
  let (output, rc) = execCmdEx("git -C " & quoteShell(repoPath) & " ls-tree -r --name-only scriptorium/plan")
  doAssert rc == 0
  result = output.splitLines().filterIt(it.len > 0)

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

proc moveTicketStateInPlan(repoPath: string, fromRelPath: string, toRelPath: string, commitMessage: string) =
  ## Move one ticket between plan state directories and commit the fixture mutation.
  withPlanWorktree(repoPath, "move_ticket_state", proc(planPath: string) =
    moveFile(planPath / fromRelPath, planPath / toRelPath)
    runCmdOrDie("git -C " & quoteShell(planPath) & " add -A tickets")
    runCmdOrDie("git -C " & quoteShell(planPath) & " commit -m " & quoteShell(commitMessage))
  )

proc writeActiveQueueInPlan(repoPath: string, activeValue: string, commitMessage: string) =
  ## Write queue/merge/active.md and commit it on the plan branch.
  withPlanWorktree(repoPath, "write_active_queue", proc(planPath: string) =
    writeFile(planPath / "queue/merge/active.md", activeValue)
    runCmdOrDie("git -C " & quoteShell(planPath) & " add queue/merge/active.md")
    runCmdOrDie("git -C " & quoteShell(planPath) & " commit -m " & quoteShell(commitMessage))
  )

proc writeSpecInPlan(repoPath: string, content: string, commitMessage: string) =
  ## Replace spec.md on the plan branch and commit fixture content.
  withPlanWorktree(repoPath, "write_spec", proc(planPath: string) =
    writeFile(planPath / "spec.md", content)
    runCmdOrDie("git -C " & quoteShell(planPath) & " add spec.md")
    runCmdOrDie("git -C " & quoteShell(planPath) & " commit -m " & quoteShell(commitMessage))
  )

proc writeOrchestratorEndpointConfig(repoPath: string, portOffset: int) =
  ## Write a unique local orchestrator endpoint configuration for test isolation.
  let basePort = OrchestratorBasePort + (getCurrentProcessId().int mod 1000)
  let orchestratorPort = basePort + portOffset
  writeFile(
    repoPath / "scriptorium.json",
    fmt"""{{"endpoints":{{"local":"http://127.0.0.1:{orchestratorPort}"}}}}""",
  )

suite "integration orchestrator merge queue":
  test "IT-01 agent run enqueues exactly one merge request with metadata":
    withTempRepo("scriptorium_integration_it01_", proc(repoPath: string) =
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

  test "IT-02 queue success moves ticket to done and merges ticket commit to master":
    withTempRepo("scriptorium_integration_it02_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addPassingMakefile(repoPath)
      addTicketToPlan(repoPath, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

      let assignment = assignOldestOpenTicket(repoPath)
      writeFile(assignment.worktree / "ticket-output.txt", "done\n")
      runCmdOrDie("git -C " & quoteShell(assignment.worktree) & " add ticket-output.txt")
      runCmdOrDie("git -C " & quoteShell(assignment.worktree) & " commit -m integration-ticket-output")
      let (ticketHead, ticketHeadRc) = execCmdEx("git -C " & quoteShell(assignment.worktree) & " rev-parse HEAD")
      doAssert ticketHeadRc == 0

      discard enqueueMergeRequest(repoPath, assignment, "merge me")

      let processed = processMergeQueue(repoPath)
      check processed
      check pendingQueueFiles(repoPath).len == 0

      let files = planTreeFiles(repoPath)
      check "tickets/done/0001-first.md" in files
      check "tickets/in-progress/0001-first.md" notin files

      let (masterFile, masterFileRc) = execCmdEx("git -C " & quoteShell(repoPath) & " show master:ticket-output.txt")
      check masterFileRc == 0
      check masterFile.strip() == "done"

      let (_, ancestorRc) = execCmdEx(
        "git -C " & quoteShell(repoPath) & " merge-base --is-ancestor " & ticketHead.strip() & " master"
      )
      check ancestorRc == 0
    )

  test "IT-03 queue failure reopens ticket and appends failure note":
    withTempRepo("scriptorium_integration_it03_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addFailingMakefile(repoPath)
      addTicketToPlan(repoPath, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

      let assignment = assignOldestOpenTicket(repoPath)
      discard enqueueMergeRequest(repoPath, assignment, "expected failure")

      let processed = processMergeQueue(repoPath)
      check processed
      check pendingQueueFiles(repoPath).len == 0

      let files = planTreeFiles(repoPath)
      check "tickets/open/0001-first.md" in files
      check "tickets/in-progress/0001-first.md" notin files

      let ticketContent = readPlanFile(repoPath, "tickets/open/0001-first.md")
      check "## Merge Queue Failure" in ticketContent
      check "- Summary: expected failure" in ticketContent
      check "FAIL" in ticketContent
    )

  test "IT-04 single-flight queue processing keeps second item pending":
    withTempRepo("scriptorium_integration_it04_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addPassingMakefile(repoPath)
      addTicketToPlan(repoPath, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")
      addTicketToPlan(repoPath, "open", "0002-second.md", "# Ticket 2\n\n**Area:** b\n")

      let firstAssignment = assignOldestOpenTicket(repoPath)
      let secondAssignment = assignOldestOpenTicket(repoPath)
      discard enqueueMergeRequest(repoPath, firstAssignment, "first summary")
      discard enqueueMergeRequest(repoPath, secondAssignment, "second summary")

      let processed = processMergeQueue(repoPath)
      check processed

      let files = planTreeFiles(repoPath)
      check "tickets/done/0001-first.md" in files
      check "tickets/in-progress/0002-second.md" in files

      let queueFiles = pendingQueueFiles(repoPath)
      check queueFiles.len == 1
      check queueFiles[0] == "queue/merge/pending/0002-0002.md"
    )

  test "IT-05 merge conflict during merge master into ticket reopens ticket":
    withTempRepo("scriptorium_integration_it05_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addPassingMakefile(repoPath)

      writeFile(repoPath / "conflict.txt", "line=base\n")
      runCmdOrDie("git -C " & quoteShell(repoPath) & " add conflict.txt")
      runCmdOrDie("git -C " & quoteShell(repoPath) & " commit -m integration-add-conflict-base")

      addTicketToPlan(repoPath, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")
      let assignment = assignOldestOpenTicket(repoPath)

      writeFile(assignment.worktree / "conflict.txt", "line=ticket\n")
      runCmdOrDie("git -C " & quoteShell(assignment.worktree) & " add conflict.txt")
      runCmdOrDie("git -C " & quoteShell(assignment.worktree) & " commit -m integration-ticket-conflict-change")

      writeFile(repoPath / "conflict.txt", "line=master\n")
      runCmdOrDie("git -C " & quoteShell(repoPath) & " add conflict.txt")
      runCmdOrDie("git -C " & quoteShell(repoPath) & " commit -m integration-master-conflict-change")

      discard enqueueMergeRequest(repoPath, assignment, "conflict expected")

      let processed = processMergeQueue(repoPath)
      check processed
      check pendingQueueFiles(repoPath).len == 0

      let files = planTreeFiles(repoPath)
      check "tickets/open/0001-first.md" in files
      check "tickets/in-progress/0001-first.md" notin files

      let ticketContent = readPlanFile(repoPath, "tickets/open/0001-first.md")
      check "## Merge Queue Failure" in ticketContent
      check "- Summary: conflict expected" in ticketContent
      check "CONFLICT" in ticketContent
    )

  test "IT-06 orchestrator tick assigns and executes before merge queue processing":
    withTempRepo("scriptorium_integration_it06_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addPassingMakefile(repoPath)
      writeSpecInPlan(repoPath, "# Spec\n\nDrive orchestrator tick.\n", "integration-write-spec")
      addTicketToPlan(repoPath, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")
      addTicketToPlan(repoPath, "open", "0002-second.md", "# Ticket 2\n\n**Area:** b\n")

      let firstAssignment = assignOldestOpenTicket(repoPath)
      discard enqueueMergeRequest(repoPath, firstAssignment, "first summary")

      let fakeBinDir = createTempDir("scriptorium_integration_fake_codex_", "", getTempDir())
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

  test "IT-08 recovery after partial queue transition converges without duplicate moves":
    withTempRepo("scriptorium_integration_it08_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addPassingMakefile(repoPath)
      addTicketToPlan(repoPath, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

      let assignment = assignOldestOpenTicket(repoPath)
      discard enqueueMergeRequest(repoPath, assignment, "recover me")
      moveTicketStateInPlan(
        repoPath,
        assignment.inProgressTicket,
        "tickets/done/0001-first.md",
        "integration-partial-done-transition",
      )
      writeActiveQueueInPlan(
        repoPath,
        "queue/merge/pending/0001-0001.md\n",
        "integration-partial-active-state",
      )

      let firstProcessed = processMergeQueue(repoPath)
      let secondProcessed = processMergeQueue(repoPath)
      check firstProcessed
      check not secondProcessed

      let files = planTreeFiles(repoPath)
      check "tickets/done/0001-first.md" in files
      check "tickets/open/0001-first.md" notin files
      check "tickets/in-progress/0001-first.md" notin files
      check pendingQueueFiles(repoPath).len == 0

      let activeFile = readPlanFile(repoPath, "queue/merge/active.md")
      check activeFile.strip().len == 0
    )

  test "IT-09 red master blocks assignment of open tickets":
    withTempRepo("scriptorium_integration_it09_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addFailingMakefile(repoPath)
      writeSpecInPlan(repoPath, "# Spec\n\nNeed assignment.\n", "integration-write-spec")
      addTicketToPlan(repoPath, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")
      writeOrchestratorEndpointConfig(repoPath, 1)

      runOrchestratorForTicks(repoPath, 1)

      let files = planTreeFiles(repoPath)
      check "tickets/open/0001-first.md" in files
      check "tickets/in-progress/0001-first.md" notin files
    )

  test "IT-10 global halt while red resumes after master health is restored":
    withTempRepo("scriptorium_integration_it10_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addPassingMakefile(repoPath)
      writeSpecInPlan(repoPath, "# Spec\n\nNeed queue processing.\n", "integration-write-spec")
      addTicketToPlan(repoPath, "open", "0001-first.md", "# Ticket 1\n\n**Area:** a\n")

      let assignment = assignOldestOpenTicket(repoPath)
      writeFile(assignment.worktree / "ticket-output.txt", "done\n")
      runCmdOrDie("git -C " & quoteShell(assignment.worktree) & " add ticket-output.txt")
      runCmdOrDie("git -C " & quoteShell(assignment.worktree) & " commit -m integration-ticket-output")
      discard enqueueMergeRequest(repoPath, assignment, "merge me")

      addFailingMakefile(repoPath)
      writeOrchestratorEndpointConfig(repoPath, 2)
      runOrchestratorForTicks(repoPath, 1)

      var files = planTreeFiles(repoPath)
      check "tickets/in-progress/0001-first.md" in files
      check "tickets/done/0001-first.md" notin files
      check pendingQueueFiles(repoPath).len == 1

      addPassingMakefile(repoPath)
      runOrchestratorForTicks(repoPath, 1)

      files = planTreeFiles(repoPath)
      check "tickets/done/0001-first.md" in files
      check "tickets/in-progress/0001-first.md" notin files
      check pendingQueueFiles(repoPath).len == 0
    )

  test "IT-11 end-to-end happy path from spec to done":
    withTempRepo("scriptorium_integration_it11_", proc(repoPath: string) =
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
      runCmdOrDie("git -C " & quoteShell(assignment.worktree) & " commit -m integration-it11-ticket-output")
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

  test "IT-12 one-shot plan runner reads repo path context and commits spec only":
    withTempRepo("scriptorium_integration_it12_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      writeFile(repoPath / "source-marker.txt", "integration-marker\n")
      runCmdOrDie("git -C " & quoteShell(repoPath) & " add source-marker.txt")
      runCmdOrDie("git -C " & quoteShell(repoPath) & " commit -m integration-add-source-marker")

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
