## Integration tests for live orchestrator daemon submit_pr flows.

import
  std/[algorithm, os, osproc, posix, sequtils, strformat, strutils, tempfiles, times, unittest],
  jsony,
  scriptorium/[config, init]

const
  CliBinaryName = "scriptorium_integration_live_orchestrator"
  DefaultIntegrationModel = "gpt-5.1-codex-mini"
  CodexAuthPathEnv = "CODEX_AUTH_FILE"
  OrchestratorLiveBasePort = 23000
  PollIntervalMs = 500
  PositiveTimeoutMs = 300_000
  NegativeTimeoutMs = 120_000
  ShutdownTimeoutMs = 15_000
  LogTailChars = 4000

let
  ProjectRoot = getCurrentDir()
var
  cliBinaryPath = ""

proc integrationModel(): string =
  ## Return the configured integration model, or the default model.
  result = getEnv("CODEX_INTEGRATION_MODEL", DefaultIntegrationModel)

proc codexAuthPath(): string =
  ## Return the configured Codex auth file path used for OAuth credentials.
  let overridePath = getEnv(CodexAuthPathEnv, "").strip()
  if overridePath.len > 0:
    result = overridePath
  else:
    result = expandTilde("~/.codex/auth.json")

proc hasCodexAuth(): bool =
  ## Return true when API keys or a Codex OAuth auth file are available.
  let hasApiKey = getEnv("OPENAI_API_KEY", "").len > 0 or getEnv("CODEX_API_KEY", "").len > 0
  result = hasApiKey or fileExists(codexAuthPath())

proc runCmdOrDie(cmd: string) =
  ## Run one shell command and fail the test immediately when it exits non-zero.
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
  ## Create one temporary git repository, run action, and clean up afterwards.
  let repoPath = createTempDir(prefix, "", getTempDir())
  defer:
    removeDir(repoPath)
  makeTestRepo(repoPath)
  action(repoPath)

proc withPlanWorktree(repoPath: string, suffix: string, action: proc(planPath: string)) =
  ## Open scriptorium/plan in a temporary worktree for direct fixture mutations.
  let planPath = createTempDir("scriptorium_integration_live_plan_" & suffix & "_", "", getTempDir())
  removeDir(planPath)
  defer:
    if dirExists(planPath):
      removeDir(planPath)

  runCmdOrDie("git -C " & quoteShell(repoPath) & " worktree add " & quoteShell(planPath) & " scriptorium/plan")
  defer:
    discard execCmdEx("git -C " & quoteShell(repoPath) & " worktree remove --force " & quoteShell(planPath))

  action(planPath)

proc writeSpecInPlan(repoPath: string, content: string, commitMessage: string) =
  ## Replace spec.md on the plan branch and commit fixture content.
  withPlanWorktree(repoPath, "write_spec", proc(planPath: string) =
    writeFile(planPath / "spec.md", content)
    runCmdOrDie("git -C " & quoteShell(planPath) & " add spec.md")
    runCmdOrDie("git -C " & quoteShell(planPath) & " commit -m " & quoteShell(commitMessage))
  )

proc addAreaToPlan(repoPath: string, fileName: string, content: string, commitMessage: string) =
  ## Add one area markdown file to the plan branch and commit it.
  withPlanWorktree(repoPath, "add_area", proc(planPath: string) =
    let relPath = "areas/" & fileName
    writeFile(planPath / relPath, content)
    runCmdOrDie("git -C " & quoteShell(planPath) & " add " & quoteShell(relPath))
    runCmdOrDie("git -C " & quoteShell(planPath) & " commit -m " & quoteShell(commitMessage))
  )

proc addTicketToPlan(repoPath: string, fileName: string, content: string, commitMessage: string) =
  ## Add one open ticket markdown file to the plan branch and commit it.
  withPlanWorktree(repoPath, "add_ticket", proc(planPath: string) =
    let relPath = "tickets/open/" & fileName
    writeFile(planPath / relPath, content)
    runCmdOrDie("git -C " & quoteShell(planPath) & " add " & quoteShell(relPath))
    runCmdOrDie("git -C " & quoteShell(planPath) & " commit -m " & quoteShell(commitMessage))
  )

proc addPassingMakefile(repoPath: string) =
  ## Add passing quality-gate targets for live orchestrator tests.
  writeFile(
    repoPath / "Makefile",
    "test:\n\t@echo PASS test\n\nintegration-test:\n\t@echo PASS integration-test\n",
  )
  runCmdOrDie("git -C " & quoteShell(repoPath) & " add Makefile")
  runCmdOrDie("git -C " & quoteShell(repoPath) & " commit -m integration-live-add-passing-makefile")

proc writeScriptoriumConfig(repoPath: string, cfg: Config) =
  ## Write one typed scriptorium.json payload for integration configuration.
  writeFile(repoPath / "scriptorium.json", cfg.toJson())

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

proc ensureCliBinary(): string =
  ## Build and cache the scriptorium CLI binary for live daemon tests.
  if cliBinaryPath.len == 0:
    cliBinaryPath = getTempDir() / CliBinaryName
    runCmdOrDie(
      "nim c -o:" & quoteShell(cliBinaryPath) & " " & quoteShell(ProjectRoot / "src/scriptorium.nim")
    )
  result = cliBinaryPath

proc orchestratorPort(offset: int): int =
  ## Return a deterministic local orchestrator port for one test offset.
  result = OrchestratorLiveBasePort + (getCurrentProcessId().int mod 1000) + offset

proc latestOrchestratorLogPath(repoPath: string): string =
  ## Return the latest orchestrator log file path for one test repository.
  let logDir = "/tmp/scriptorium" / lastPathPart(repoPath)
  if dirExists(logDir):
    for filePath in walkDirRec(logDir):
      if filePath.toLowerAscii().endsWith(".log"):
        result.add(filePath & "\n")

  if result.len > 0:
    let paths = result.splitLines().filterIt(it.len > 0).sorted()
    result = paths[^1]
  else:
    result = ""

proc truncateTail(value: string, maxChars: int): string =
  ## Return at most maxChars from the end of value.
  if maxChars < 1:
    result = ""
  elif value.len <= maxChars:
    result = value
  else:
    result = value[(value.len - maxChars)..^1]

proc orchestratorLogTail(repoPath: string): string =
  ## Return a short tail preview from the latest orchestrator log.
  let logPath = latestOrchestratorLogPath(repoPath)
  if logPath.len > 0 and fileExists(logPath):
    result = truncateTail(readFile(logPath), LogTailChars)
  else:
    result = "<no orchestrator log found>"

proc waitForCondition(timeoutMs: int, pollMs: int, condition: proc(): bool): bool =
  ## Poll condition until true or timeout.
  let startedAt = epochTime()
  var elapsedMs = 0.0
  while elapsedMs < timeoutMs.float:
    if condition():
      result = true
      break
    sleep(pollMs)
    elapsedMs = (epochTime() - startedAt) * 1000.0

proc stopProcessWithSigint(process: Process) =
  ## Send SIGINT to one process, wait briefly, then close process handles.
  if process.peekExitCode() == -1:
    let pid = processID(process)
    discard posix.kill(Pid(pid), SIGINT)
    discard process.waitForExit(ShutdownTimeoutMs)
  process.close()

suite "integration orchestrator live submit_pr":
  test "IT-LIVE-03 real daemon path completes ticket via live submit_pr":
    doAssert findExe("codex").len > 0, "codex binary is required for live orchestrator integration"
    doAssert hasCodexAuth(),
      "OPENAI_API_KEY/CODEX_API_KEY or a Codex OAuth auth file is required for live orchestrator integration (" &
      codexAuthPath() & ")"

    withTempRepo("scriptorium_integration_live_it03_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addPassingMakefile(repoPath)

      let
        port = orchestratorPort(1)
        endpoint = &"http://127.0.0.1:{port}"
        timestamp = now().utc().format("yyyyMMddHHmmss")
        summaryNonce = &"it-live-03-{getCurrentProcessId()}-{timestamp}"
        ticketFile = "0001-live-submit-pr.md"
        openTicketPath = "tickets/open/" & ticketFile
        inProgressTicketPath = "tickets/in-progress/" & ticketFile
        doneTicketPath = "tickets/done/" & ticketFile
        ticketContent =
          "# Ticket 1\n\n" &
          "## Goal\n" &
          "Use the `submit_pr` function exactly once with summary `" & summaryNonce & "`.\n\n" &
          "## Requirements\n" &
          "- Do not edit repository files.\n" &
          "- Do not run shell commands to call submit_pr. Use the function from your tool list.\n" &
          "- After calling the function, reply with a short done message.\n\n" &
          "**Area:** 01-live\n"

      writeSpecInPlan(repoPath, "# Spec\n\nLive submit_pr runtime integration.\n", "integration-live-write-spec")
      addAreaToPlan(
        repoPath,
        "01-live.md",
        "# Area 01\n\n## Goal\n- Keep one live ticket for coding execution.\n",
        "integration-live-add-area",
      )
      addTicketToPlan(repoPath, ticketFile, ticketContent, "integration-live-add-ticket")

      var cfg = defaultConfig()
      cfg.models.architect = integrationModel()
      cfg.models.manager = integrationModel()
      cfg.models.coding = integrationModel()
      cfg.endpoints.local = endpoint
      writeScriptoriumConfig(repoPath, cfg)

      let process = startProcess(
        ensureCliBinary(),
        workingDir = repoPath,
        args = @["run"],
        options = {poUsePath, poParentStreams},
      )
      defer:
        stopProcessWithSigint(process)

      let completed = waitForCondition(PositiveTimeoutMs, PollIntervalMs, proc(): bool =
        let files = planTreeFiles(repoPath)
        doneTicketPath in files and
        openTicketPath notin files and
        inProgressTicketPath notin files and
        pendingQueueFiles(repoPath).len == 0
      )
      doAssert completed,
        "orchestrator did not reach done state for live submit_pr flow.\n" &
        "Plan files:\n" & planTreeFiles(repoPath).join("\n") & "\n\n" &
        "Log tail:\n" & orchestratorLogTail(repoPath)

      let doneContent = readPlanFile(repoPath, doneTicketPath)
      check "## Merge Queue Success" in doneContent
      check ("- Summary: " & summaryNonce) in doneContent

    )

  test "IT-LIVE-04 live daemon does not enqueue when submit_pr is missing":
    doAssert findExe("codex").len > 0, "codex binary is required for live orchestrator integration"
    doAssert hasCodexAuth(),
      "OPENAI_API_KEY/CODEX_API_KEY or a Codex OAuth auth file is required for live orchestrator integration (" &
      codexAuthPath() & ")"

    withTempRepo("scriptorium_integration_live_it04_", proc(repoPath: string) =
      runInit(repoPath, quiet = true)
      addPassingMakefile(repoPath)

      let
        port = orchestratorPort(2)
        endpoint = &"http://127.0.0.1:{port}"
        ticketFile = "0001-live-missing-submit-pr.md"
        openTicketPath = "tickets/open/" & ticketFile
        inProgressTicketPath = "tickets/in-progress/" & ticketFile
        doneTicketPath = "tickets/done/" & ticketFile
        ticketContent =
          "# Ticket 1\n\n" &
          "## Goal\n" &
          "Perform a no-op response.\n\n" &
          "**Area:** 01-live\n"

      writeSpecInPlan(repoPath, "# Spec\n\nLive missing-submit_pr integration.\n", "integration-live-write-spec")
      addAreaToPlan(
        repoPath,
        "01-live.md",
        "# Area 01\n\n## Goal\n- Keep one live ticket for coding execution.\n",
        "integration-live-add-area",
      )
      addTicketToPlan(repoPath, ticketFile, ticketContent, "integration-live-add-ticket")

      var cfg = defaultConfig()
      cfg.models.architect = integrationModel()
      cfg.models.manager = integrationModel()
      cfg.models.coding = "gpt-live-invalid-model-no-submit-pr"
      cfg.endpoints.local = endpoint
      writeScriptoriumConfig(repoPath, cfg)

      let process = startProcess(
        ensureCliBinary(),
        workingDir = repoPath,
        args = @["run"],
        options = {poUsePath, poParentStreams},
      )
      defer:
        stopProcessWithSigint(process)

      let runRecorded = waitForCondition(NegativeTimeoutMs, PollIntervalMs, proc(): bool =
        let files = planTreeFiles(repoPath)
        if inProgressTicketPath in files and openTicketPath notin files:
          let content = readPlanFile(repoPath, inProgressTicketPath)
          "## Agent Run" in content
        else:
          false
      )
      doAssert runRecorded,
        "orchestrator did not record a failed coding run for missing submit_pr scenario.\n" &
        "Plan files:\n" & planTreeFiles(repoPath).join("\n") & "\n\n" &
        "Log tail:\n" & orchestratorLogTail(repoPath)

      let files = planTreeFiles(repoPath)
      check doneTicketPath notin files
      check inProgressTicketPath in files
      check pendingQueueFiles(repoPath).len == 0

      let ticketContentAfterRun = readPlanFile(repoPath, inProgressTicketPath)
      check "## Agent Run" in ticketContentAfterRun
      check "- Exit Code: 0" notin ticketContentAfterRun
      check process.peekExitCode() == -1
    )
