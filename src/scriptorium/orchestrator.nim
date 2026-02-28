import
  std/[algorithm, os, osproc, posix, sets, streams, strformat, strutils, tables, tempfiles, uri],
  mcport,
  ./[agent_runner, config, prompt_catalog]

const
  PlanBranch = "scriptorium/plan"
  PlanAreasDir = "areas"
  PlanTicketsOpenDir = "tickets/open"
  PlanTicketsInProgressDir = "tickets/in-progress"
  PlanTicketsDoneDir = "tickets/done"
  PlanMergeQueueDir = "queue/merge"
  PlanMergeQueuePendingDir = "queue/merge/pending"
  PlanMergeQueueActivePath = "queue/merge/active.md"
  PlanSpecPath = "spec.md"
  PlanSpecPlaceholder = "# Spec\n\nRun `scriptorium plan` to build your spec with the Architect."
  AreaCommitMessage = "scriptorium: update areas from spec"
  TicketCommitMessage = "scriptorium: create tickets from areas"
  AreaFieldPrefix = "**Area:**"
  WorktreeFieldPrefix = "**Worktree:**"
  TicketAssignCommitPrefix = "scriptorium: assign ticket"
  TicketAgentRunCommitPrefix = "scriptorium: record agent run"
  MergeQueueInitCommitMessage = "scriptorium: initialize merge queue"
  MergeQueueEnqueueCommitPrefix = "scriptorium: enqueue merge request"
  MergeQueueDoneCommitPrefix = "scriptorium: complete ticket"
  MergeQueueReopenCommitPrefix = "scriptorium: reopen ticket"
  MergeQueueCleanupCommitPrefix = "scriptorium: cleanup merge queue"
  PlanSpecCommitMessage = "scriptorium: update spec from architect"
  PlanSpecTicketId = "plan-spec"
  PlanSessionTicketId = "plan-session"
  PlanTempWorktreePrefix = "scriptorium_plan_"
  ManagedWorktreeRoot = ".scriptorium/worktrees"
  PlanLogRoot = "scriptorium-plan-logs"
  PlanWriteScopeName = "scriptorium plan"
  TicketBranchPrefix = "scriptorium/ticket-"
  DefaultLocalEndpoint* = "http://127.0.0.1:8097"
  DefaultAgentAttempt = 1
  PlanDefaultMaxAttempts = 1
  PlanNoOutputTimeoutMs = 120_000
  PlanHardTimeoutMs = 300_000
  PlanHeartbeatIntervalMs = 3000
  PlanStreamPreviewChars = 140
  DefaultAgentMaxAttempts = 2
  AgentMessagePreviewChars = 1200
  AgentStdoutPreviewChars = 1200
  MergeQueueOutputPreviewChars = 2000
  MasterHealthCheckTarget = "test"
  IdleSleepMs = 200
  WaitingNoSpecMessage = "WAITING: no spec — run 'scriptorium plan'"
  ArchitectAreasTicketId = "architect-areas"
  ManagerTicketIdPrefix = "manager-"
  OrchestratorServerName = "scriptorium-orchestrator"
  OrchestratorServerVersion = "0.1.0"

type
  OrchestratorEndpoint* = object
    address*: string
    port*: int

  AreaDocument* = object
    path*: string
    content*: string

  ArchitectAreaGenerator* = proc(model: string, spec: string): seq[AreaDocument]

  TicketDocument* = object
    slug*: string
    content*: string

  ManagerTicketGenerator* = proc(model: string, areaPath: string, areaContent: string): seq[TicketDocument]

  PlanTurn* = object
    role*: string
    text*: string

  PlanSessionInput* = proc(): string
    ## Returns the next line of input. Raises EOFError to end the session.

  TicketAssignment* = object
    openTicket*: string
    inProgressTicket*: string
    branch*: string
    worktree*: string

  ActiveTicketWorktree* = object
    ticketPath*: string
    ticketId*: string
    branch*: string
    worktree*: string

  OrchestratorStatus* = object
    openTickets*: int
    inProgressTickets*: int
    doneTickets*: int
    activeTicketPath*: string
    activeTicketId*: string
    activeTicketBranch*: string
    activeTicketWorktree*: string

  MergeQueueItem* = object
    pendingPath*: string
    ticketPath*: string
    ticketId*: string
    branch*: string
    worktree*: string
    summary*: string

  ServerThreadArgs = tuple[
    httpServer: HttpMcpServer,
    address: string,
    port: int,
  ]

  MasterHealthState = object
    head*: string
    healthy*: bool
    initialized*: bool

var
  shouldRun {.volatile.} = true
  interactivePlanInterrupted {.volatile.} = false

proc gitRun(dir: string, args: varargs[string]) =
  ## Run a git subcommand in dir and raise an IOError on non-zero exit.
  let argsSeq = @args
  let allArgs = @["-C", dir] & argsSeq
  let process = startProcess("git", args = allArgs, options = {poUsePath, poStdErrToStdOut})
  let output = process.outputStream.readAll()
  let rc = process.waitForExit()
  process.close()
  if rc != 0:
    let argsStr = argsSeq.join(" ")
    raise newException(IOError, fmt"git {argsStr} failed: {output.strip()}")

proc gitCheck(dir: string, args: varargs[string]): int =
  ## Run a git subcommand in dir and return its exit code.
  let allArgs = @["-C", dir] & @args
  let process = startProcess("git", args = allArgs, options = {poUsePath, poStdErrToStdOut})
  discard process.outputStream.readAll()
  result = process.waitForExit()
  process.close()

proc parseWorktreeConflictPath(output: string): string =
  ## Extract a conflicting worktree path from git worktree add stderr output.
  let marker = "worktree at '"
  let markerPos = output.rfind(marker)
  if markerPos >= 0:
    let pathStart = markerPos + marker.len
    let pathEnd = output.find('\'', pathStart)
    if pathEnd > pathStart:
      result = output[pathStart..<pathEnd].strip()

proc isManagedPlanTempWorktreePath(path: string): bool =
  ## Return true when path is one of this tool's temporary plan worktrees.
  var tempRoot = absolutePath(getTempDir()).replace('\\', '/')
  if tempRoot.endsWith("/"):
    tempRoot.setLen(tempRoot.len - 1)

  let normalizedPath = absolutePath(path).replace('\\', '/')
  result = normalizedPath.startsWith(tempRoot & "/" & PlanTempWorktreePrefix)

proc recoverManagedPlanWorktreeConflict(repoPath: string, addOutput: string): bool =
  ## Remove a stale managed temp worktree conflict and prune stale worktree metadata.
  let conflictPath = parseWorktreeConflictPath(addOutput)
  if conflictPath.len == 0:
    result = false
  elif not isManagedPlanTempWorktreePath(conflictPath):
    result = false
  else:
    discard gitCheck(repoPath, "worktree", "remove", "--force", conflictPath)
    discard gitCheck(repoPath, "worktree", "prune")
    result = true

proc withPlanWorktree[T](repoPath: string, operation: proc(planPath: string): T): T =
  ## Open a temporary worktree for the plan branch, run operation, then remove it.
  if gitCheck(repoPath, "rev-parse", "--verify", PlanBranch) != 0:
    raise newException(ValueError, "scriptorium/plan branch does not exist")

  let planWorktree = createTempDir(PlanTempWorktreePrefix, "", getTempDir())
  removeDir(planWorktree)
  var recoveredConflict = false
  while true:
    let addProcess = startProcess(
      "git",
      args = @["-C", repoPath, "worktree", "add", planWorktree, PlanBranch],
      options = {poUsePath, poStdErrToStdOut},
    )
    let addOutput = addProcess.outputStream.readAll()
    let addRc = addProcess.waitForExit()
    addProcess.close()

    if addRc == 0:
      break

    if recoveredConflict or not recoverManagedPlanWorktreeConflict(repoPath, addOutput):
      raise newException(
        IOError,
        fmt"git worktree add {planWorktree} {PlanBranch} failed: {addOutput.strip()}",
      )
    recoveredConflict = true
    if dirExists(planWorktree):
      removeDir(planWorktree)

  defer:
    discard gitCheck(repoPath, "worktree", "remove", "--force", planWorktree)

  result = operation(planWorktree)

proc loadSpecFromPlanPath(planPath: string): string =
  ## Load spec.md from an existing plan branch worktree path.
  let specPath = planPath / PlanSpecPath
  if not fileExists(specPath):
    raise newException(ValueError, "spec.md does not exist in scriptorium/plan")
  result = readFile(specPath)

proc normalizeAreaPath(rawPath: string): string =
  ## Validate and normalize a relative area path.
  let clean = rawPath.strip()
  if clean.len == 0:
    raise newException(ValueError, "area path cannot be empty")
  if clean.startsWith("/") or clean.startsWith("\\"):
    raise newException(ValueError, fmt"area path must be relative: {clean}")
  if clean.startsWith("..") or clean.contains("/../") or clean.contains("\\..\\"):
    raise newException(ValueError, fmt"area path cannot escape areas directory: {clean}")
  if not clean.toLowerAscii().endsWith(".md"):
    raise newException(ValueError, fmt"area path must be a markdown file: {clean}")
  result = clean

proc normalizeTicketSlug(rawSlug: string): string =
  ## Validate and normalize a ticket slug for filename usage.
  let clean = rawSlug.strip().toLowerAscii()
  if clean.len == 0:
    raise newException(ValueError, "ticket slug cannot be empty")

  var slug = ""
  for ch in clean:
    if ch in {'a'..'z', '0'..'9'}:
      slug.add(ch)
    elif ch in {' ', '-', '_'}:
      if slug.len > 0 and slug[^1] != '-':
        slug.add('-')

  if slug.endsWith("-"):
    slug.setLen(slug.len - 1)
  if slug.len == 0:
    raise newException(ValueError, "ticket slug must contain alphanumeric characters")
  result = slug

proc areaIdFromAreaPath(areaRelPath: string): string =
  ## Derive the area identifier from an area file path.
  result = splitFile(areaRelPath).name

proc ticketIdFromTicketPath(ticketRelPath: string): string =
  ## Extract the numeric ticket identifier prefix from a ticket path.
  let fileName = splitFile(ticketRelPath).name
  let dashPos = fileName.find('-')
  if dashPos < 1:
    raise newException(ValueError, fmt"ticket filename has no numeric prefix: {fileName}")
  let id = fileName[0..<dashPos]
  if not id.allCharsInSet(Digits):
    raise newException(ValueError, fmt"ticket filename has non-numeric prefix: {fileName}")
  result = id

proc parseAreaFromTicketContent(ticketContent: string): string =
  ## Extract the area identifier from a ticket markdown body.
  for line in ticketContent.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith(AreaFieldPrefix):
      result = trimmed[AreaFieldPrefix.len..^1].strip()
      break

proc parseWorktreeFromTicketContent(ticketContent: string): string =
  ## Extract the worktree path from a ticket markdown body.
  for line in ticketContent.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith(WorktreeFieldPrefix):
      let value = trimmed[WorktreeFieldPrefix.len..^1].strip()
      if value.len > 0 and value != "—" and value != "-":
        result = value
      break

proc setTicketWorktree(ticketContent: string, worktreePath: string): string =
  ## Set or append the ticket worktree metadata field.
  var lines = ticketContent.strip().splitLines()
  var updated = false
  for i in 0..<lines.len:
    if lines[i].strip().startsWith(WorktreeFieldPrefix):
      lines[i] = WorktreeFieldPrefix & " " & worktreePath
      updated = true
      break
  if not updated:
    lines.add("")
    lines.add(WorktreeFieldPrefix & " " & worktreePath)
  result = lines.join("\n") & "\n"

proc truncateTail(value: string, maxChars: int): string =
  ## Return at most maxChars from the end of value.
  if maxChars < 1:
    result = ""
  elif value.len <= maxChars:
    result = value
  else:
    result = value[(value.len - maxChars)..^1]

proc clipPlanStreamText(value: string): string =
  ## Clip one stream message for concise interactive status rendering.
  let normalized = value.replace('\n', ' ').replace('\r', ' ').strip()
  if normalized.len <= PlanStreamPreviewChars:
    result = normalized
  elif PlanStreamPreviewChars > 3:
    result = normalized[0..<(PlanStreamPreviewChars - 3)] & "..."
  else:
    result = normalized

proc formatPlanStreamEvent(event: AgentStreamEvent): string =
  ## Format one agent stream event for interactive planning output.
  let text = clipPlanStreamText(event.text)
  case event.kind
  of agentEventHeartbeat:
    result = "[thinking] still working..."
  of agentEventReasoning:
    if text.len > 0:
      result = "[thinking] " & text
    else:
      result = "[thinking]"
  of agentEventTool:
    if text.len > 0:
      result = "[tool] " & text
    else:
      result = "[tool]"
  of agentEventStatus:
    if text.len > 0:
      result = "[status] " & text
    else:
      result = ""
  of agentEventMessage:
    result = ""

proc buildCodingAgentPrompt(ticketRelPath: string, ticketContent: string): string =
  ## Build the coding-agent prompt from ticket context.
  result = renderPromptTemplate(
    CodingAgentTemplate,
    [
      (name: "TICKET_PATH", value: ticketRelPath),
      (name: "TICKET_CONTENT", value: ticketContent.strip()),
    ],
  )

proc buildArchitectAreasPrompt(spec: string): string =
  ## Build the architect prompt that writes area files directly into areas/.
  result = renderPromptTemplate(
    ArchitectAreasTemplate,
    [
      (name: "CURRENT_SPEC", value: spec.strip()),
    ],
  )

proc buildManagerTicketsPrompt(areaRelPath: string, areaContent: string, nextId: int): string =
  ## Build the manager prompt that writes ticket files directly into tickets/open/.
  let areaId = areaIdFromAreaPath(areaRelPath)
  let nextIdText = &"{nextId:04d}"
  result = renderPromptTemplate(
    ManagerTicketsTemplate,
    [
      (name: "NEXT_ID", value: nextIdText),
      (name: "AREA_FIELD_PREFIX", value: AreaFieldPrefix),
      (name: "AREA_ID", value: areaId),
      (name: "AREA_PATH", value: areaRelPath),
      (name: "AREA_CONTENT", value: areaContent.strip()),
    ],
  )

proc formatAgentRunNote(model: string, runResult: AgentRunResult): string =
  ## Format a markdown note summarizing one coding-agent run.
  let messagePreview = truncateTail(runResult.lastMessage.strip(), AgentMessagePreviewChars)
  let stdoutPreview = truncateTail(runResult.stdout.strip(), AgentStdoutPreviewChars)
  result =
    "## Agent Run\n" &
    fmt"- Model: {model}\n" &
    fmt"- Backend: {runResult.backend}\n" &
    fmt"- Exit Code: {runResult.exitCode}\n" &
    fmt"- Attempt: {runResult.attempt}\n" &
    fmt"- Attempt Count: {runResult.attemptCount}\n" &
    fmt"- Timeout: {runResult.timeoutKind}\n" &
    fmt"- Log File: {runResult.logFile}\n" &
    fmt"- Last Message File: {runResult.lastMessageFile}\n"

  if messagePreview.len > 0:
    result &=
      "\n### Agent Last Message\n" &
      "```text\n" &
      messagePreview & "\n" &
      "```\n"

  if stdoutPreview.len > 0:
    result &=
      "\n### Agent Stdout Tail\n" &
      "```text\n" &
      stdoutPreview & "\n" &
      "```\n"

proc appendAgentRunNote(ticketContent: string, model: string, runResult: AgentRunResult): string =
  ## Append a formatted coding-agent run note to a ticket markdown document.
  let base = ticketContent.strip()
  let note = formatAgentRunNote(model, runResult).strip()
  result = base & "\n\n" & note & "\n"

proc branchNameForTicket(ticketRelPath: string): string

proc buildPlanScopePrompt(repoPath: string): string =
  ## Build shared planning prompt context with read and write scope.
  result = renderPromptTemplate(
    PlanScopeTemplate,
    [
      (name: "REPO_PATH", value: repoPath),
    ],
  )

proc buildArchitectPlanPrompt(repoPath: string, userPrompt: string, currentSpec: string): string =
  ## Build the one-shot architect prompt that edits spec.md in place.
  result = renderPromptTemplate(
    ArchitectPlanOneShotTemplate,
    [
      (name: "PLAN_SCOPE", value: buildPlanScopePrompt(repoPath).strip()),
      (name: "USER_REQUEST", value: userPrompt.strip()),
      (name: "CURRENT_SPEC", value: currentSpec.strip()),
    ],
  )

proc runPlanArchitectRequest(
  runner: AgentRunner,
  planPath: string,
  model: string,
  reasoningEffort: string,
  prompt: string,
  ticketId: string,
  onEvent: AgentEventHandler = nil,
  heartbeatIntervalMs: int = 0,
): AgentRunResult =
  ## Run one architect planning pass with shared harness settings.
  if runner.isNil:
    raise newException(ValueError, "agent runner is required")
  result = runner(AgentRunRequest(
    prompt: prompt,
    workingDir: planPath,
    model: model,
    reasoningEffort: reasoningEffort,
    ticketId: ticketId,
    attempt: DefaultAgentAttempt,
    skipGitRepoCheck: true,
    logRoot: getTempDir() / PlanLogRoot,
    noOutputTimeoutMs: PlanNoOutputTimeoutMs,
    hardTimeoutMs: PlanHardTimeoutMs,
    heartbeatIntervalMs: heartbeatIntervalMs,
    maxAttempts: PlanDefaultMaxAttempts,
    onEvent: onEvent,
  ))

proc listMarkdownFiles(basePath: string): seq[string]
proc runCommandCapture(workingDir: string, command: string, args: seq[string]): tuple[exitCode: int, output: string]

proc normalizeRelativeWritePath(rawPath: string): string =
  ## Validate and normalize one relative path for write guard checks.
  let clean = rawPath.strip().replace('\\', '/')
  if clean.len == 0:
    raise newException(ValueError, "write guard path cannot be empty")
  if clean.startsWith("/") or (clean.len >= 2 and clean[1] == ':'):
    raise newException(ValueError, fmt"write guard path must be relative: {clean}")

  var parts: seq[string] = @[]
  for part in clean.split('/'):
    if part.len == 0 or part == ".":
      continue
    if part == "..":
      raise newException(ValueError, fmt"write guard path cannot escape worktree: {clean}")
    parts.add(part)

  if parts.len == 0:
    raise newException(ValueError, fmt"write guard path is invalid: {clean}")
  result = parts.join("/")

proc collectGitPathOutput(planPath: string, args: seq[string]): seq[string] =
  ## Run one git command that emits relative paths and return non-empty lines.
  let commandResult = runCommandCapture(planPath, "git", args)
  if commandResult.exitCode != 0:
    let argsText = args.join(" ")
    raise newException(IOError, fmt"git {argsText} failed while checking write guards: {commandResult.output.strip()}")
  for line in commandResult.output.splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.add(trimmed)

proc listModifiedPathsInPlanPath(planPath: string): seq[string] =
  ## Return modified and untracked relative paths in the plan worktree.
  var seen = initHashSet[string]()
  let commands = @[
    @["diff", "--name-only", "--relative"],
    @["diff", "--cached", "--name-only", "--relative"],
    @["ls-files", "--others", "--exclude-standard"],
  ]

  for args in commands:
    for rawPath in collectGitPathOutput(planPath, args):
      let normalized = normalizeRelativeWritePath(rawPath)
      if not seen.contains(normalized):
        seen.incl(normalized)
        result.add(normalized)
  result.sort()

proc enforceWriteAllowlist(planPath: string, allowedPaths: openArray[string], scopeName: string) =
  ## Fail when modified paths are outside the provided relative-path allowlist.
  if allowedPaths.len == 0:
    raise newException(ValueError, "write allowlist cannot be empty")

  var allowedSet = initHashSet[string]()
  var allowedList: seq[string] = @[]
  for path in allowedPaths:
    let normalized = normalizeRelativeWritePath(path)
    if not allowedSet.contains(normalized):
      allowedSet.incl(normalized)
      allowedList.add(normalized)
  allowedList.sort()

  var disallowed: seq[string] = @[]
  for path in listModifiedPathsInPlanPath(planPath):
    if not allowedSet.contains(path):
      disallowed.add(path)

  if disallowed.len > 0:
    let disallowedText = disallowed.join(", ")
    let allowedText = allowedList.join(", ")
    raise newException(
      ValueError,
      fmt"{scopeName} modified out-of-scope files: {disallowedText}. Allowed files: {allowedText}.",
    )

proc ensureUniqueTicketStateInPlanPath(planPath: string) =
  ## Ensure each ticket markdown filename exists in exactly one state directory.
  var seen = initHashSet[string]()
  for stateDir in [PlanTicketsOpenDir, PlanTicketsInProgressDir, PlanTicketsDoneDir]:
    for ticketPath in listMarkdownFiles(planPath / stateDir):
      let fileName = extractFilename(ticketPath)
      if seen.contains(fileName):
        raise newException(ValueError, fmt"ticket exists in multiple state directories: {fileName}")
      seen.incl(fileName)

proc hasRunnableSpecInPlanPath(planPath: string): bool =
  ## Return true when spec.md exists and is not blank or the init placeholder.
  let specPath = planPath / PlanSpecPath
  if not fileExists(specPath):
    return false

  let specBody = readFile(specPath).strip()
  if specBody.len == 0:
    return false
  result = specBody != PlanSpecPlaceholder.strip()

proc ticketStateFromPath(path: string): string =
  ## Return ticket state directory name from one ticket markdown path.
  let normalized = path.replace('\\', '/')
  if normalized.startsWith(PlanTicketsOpenDir & "/"):
    result = PlanTicketsOpenDir
  elif normalized.startsWith(PlanTicketsInProgressDir & "/"):
    result = PlanTicketsInProgressDir
  elif normalized.startsWith(PlanTicketsDoneDir & "/"):
    result = PlanTicketsDoneDir

proc isOrchestratorTransitionSubject(subject: string): bool =
  ## Return true when one commit subject is an orchestrator ticket transition commit.
  result =
    subject.startsWith(TicketAssignCommitPrefix & " ") or
    subject.startsWith(MergeQueueDoneCommitPrefix & " ") or
    subject.startsWith(MergeQueueReopenCommitPrefix & " ")

proc transitionCountInCommit(repoPath: string, parentCommit: string, commitHash: string): int =
  ## Count ticket state transitions represented by one commit diff.
  let diffResult = runCommandCapture(
    repoPath,
    "git",
    @[
      "diff",
      "--name-status",
      "--find-renames",
      parentCommit,
      commitHash,
      "--",
      PlanTicketsOpenDir,
      PlanTicketsInProgressDir,
      PlanTicketsDoneDir,
    ],
  )
  if diffResult.exitCode != 0:
    raise newException(IOError, fmt"git diff failed while auditing transitions: {diffResult.output.strip()}")

  var removedByName = initTable[string, string]()
  var addedByName = initTable[string, string]()
  for line in diffResult.output.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    let columns = trimmed.split('\t')
    if columns.len < 2:
      continue

    let status = columns[0]
    if status.startsWith("R"):
      if columns.len < 3:
        continue
      let oldPath = columns[1]
      let newPath = columns[2]
      let oldState = ticketStateFromPath(oldPath)
      let newState = ticketStateFromPath(newPath)
      let oldName = extractFilename(oldPath)
      let newName = extractFilename(newPath)
      if oldState.len > 0 and newState.len > 0 and oldState != newState:
        if oldName != newName:
          raise newException(ValueError, fmt"invalid ticket rename across states in commit {commitHash}: {oldPath} -> {newPath}")
        inc result
    elif status == "D":
      let oldPath = columns[1]
      let oldState = ticketStateFromPath(oldPath)
      if oldState.len > 0:
        removedByName[extractFilename(oldPath)] = oldState
    elif status == "A":
      let newPath = columns[1]
      let newState = ticketStateFromPath(newPath)
      if newState.len > 0:
        addedByName[extractFilename(newPath)] = newState

  for ticketName, oldState in removedByName.pairs():
    if addedByName.hasKey(ticketName):
      let newState = addedByName[ticketName]
      if oldState != newState:
        inc result

proc runCommandCapture(workingDir: string, command: string, args: seq[string]): tuple[exitCode: int, output: string] =
  ## Run a process and return combined stdout/stderr with its exit code.
  let process = startProcess(
    command,
    workingDir = workingDir,
    args = args,
    options = {poUsePath, poStdErrToStdOut},
  )
  let output = process.outputStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  result = (exitCode: exitCode, output: output)

proc withMasterWorktree[T](repoPath: string, operation: proc(masterPath: string): T): T =
  ## Open a temporary worktree for the master branch, run operation, then remove it.
  if gitCheck(repoPath, "rev-parse", "--verify", "master") != 0:
    raise newException(ValueError, "master branch does not exist")

  let worktreeList = runCommandCapture(repoPath, "git", @["worktree", "list", "--porcelain"])
  if worktreeList.exitCode != 0:
    raise newException(IOError, fmt"git worktree list failed: {worktreeList.output.strip()}")

  var currentPath = ""
  for line in worktreeList.output.splitLines():
    if line.startsWith("worktree "):
      currentPath = line["worktree ".len..^1].strip()
    elif line == "branch refs/heads/master" and currentPath.len > 0:
      return operation(currentPath)

  let masterWorktree = createTempDir("scriptorium_master_", "", getTempDir())
  removeDir(masterWorktree)
  gitRun(repoPath, "worktree", "add", masterWorktree, "master")
  defer:
    discard gitCheck(repoPath, "worktree", "remove", "--force", masterWorktree)

  result = operation(masterWorktree)

proc extractSubmitPrSummary*(text: string): string =
  ## Extract submit_pr(summary) text from agent output when present.
  let marker = "submit_pr("
  let startIndex = text.find(marker)
  if startIndex < 0:
    return ""

  let valueStart = startIndex + marker.len
  let closeIndex = text.find(')', valueStart)
  if closeIndex < 0:
    return ""

  var raw = text[valueStart..<closeIndex].strip()
  if raw.startsWith("summary="):
    raw = raw["summary=".len..^1].strip()
  if raw.len >= 2 and ((raw[0] == '"' and raw[^1] == '"') or (raw[0] == '\'' and raw[^1] == '\'')):
    raw = raw[1..^2]
  result = raw.strip()

proc queueFilePrefixNumber(fileName: string): int =
  ## Parse the numeric prefix from a merge queue file name.
  let base = splitFile(fileName).name
  let dashPos = base.find('-')
  if dashPos < 1:
    return 0
  let prefix = base[0..<dashPos]
  if not prefix.allCharsInSet(Digits):
    return 0
  result = parseInt(prefix)

proc nextMergeQueueId(planPath: string): int =
  ## Compute the next monotonic merge queue identifier.
  result = 1
  for pendingPath in listMarkdownFiles(planPath / PlanMergeQueuePendingDir):
    let parsed = queueFilePrefixNumber(extractFilename(pendingPath))
    if parsed >= result:
      result = parsed + 1

proc ensureMergeQueueInitializedInPlanPath(planPath: string): bool =
  ## Ensure merge queue directories and files exist in the plan worktree.
  createDir(planPath / PlanMergeQueuePendingDir)
  let keepPath = planPath / PlanMergeQueuePendingDir / ".gitkeep"
  if not fileExists(keepPath):
    writeFile(keepPath, "")
    result = true

  let activePath = planPath / PlanMergeQueueActivePath
  if not fileExists(activePath):
    writeFile(activePath, "")
    result = true

proc queueItemToMarkdown(item: MergeQueueItem): string =
  ## Convert one merge queue item into markdown.
  result =
    "# Merge Queue Item\n\n" &
    "**Ticket:** " & item.ticketPath & "\n" &
    "**Ticket ID:** " & item.ticketId & "\n" &
    "**Branch:** " & item.branch & "\n" &
    "**Worktree:** " & item.worktree & "\n" &
    "**Summary:** " & item.summary & "\n"

proc parseQueueField(content: string, prefix: string): string =
  ## Parse one single-line markdown field from queue item content.
  for line in content.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith(prefix):
      result = trimmed[prefix.len..^1].strip()
      break

proc parseMergeQueueItem(pendingPath: string, content: string): MergeQueueItem =
  ## Parse one merge queue item from markdown.
  result = MergeQueueItem(
    pendingPath: pendingPath,
    ticketPath: parseQueueField(content, "**Ticket:**"),
    ticketId: parseQueueField(content, "**Ticket ID:**"),
    branch: parseQueueField(content, "**Branch:**"),
    worktree: parseQueueField(content, "**Worktree:**"),
    summary: parseQueueField(content, "**Summary:**"),
  )
  if result.ticketPath.len == 0 or result.ticketId.len == 0 or result.branch.len == 0 or result.worktree.len == 0:
    raise newException(ValueError, fmt"invalid merge queue item: {pendingPath}")

proc ticketPathInState(planPath: string, stateDir: string, item: MergeQueueItem): string =
  ## Return the expected ticket path for one ticket state directory.
  result = planPath / stateDir / extractFilename(item.ticketPath)

proc clearActiveQueueInPlanPath(planPath: string): bool =
  ## Clear queue/merge/active.md when it contains a pending item path.
  let activePath = planPath / PlanMergeQueueActivePath
  if fileExists(activePath) and readFile(activePath).strip().len > 0:
    writeFile(activePath, "")
    result = true

proc commitMergeQueueCleanup(planPath: string, ticketId: string) =
  ## Commit merge queue cleanup changes when tracked files were modified.
  gitRun(planPath, "add", "-A", PlanMergeQueueDir)
  if gitCheck(planPath, "diff", "--cached", "--quiet") != 0:
    let suffix = if ticketId.len > 0: " " & ticketId else: ""
    gitRun(planPath, "commit", "-m", MergeQueueCleanupCommitPrefix & suffix)

proc listMergeQueueItems(planPath: string): seq[MergeQueueItem] =
  ## Return merge queue items ordered by file name.
  let pendingRoot = planPath / PlanMergeQueuePendingDir
  if not dirExists(pendingRoot):
    return @[]

  var relPaths: seq[string] = @[]
  for absPath in listMarkdownFiles(pendingRoot):
    let fileName = extractFilename(absPath)
    if fileName == ".gitkeep":
      continue
    relPaths.add(relativePath(absPath, planPath).replace('\\', '/'))
  relPaths.sort()

  for relPath in relPaths:
    let content = readFile(planPath / relPath)
    result.add(parseMergeQueueItem(relPath, content))

proc listActiveTicketWorktreesInPlanPath(planPath: string): seq[ActiveTicketWorktree] =
  ## Return active in-progress ticket worktrees from a plan worktree path.
  for ticketPath in listMarkdownFiles(planPath / PlanTicketsInProgressDir):
    let relPath = relativePath(ticketPath, planPath).replace('\\', '/')
    let content = readFile(ticketPath)
    result.add(ActiveTicketWorktree(
      ticketPath: relPath,
      ticketId: ticketIdFromTicketPath(relPath),
      branch: branchNameForTicket(relPath),
      worktree: parseWorktreeFromTicketContent(content),
    ))
  result.sort(proc(a: ActiveTicketWorktree, b: ActiveTicketWorktree): int = cmp(a.ticketPath, b.ticketPath))

proc formatMergeFailureNote(summary: string, mergeOutput: string, testOutput: string): string =
  ## Format a ticket note for failed merge queue processing.
  let mergePreview = truncateTail(mergeOutput.strip(), MergeQueueOutputPreviewChars)
  let testPreview = truncateTail(testOutput.strip(), MergeQueueOutputPreviewChars)
  result =
    "## Merge Queue Failure\n" &
    fmt"- Summary: {summary}\n"
  if mergePreview.len > 0:
    result &=
      "\n### Merge Output\n" &
      "```text\n" &
      mergePreview & "\n" &
      "```\n"
  if testPreview.len > 0:
    result &=
      "\n### Test Output\n" &
      "```text\n" &
      testPreview & "\n" &
      "```\n"

proc formatMergeSuccessNote(summary: string, testOutput: string): string =
  ## Format a ticket note for successful merge queue processing.
  let testPreview = truncateTail(testOutput.strip(), MergeQueueOutputPreviewChars)
  result =
    "## Merge Queue Success\n" &
    fmt"- Summary: {summary}\n"
  if testPreview.len > 0:
    result &=
      "\n### Test Output\n" &
      "```text\n" &
      testPreview & "\n" &
      "```\n"

proc listMarkdownFiles(basePath: string): seq[string] =
  ## Collect markdown files recursively and return sorted absolute paths.
  if not dirExists(basePath):
    result = @[]
  else:
    for filePath in walkDirRec(basePath):
      if filePath.toLowerAscii().endsWith(".md"):
        result.add(filePath)
    result.sort()

proc collectActiveTicketAreas(planPath: string): HashSet[string] =
  ## Collect area identifiers that currently have open or in-progress tickets.
  result = initHashSet[string]()
  for stateDir in [PlanTicketsOpenDir, PlanTicketsInProgressDir]:
    for ticketPath in listMarkdownFiles(planPath / stateDir):
      let areaId = parseAreaFromTicketContent(readFile(ticketPath))
      if areaId.len > 0:
        result.incl(areaId)

proc areasNeedingTicketsInPlanPath(planPath: string): seq[string] =
  ## Return area files that currently have no open or in-progress tickets.
  let activeAreas = collectActiveTicketAreas(planPath)
  for areaPath in listMarkdownFiles(planPath / PlanAreasDir):
    let relativeAreaPath = relativePath(areaPath, planPath).replace('\\', '/')
    let areaId = areaIdFromAreaPath(relativeAreaPath)
    if not activeAreas.contains(areaId):
      result.add(relativeAreaPath)
  result.sort()

proc areasMissingInPlanPath(planPath: string): bool =
  ## Return true when no area markdown files exist under areas/.
  let areasPath = planPath / PlanAreasDir
  if not dirExists(areasPath):
    result = true
  else:
    var hasAreaFiles = false
    for filePath in walkDirRec(areasPath):
      if filePath.toLowerAscii().endsWith(".md"):
        hasAreaFiles = true
    result = not hasAreaFiles

proc nextTicketId(planPath: string): int =
  ## Compute the next monotonic ticket ID by scanning all ticket states.
  result = 1
  for stateDir in [PlanTicketsOpenDir, PlanTicketsInProgressDir, PlanTicketsDoneDir]:
    for ticketPath in listMarkdownFiles(planPath / stateDir):
      let ticketName = splitFile(ticketPath).name
      let dashPos = ticketName.find('-')
      if dashPos > 0:
        let prefix = ticketName[0..<dashPos]
        if prefix.allCharsInSet(Digits):
          let parsedId = parseInt(prefix)
          if parsedId >= result:
            result = parsedId + 1

proc oldestOpenTicketInPlanPath(planPath: string): string =
  ## Return the oldest open ticket path relative to planPath.
  var bestId = high(int)
  var bestRel = ""
  for ticketPath in listMarkdownFiles(planPath / PlanTicketsOpenDir):
    let rel = relativePath(ticketPath, planPath).replace('\\', '/')
    let parsedId = parseInt(ticketIdFromTicketPath(rel))
    if parsedId < bestId or (parsedId == bestId and rel < bestRel):
      bestId = parsedId
      bestRel = rel
  result = bestRel

proc branchNameForTicket(ticketRelPath: string): string =
  ## Build a deterministic branch name for a ticket.
  result = TicketBranchPrefix & ticketIdFromTicketPath(ticketRelPath)

proc worktreePathForTicket(repoPath: string, ticketRelPath: string): string =
  ## Build a deterministic absolute worktree path for a ticket.
  let ticketName = splitFile(ticketRelPath).name
  let root = repoPath / ManagedWorktreeRoot
  result = absolutePath(root / ticketName)

proc ensureWorktreeCreated(repoPath: string, ticketRelPath: string): tuple[branch: string, path: string] =
  ## Ensure the code worktree exists for the ticket and return branch/path.
  let branch = branchNameForTicket(ticketRelPath)
  let path = worktreePathForTicket(repoPath, ticketRelPath)
  createDir(parentDir(path))

  discard gitCheck(repoPath, "worktree", "remove", "--force", path)
  if dirExists(path):
    removeDir(path)

  if gitCheck(repoPath, "show-ref", "--verify", "--quiet", "refs/heads/" & branch) == 0:
    gitRun(repoPath, "worktree", "add", path, branch)
  else:
    gitRun(repoPath, "worktree", "add", "-b", branch, path)

  result = (branch: branch, path: path)

proc listGitWorktreePaths(repoPath: string): seq[string] =
  ## Return absolute worktree paths from git worktree list.
  let allArgs = @["-C", repoPath, "worktree", "list", "--porcelain"]
  let process = startProcess("git", args = allArgs, options = {poUsePath, poStdErrToStdOut})
  let output = process.outputStream.readAll()
  let rc = process.waitForExit()
  process.close()
  if rc != 0:
    raise newException(IOError, fmt"git worktree list failed: {output.strip()}")

  for line in output.splitLines():
    if line.startsWith("worktree "):
      result.add(line["worktree ".len..^1].strip())

proc writeAreasAndCommit(planPath: string, docs: seq[AreaDocument]): bool =
  ## Write generated area files and commit only when contents changed.
  var hasChanges = false
  for doc in docs:
    let relPath = normalizeAreaPath(doc.path)
    let target = planPath / PlanAreasDir / relPath
    createDir(parentDir(target))
    if fileExists(target):
      if readFile(target) != doc.content:
        writeFile(target, doc.content)
        hasChanges = true
    else:
      writeFile(target, doc.content)
      hasChanges = true

  if hasChanges:
    gitRun(planPath, "add", PlanAreasDir)
    if gitCheck(planPath, "diff", "--cached", "--quiet") != 0:
      gitRun(planPath, "commit", "-m", AreaCommitMessage)

  result = hasChanges

proc writeTicketsForArea(
  planPath: string,
  areaRelPath: string,
  docs: seq[TicketDocument],
  nextId: var int,
): bool =
  ## Write manager-generated tickets for one area into tickets/open.
  let areaId = areaIdFromAreaPath(areaRelPath)
  var hasChanges = false

  for doc in docs:
    let slug = normalizeTicketSlug(doc.slug)
    let ticketPath = planPath / PlanTicketsOpenDir / fmt"{nextId:04d}-{slug}.md"
    let body = doc.content.strip()
    if body.len == 0:
      raise newException(ValueError, "ticket content cannot be empty")

    let existingArea = parseAreaFromTicketContent(body)
    var ticketContent = body
    if existingArea.len == 0:
      ticketContent &= "\n\n" & AreaFieldPrefix & " " & areaId & "\n"
    elif existingArea != areaId:
      raise newException(ValueError, fmt"ticket area '{existingArea}' does not match area '{areaId}'")
    else:
      ticketContent &= "\n"

    writeFile(ticketPath, ticketContent)
    hasChanges = true
    inc nextId

  result = hasChanges

proc parsePort(rawPort: string, scheme: string): int =
  ## Parse the port value from a URI, falling back to scheme defaults.
  if rawPort.len > 0:
    result = parseInt(rawPort)
  elif scheme == "https":
    result = 443
  else:
    result = 80

  if result < 1 or result > 65535:
    raise newException(ValueError, fmt"invalid endpoint port: {result}")

proc parseEndpoint*(endpointUrl: string): OrchestratorEndpoint =
  ## Parse the orchestrator HTTP endpoint from a URL.
  let clean = endpointUrl.strip()
  let resolved = if clean.len > 0: clean else: DefaultLocalEndpoint
  let parsed = parseUri(resolved)

  if parsed.scheme.len == 0:
    raise newException(ValueError, fmt"invalid endpoint URL (missing scheme): {resolved}")
  if parsed.hostname.len == 0:
    raise newException(ValueError, fmt"invalid endpoint URL (missing hostname): {resolved}")

  result = OrchestratorEndpoint(
    address: parsed.hostname,
    port: parsePort(parsed.port, parsed.scheme),
  )

proc loadOrchestratorEndpoint*(repoPath: string): OrchestratorEndpoint =
  ## Load and parse the orchestrator endpoint from repo configuration.
  let cfg = loadConfig(repoPath)
  result = parseEndpoint(cfg.endpoints.local)

proc loadSpecFromPlan*(repoPath: string): string =
  ## Load spec.md by opening the scriptorium/plan branch in a temporary worktree.
  result = withPlanWorktree(repoPath, proc(planPath: string): string =
    loadSpecFromPlanPath(planPath)
  )

proc areasMissing*(repoPath: string): bool =
  ## Return true when the plan branch has no area markdown files.
  result = withPlanWorktree(repoPath, proc(planPath: string): bool =
    areasMissingInPlanPath(planPath)
  )

proc areasNeedingTickets*(repoPath: string): seq[string] =
  ## Return area files that are eligible for manager ticket generation.
  result = withPlanWorktree(repoPath, proc(planPath: string): seq[string] =
    areasNeedingTicketsInPlanPath(planPath)
  )

proc oldestOpenTicket*(repoPath: string): string =
  ## Return the oldest open ticket path in the plan branch.
  result = withPlanWorktree(repoPath, proc(planPath: string): string =
    oldestOpenTicketInPlanPath(planPath)
  )

proc validateTicketStateInvariant*(repoPath: string) =
  ## Validate that no ticket markdown filename exists in more than one state directory.
  discard withPlanWorktree(repoPath, proc(planPath: string): int =
    ensureUniqueTicketStateInPlanPath(planPath)
    0
  )

proc validateTransitionCommitInvariant*(repoPath: string) =
  ## Validate that each ticket state transition is exactly one orchestrator transition commit.
  let logResult = runCommandCapture(
    repoPath,
    "git",
    @["log", "--reverse", "--format=%H%x1f%P%x1f%s", PlanBranch],
  )
  if logResult.exitCode != 0:
    raise newException(IOError, fmt"git log failed while auditing transitions: {logResult.output.strip()}")

  for line in logResult.output.splitLines():
    if line.strip().len == 0:
      continue
    let columns = line.split('\x1f')
    if columns.len < 3:
      raise newException(ValueError, fmt"invalid git log row while auditing transitions: {line}")

    let commitHash = columns[0].strip()
    let parentValue = columns[1].strip()
    let subject = columns[2].strip()
    let isTransitionSubject = isOrchestratorTransitionSubject(subject)

    if parentValue.len == 0:
      if isTransitionSubject:
        raise newException(ValueError, fmt"transition commit cannot be root commit: {subject}")
      continue

    let parentCommit = parentValue.splitWhitespace()[0]
    let transitionCount = transitionCountInCommit(repoPath, parentCommit, commitHash)
    if transitionCount > 0 and not isTransitionSubject:
      raise newException(ValueError, fmt"ticket state transition must use orchestrator transition commit: {subject}")
    if isTransitionSubject and transitionCount != 1:
      raise newException(
        ValueError,
        fmt"orchestrator transition commit must contain exactly one ticket transition: {subject} (found {transitionCount})",
      )

proc hasRunnableSpec*(repoPath: string): bool =
  ## Return true when spec.md is present and contains actionable content.
  result = withPlanWorktree(repoPath, proc(planPath: string): bool =
    hasRunnableSpecInPlanPath(planPath)
  )

proc listActiveTicketWorktrees*(repoPath: string): seq[ActiveTicketWorktree] =
  ## Return active in-progress ticket worktrees from the plan branch.
  result = withPlanWorktree(repoPath, proc(planPath: string): seq[ActiveTicketWorktree] =
    listActiveTicketWorktreesInPlanPath(planPath)
  )

proc readOrchestratorStatus*(repoPath: string): OrchestratorStatus =
  ## Return plan ticket counts and current active agent metadata.
  result = withPlanWorktree(repoPath, proc(planPath: string): OrchestratorStatus =
    result = OrchestratorStatus(
      openTickets: listMarkdownFiles(planPath / PlanTicketsOpenDir).len,
      inProgressTickets: listMarkdownFiles(planPath / PlanTicketsInProgressDir).len,
      doneTickets: listMarkdownFiles(planPath / PlanTicketsDoneDir).len,
    )

    let activeQueuePath = planPath / PlanMergeQueueActivePath
    if fileExists(activeQueuePath):
      let activeRelPath = readFile(activeQueuePath).strip()
      if activeRelPath.len > 0:
        let pendingPath = planPath / activeRelPath
        if fileExists(pendingPath):
          let item = parseMergeQueueItem(activeRelPath, readFile(pendingPath))
          result.activeTicketPath = item.ticketPath
          result.activeTicketId = item.ticketId
          result.activeTicketBranch = item.branch
          result.activeTicketWorktree = item.worktree

    if result.activeTicketId.len == 0:
      let activeWorktrees = listActiveTicketWorktreesInPlanPath(planPath)
      if activeWorktrees.len > 0:
        let active = activeWorktrees[0]
        result.activeTicketPath = active.ticketPath
        result.activeTicketId = active.ticketId
        result.activeTicketBranch = active.branch
        result.activeTicketWorktree = active.worktree
  )

proc syncAreasFromSpec*(repoPath: string, generateAreas: ArchitectAreaGenerator): bool =
  ## Generate and persist areas when plan/areas has no markdown files.
  if generateAreas.isNil:
    raise newException(ValueError, "architect area generator is required")

  let cfg = loadConfig(repoPath)
  result = withPlanWorktree(repoPath, proc(planPath: string): bool =
    let missing = areasMissingInPlanPath(planPath)
    if missing:
      let spec = loadSpecFromPlanPath(planPath)
      let docs = generateAreas(cfg.models.architect, spec)
      discard writeAreasAndCommit(planPath, docs)
      true
    else:
      false
  )

proc runArchitectAreas*(repoPath: string, runner: AgentRunner = runAgent): bool =
  ## Run one architect pass that writes area files directly in the plan worktree.
  if runner.isNil:
    raise newException(ValueError, "agent runner is required")

  let cfg = loadConfig(repoPath)
  result = withPlanWorktree(repoPath, proc(planPath: string): bool =
    if not hasRunnableSpecInPlanPath(planPath):
      false
    elif not areasMissingInPlanPath(planPath):
      false
    else:
      let spec = loadSpecFromPlanPath(planPath)
      discard runner(AgentRunRequest(
        prompt: buildArchitectAreasPrompt(spec),
        workingDir: planPath,
        model: cfg.models.architect,
        reasoningEffort: cfg.reasoningEffort.architect,
        ticketId: ArchitectAreasTicketId,
        attempt: DefaultAgentAttempt,
        skipGitRepoCheck: true,
        maxAttempts: DefaultAgentMaxAttempts,
      ))

      gitRun(planPath, "add", PlanAreasDir)
      if gitCheck(planPath, "diff", "--cached", "--quiet") != 0:
        gitRun(planPath, "commit", "-m", AreaCommitMessage)
        true
      else:
        false
  )

proc updateSpecFromArchitect*(
  repoPath: string,
  prompt: string,
  runner: AgentRunner,
): bool =
  ## Update spec.md from one architect run and commit when content changes.
  if runner.isNil:
    raise newException(ValueError, "agent runner is required")
  if prompt.strip().len == 0:
    raise newException(ValueError, "plan prompt is required")

  let cfg = loadConfig(repoPath)
  result = withPlanWorktree(repoPath, proc(planPath: string): bool =
    let existingSpec = loadSpecFromPlanPath(planPath)
    discard runPlanArchitectRequest(
      runner,
      planPath,
      cfg.models.architect,
      cfg.reasoningEffort.architect,
      buildArchitectPlanPrompt(repoPath, prompt, existingSpec),
      PlanSpecTicketId,
    )
    enforceWriteAllowlist(planPath, [PlanSpecPath], PlanWriteScopeName)

    let updatedSpec = loadSpecFromPlanPath(planPath)
    if updatedSpec == existingSpec:
      false
    else:
      gitRun(planPath, "add", PlanSpecPath)
      if gitCheck(planPath, "diff", "--cached", "--quiet") != 0:
        gitRun(planPath, "commit", "-m", PlanSpecCommitMessage)
      true
  )

proc updateSpecFromArchitect*(repoPath: string, prompt: string): bool =
  ## Update spec.md using the default architect model backend.
  result = updateSpecFromArchitect(repoPath, prompt, runAgent)

proc syncTicketsFromAreas*(repoPath: string, generateTickets: ManagerTicketGenerator): bool =
  ## Generate and persist tickets for areas without active work.
  if generateTickets.isNil:
    raise newException(ValueError, "manager ticket generator is required")

  let cfg = loadConfig(repoPath)
  result = withPlanWorktree(repoPath, proc(planPath: string): bool =
    let areasToProcess = areasNeedingTicketsInPlanPath(planPath)
    if areasToProcess.len == 0:
      false
    else:
      var nextId = nextTicketId(planPath)
      var hasChanges = false
      for areaRelPath in areasToProcess:
        let areaContent = readFile(planPath / areaRelPath)
        let docs = generateTickets(cfg.models.coding, areaRelPath, areaContent)
        if writeTicketsForArea(planPath, areaRelPath, docs, nextId):
          hasChanges = true

      if hasChanges:
        gitRun(planPath, "add", PlanTicketsOpenDir)
        if gitCheck(planPath, "diff", "--cached", "--quiet") != 0:
          gitRun(planPath, "commit", "-m", TicketCommitMessage)
      hasChanges
  )

proc runManagerTickets*(repoPath: string, runner: AgentRunner = runAgent): bool =
  ## Run manager passes that write ticket files directly in tickets/open/.
  if runner.isNil:
    raise newException(ValueError, "agent runner is required")

  let cfg = loadConfig(repoPath)
  result = withPlanWorktree(repoPath, proc(planPath: string): bool =
    if not hasRunnableSpecInPlanPath(planPath):
      false
    else:
      let areasToProcess = areasNeedingTicketsInPlanPath(planPath)
      if areasToProcess.len == 0:
        false
      else:
        for areaRelPath in areasToProcess:
          let areaContent = readFile(planPath / areaRelPath)
          let areaId = areaIdFromAreaPath(areaRelPath)
          let nextId = nextTicketId(planPath)
          discard runner(AgentRunRequest(
            prompt: buildManagerTicketsPrompt(areaRelPath, areaContent, nextId),
            workingDir: planPath,
            model: cfg.models.coding,
            reasoningEffort: cfg.reasoningEffort.coding,
            ticketId: ManagerTicketIdPrefix & areaId,
            attempt: DefaultAgentAttempt,
            skipGitRepoCheck: true,
            maxAttempts: DefaultAgentMaxAttempts,
          ))

        gitRun(planPath, "add", PlanTicketsOpenDir)
        if gitCheck(planPath, "diff", "--cached", "--quiet") != 0:
          gitRun(planPath, "commit", "-m", TicketCommitMessage)
          true
        else:
          false
  )

proc assignOldestOpenTicket*(repoPath: string): TicketAssignment =
  ## Move the oldest open ticket to in-progress and attach a code worktree.
  result = withPlanWorktree(repoPath, proc(planPath: string): TicketAssignment =
    let openTicket = oldestOpenTicketInPlanPath(planPath)
    if openTicket.len == 0:
      return TicketAssignment()

    let inProgressTicket = PlanTicketsInProgressDir / splitFile(openTicket).name & ".md"
    let openAbs = planPath / openTicket
    let inProgressAbs = planPath / inProgressTicket
    moveFile(openAbs, inProgressAbs)

    let worktreeInfo = ensureWorktreeCreated(repoPath, inProgressTicket)
    let content = readFile(inProgressAbs)
    writeFile(inProgressAbs, setTicketWorktree(content, worktreeInfo.path))

    gitRun(planPath, "add", "-A", PlanTicketsOpenDir, PlanTicketsInProgressDir)
    if gitCheck(planPath, "diff", "--cached", "--quiet") != 0:
      let ticketName = splitFile(inProgressTicket).name
      gitRun(planPath, "commit", "-m", TicketAssignCommitPrefix & " " & ticketName)

    result = TicketAssignment(
      openTicket: openTicket,
      inProgressTicket: inProgressTicket,
      branch: worktreeInfo.branch,
      worktree: worktreeInfo.path,
    )
  )

proc cleanupStaleTicketWorktrees*(repoPath: string): seq[string] =
  ## Remove managed code worktrees that no longer correspond to in-progress tickets.
  let managedRoot = absolutePath(repoPath / ManagedWorktreeRoot)
  let activeWorktrees = withPlanWorktree(repoPath, proc(planPath: string): HashSet[string] =
    result = initHashSet[string]()
    for ticketPath in listMarkdownFiles(planPath / PlanTicketsInProgressDir):
      let worktreePath = parseWorktreeFromTicketContent(readFile(ticketPath))
      if worktreePath.len > 0:
        result.incl(worktreePath)
  )

  for path in listGitWorktreePaths(repoPath):
    if path.startsWith(managedRoot) and not activeWorktrees.contains(path):
      discard gitCheck(repoPath, "worktree", "remove", "--force", path)
      if dirExists(path):
        removeDir(path)
      result.add(path)

proc ensureMergeQueueInitialized*(repoPath: string): bool =
  ## Ensure the merge queue structure exists on the plan branch.
  result = withPlanWorktree(repoPath, proc(planPath: string): bool =
    let changed = ensureMergeQueueInitializedInPlanPath(planPath)
    if changed:
      gitRun(planPath, "add", PlanMergeQueueDir)
      if gitCheck(planPath, "diff", "--cached", "--quiet") != 0:
        gitRun(planPath, "commit", "-m", MergeQueueInitCommitMessage)
    changed
  )

proc enqueueMergeRequest*(
  repoPath: string,
  assignment: TicketAssignment,
  summary: string,
): string =
  ## Persist a merge request into the plan-branch merge queue.
  if assignment.inProgressTicket.len == 0:
    raise newException(ValueError, "in-progress ticket path is required")
  if assignment.branch.len == 0:
    raise newException(ValueError, "assignment branch is required")
  if assignment.worktree.len == 0:
    raise newException(ValueError, "assignment worktree is required")
  if summary.strip().len == 0:
    raise newException(ValueError, "merge summary is required")

  result = withPlanWorktree(repoPath, proc(planPath: string): string =
    discard ensureMergeQueueInitializedInPlanPath(planPath)

    let queueId = nextMergeQueueId(planPath)
    let ticketId = ticketIdFromTicketPath(assignment.inProgressTicket)
    let pendingRelPath = PlanMergeQueuePendingDir / fmt"{queueId:04d}-{ticketId}.md"
    let item = MergeQueueItem(
      pendingPath: pendingRelPath,
      ticketPath: assignment.inProgressTicket,
      ticketId: ticketId,
      branch: assignment.branch,
      worktree: assignment.worktree,
      summary: summary.strip(),
    )

    writeFile(planPath / pendingRelPath, queueItemToMarkdown(item))
    gitRun(planPath, "add", PlanMergeQueueDir)
    if gitCheck(planPath, "diff", "--cached", "--quiet") != 0:
      gitRun(planPath, "commit", "-m", MergeQueueEnqueueCommitPrefix & " " & ticketId)
    pendingRelPath
  )

proc processMergeQueue*(repoPath: string): bool =
  ## Process at most one merge queue item and apply success/failure transitions.
  result = withPlanWorktree(repoPath, proc(planPath: string): bool =
    discard ensureMergeQueueInitializedInPlanPath(planPath)
    let activePath = planPath / PlanMergeQueueActivePath

    let queueItems = listMergeQueueItems(planPath)
    if queueItems.len == 0:
      if clearActiveQueueInPlanPath(planPath):
        commitMergeQueueCleanup(planPath, "")
        return true
      return false

    let item = queueItems[0]
    writeFile(activePath, item.pendingPath & "\n")
    let queuePath = planPath / item.pendingPath
    let ticketPath = planPath / item.ticketPath
    if not fileExists(ticketPath):
      let doneTicketPath = ticketPathInState(planPath, PlanTicketsDoneDir, item)
      let openTicketPath = ticketPathInState(planPath, PlanTicketsOpenDir, item)
      let hasTerminalTicket = fileExists(doneTicketPath) or fileExists(openTicketPath)
      if hasTerminalTicket:
        if fileExists(queuePath):
          removeFile(queuePath)
        writeFile(activePath, "")
        commitMergeQueueCleanup(planPath, item.ticketId)
        return true
      raise newException(ValueError, fmt"ticket does not exist in plan branch: {item.ticketPath}")

    let mergeMasterResult = runCommandCapture(item.worktree, "git", @["merge", "--no-edit", "master"])
    var testResult = (exitCode: 0, output: "")
    if mergeMasterResult.exitCode == 0:
      testResult = runCommandCapture(item.worktree, "make", @["test"])

    var mergedToMaster = false
    if mergeMasterResult.exitCode == 0 and testResult.exitCode == 0:
      let mergeToMasterResult = withMasterWorktree(repoPath, proc(masterPath: string): tuple[exitCode: int, output: string] =
        runCommandCapture(masterPath, "git", @["merge", "--ff-only", item.branch])
      )
      mergedToMaster = mergeToMasterResult.exitCode == 0
      if not mergedToMaster:
        testResult = mergeToMasterResult

    if mergeMasterResult.exitCode == 0 and testResult.exitCode == 0 and mergedToMaster:
      let doneRelPath = PlanTicketsDoneDir / extractFilename(item.ticketPath)
      let successNote = formatMergeSuccessNote(item.summary, testResult.output).strip()
      let updatedContent = readFile(ticketPath).strip() & "\n\n" & successNote & "\n"
      writeFile(ticketPath, updatedContent)
      moveFile(ticketPath, planPath / doneRelPath)
      if fileExists(queuePath):
        removeFile(queuePath)
      writeFile(activePath, "")

      gitRun(planPath, "add", "-A", PlanTicketsInProgressDir, PlanTicketsDoneDir, PlanMergeQueueDir)
      if gitCheck(planPath, "diff", "--cached", "--quiet") != 0:
        gitRun(planPath, "commit", "-m", MergeQueueDoneCommitPrefix & " " & item.ticketId)
      true
    else:
      let openRelPath = PlanTicketsOpenDir / extractFilename(item.ticketPath)
      let failureNote = formatMergeFailureNote(item.summary, mergeMasterResult.output, testResult.output).strip()
      let updatedContent = readFile(ticketPath).strip() & "\n\n" & failureNote & "\n"
      writeFile(ticketPath, updatedContent)
      moveFile(ticketPath, planPath / openRelPath)
      if fileExists(queuePath):
        removeFile(queuePath)
      writeFile(activePath, "")

      gitRun(planPath, "add", "-A", PlanTicketsInProgressDir, PlanTicketsOpenDir, PlanMergeQueueDir)
      if gitCheck(planPath, "diff", "--cached", "--quiet") != 0:
        gitRun(planPath, "commit", "-m", MergeQueueReopenCommitPrefix & " " & item.ticketId)
      true
  )

proc executeAssignedTicket*(
  repoPath: string,
  assignment: TicketAssignment,
  runner: AgentRunner = runAgent,
): AgentRunResult =
  ## Run the coding agent for an assigned in-progress ticket and persist run notes.
  if runner.isNil:
    raise newException(ValueError, "agent runner is required")
  if assignment.inProgressTicket.len == 0:
    raise newException(ValueError, "in-progress ticket path is required")
  if assignment.worktree.len == 0:
    raise newException(ValueError, "assignment worktree path is required")

  let cfg = loadConfig(repoPath)
  let ticketRelPath = assignment.inProgressTicket
  let ticketContent = withPlanWorktree(repoPath, proc(planPath: string): string =
    let ticketPath = planPath / ticketRelPath
    if not fileExists(ticketPath):
      raise newException(ValueError, fmt"ticket does not exist in plan branch: {ticketRelPath}")
    readFile(ticketPath)
  )

  let request = AgentRunRequest(
    prompt: buildCodingAgentPrompt(ticketRelPath, ticketContent),
    workingDir: assignment.worktree,
    model: cfg.models.coding,
    reasoningEffort: cfg.reasoningEffort.coding,
    ticketId: ticketIdFromTicketPath(ticketRelPath),
    attempt: DefaultAgentAttempt,
    skipGitRepoCheck: true,
    maxAttempts: DefaultAgentMaxAttempts,
  )
  let agentResult = runner(request)
  result = agentResult

  discard withPlanWorktree(repoPath, proc(planPath: string): int =
    let ticketPath = planPath / ticketRelPath
    if not fileExists(ticketPath):
      raise newException(ValueError, fmt"ticket does not exist in plan branch: {ticketRelPath}")

    let currentContent = readFile(ticketPath)
    let updatedContent = appendAgentRunNote(currentContent, cfg.models.coding, agentResult)
    writeFile(ticketPath, updatedContent)
    gitRun(planPath, "add", ticketRelPath)
    if gitCheck(planPath, "diff", "--cached", "--quiet") != 0:
      let ticketName = splitFile(ticketRelPath).name
      gitRun(planPath, "commit", "-m", TicketAgentRunCommitPrefix & " " & ticketName)
    0
  )

  let submitSummaryFromMessage = extractSubmitPrSummary(agentResult.lastMessage)
  let submitSummary =
    if submitSummaryFromMessage.len > 0:
      submitSummaryFromMessage
    else:
      extractSubmitPrSummary(agentResult.stdout)
  if submitSummary.len > 0:
    discard enqueueMergeRequest(repoPath, assignment, submitSummary)

proc executeOldestOpenTicket*(repoPath: string, runner: AgentRunner = runAgent): AgentRunResult =
  ## Assign the oldest open ticket and execute it with the coding agent.
  let assignment = assignOldestOpenTicket(repoPath)
  if assignment.inProgressTicket.len == 0:
    result = AgentRunResult()
  else:
    result = executeAssignedTicket(repoPath, assignment, runner)

proc createOrchestratorServer*(): HttpMcpServer =
  ## Create the orchestrator MCP HTTP server.
  let server = newMcpServer(OrchestratorServerName, OrchestratorServerVersion)
  result = newHttpMcpServer(server, logEnabled = false)

proc handleCtrlC() {.noconv.} =
  ## Stop the orchestrator loop on Ctrl+C.
  shouldRun = false

proc handlePosixSignal(signalNumber: cint) {.noconv.} =
  ## Stop the orchestrator loop on SIGINT/SIGTERM.
  discard signalNumber
  shouldRun = false

proc handleInteractivePlanCtrlC() {.noconv.} =
  ## Request shutdown of one interactive planning session on Ctrl+C.
  interactivePlanInterrupted = true

proc inputErrorIndicatesInterrupt(message: string): bool =
  ## Return true when one input error string indicates interrupted input.
  let lower = message.toLowerAscii()
  result = lower.contains("interrupted") or lower.contains("eintr")

proc installSignalHandlers() =
  ## Install signal handlers used by the orchestrator run loop.
  setControlCHook(handleCtrlC)
  posix.signal(SIGINT, handlePosixSignal)
  posix.signal(SIGTERM, handlePosixSignal)

proc runHttpServer(args: ServerThreadArgs) {.thread.} =
  ## Run the MCP HTTP server in a background thread.
  args.httpServer.serve(args.port, args.address)

proc hasPlanBranch(repoPath: string): bool =
  ## Return true when the repository has the scriptorium plan branch.
  result = gitCheck(repoPath, "rev-parse", "--verify", PlanBranch) == 0

proc masterHeadCommit(repoPath: string): string =
  ## Return the current master branch commit SHA.
  let process = startProcess(
    "git",
    args = @["-C", repoPath, "rev-parse", "master"],
    options = {poUsePath, poStdErrToStdOut},
  )
  let output = process.outputStream.readAll()
  let rc = process.waitForExit()
  process.close()
  if rc != 0:
    raise newException(IOError, fmt"git rev-parse master failed: {output.strip()}")
  result = output.strip()

proc checkMasterHealth(repoPath: string): bool =
  ## Run the master health check command and return true on success.
  let checkResult = withMasterWorktree(repoPath, proc(masterPath: string): tuple[exitCode: int, output: string] =
    runCommandCapture(masterPath, "make", @[MasterHealthCheckTarget])
  )
  result = checkResult.exitCode == 0

proc isMasterHealthy(repoPath: string, state: var MasterHealthState): bool =
  ## Return cached master health, refreshing only when the master commit changes.
  let currentHead = masterHeadCommit(repoPath)
  if (not state.initialized) or state.head != currentHead:
    state.head = currentHead
    state.healthy = checkMasterHealth(repoPath)
    state.initialized = true
  result = state.healthy

proc runOrchestratorMainLoop(repoPath: string, maxTicks: int, runner: AgentRunner) =
  ## Execute the orchestrator polling loop for an optional bounded number of ticks.
  var ticks = 0
  var masterHealthState = MasterHealthState()
  while shouldRun:
    if maxTicks >= 0 and ticks >= maxTicks:
      break
    if hasPlanBranch(repoPath):
      if isMasterHealthy(repoPath, masterHealthState):
        if hasRunnableSpec(repoPath):
          discard runArchitectAreas(repoPath, runner)
          discard runManagerTickets(repoPath, runner)
          discard executeOldestOpenTicket(repoPath, runner)
          discard processMergeQueue(repoPath)
        else:
          echo WaitingNoSpecMessage
    sleep(IdleSleepMs)
    inc ticks

proc runOrchestratorLoop(
  repoPath: string,
  httpServer: HttpMcpServer,
  endpoint: OrchestratorEndpoint,
  maxTicks: int,
  runner: AgentRunner,
) =
  ## Start HTTP transport and execute the orchestrator idle event loop.
  shouldRun = true
  installSignalHandlers()

  var serverThread: Thread[ServerThreadArgs]
  createThread(serverThread, runHttpServer, (httpServer, endpoint.address, endpoint.port))
  runOrchestratorMainLoop(repoPath, maxTicks, runner)

  shouldRun = false
  httpServer.close()
  joinThread(serverThread)

proc runOrchestratorForTicks*(repoPath: string, maxTicks: int, runner: AgentRunner = runAgent) =
  ## Run a bounded orchestrator loop without starting the MCP HTTP server.
  shouldRun = true
  runOrchestratorMainLoop(repoPath, maxTicks, runner)
  shouldRun = false

proc buildInteractivePlanPrompt*(repoPath: string, spec: string, history: seq[PlanTurn], userMsg: string): string =
  ## Assemble the multi-turn architect prompt with spec, history, and current message.
  var conversationHistory = ""
  if history.len > 0:
    conversationHistory = "\nConversation history:\n"
    for turn in history:
      conversationHistory &= fmt"\n[{turn.role}]: {turn.text.strip()}\n"

  result = renderPromptTemplate(
    ArchitectPlanInteractiveTemplate,
    [
      (name: "PLAN_SCOPE", value: buildPlanScopePrompt(repoPath).strip()),
      (name: "CURRENT_SPEC", value: spec.strip()),
      (name: "CONVERSATION_HISTORY", value: conversationHistory),
      (name: "USER_MESSAGE", value: userMsg.strip()),
    ],
  )

proc runInteractivePlanSession*(
  repoPath: string,
  runner: AgentRunner = runAgent,
  input: PlanSessionInput = nil,
  quiet: bool = false,
) =
  ## Run a multi-turn interactive planning session with the Architect.
  if runner.isNil:
    raise newException(ValueError, "agent runner is required")

  interactivePlanInterrupted = false
  setControlCHook(handleInteractivePlanCtrlC)
  defer:
    when declared(unsetControlCHook):
      unsetControlCHook()
    interactivePlanInterrupted = false

  let cfg = loadConfig(repoPath)
  discard withPlanWorktree(repoPath, proc(planPath: string): int =
    if not quiet:
      echo "scriptorium: interactive planning session (type /help for commands, /quit to exit)"
    var history: seq[PlanTurn] = @[]
    var turnNum = 0

    while true:
      if interactivePlanInterrupted:
        if not quiet:
          echo ""
        break

      if not quiet:
        stdout.write("> ")
        flushFile(stdout)
      var line: string
      try:
        if input.isNil:
          line = readLine(stdin)
        else:
          line = input()
      except EOFError:
        break
      except CatchableError as err:
        if interactivePlanInterrupted or inputErrorIndicatesInterrupt(err.msg):
          if not quiet:
            echo ""
          break
        raise err

      line = line.strip()
      if line.len == 0:
        continue

      case line
      of "/quit", "/exit":
        break
      of "/show":
        let specPath = planPath / PlanSpecPath
        if not quiet:
          if fileExists(specPath):
            echo readFile(specPath)
          else:
            echo "scriptorium: spec.md not found"
        continue
      of "/help":
        if not quiet:
          echo "/show  — print current spec.md"
          echo "/quit  — exit the session"
          echo "/help  — show this list"
        continue
      else:
        if line.startsWith("/"):
          if not quiet:
            echo fmt"scriptorium: unknown command '{line}'"
          continue

      let prevSpec = readFile(planPath / PlanSpecPath)
      inc turnNum
      let prompt = buildInteractivePlanPrompt(repoPath, prevSpec, history, line)
      var lastStreamLine = "[thinking] working..."
      if not quiet:
        echo lastStreamLine
      let streamEventHandler = proc(event: AgentStreamEvent) =
        ## Render live architect stream events in concise interactive form.
        if quiet:
          return
        let rendered = formatPlanStreamEvent(event)
        if rendered.len > 0 and rendered != lastStreamLine:
          echo rendered
          lastStreamLine = rendered
      let agentResult = runPlanArchitectRequest(
        runner,
        planPath,
        cfg.models.architect,
        cfg.reasoningEffort.architect,
        prompt,
        PlanSessionTicketId,
        streamEventHandler,
        PlanHeartbeatIntervalMs,
      )
      enforceWriteAllowlist(planPath, [PlanSpecPath], PlanWriteScopeName)

      var response = agentResult.lastMessage.strip()
      if response.len == 0:
        response = agentResult.stdout.strip()
      if response.len > 0 and not quiet:
        echo response

      history.add(PlanTurn(role: "engineer", text: line))
      history.add(PlanTurn(role: "architect", text: response))

      let newSpec = readFile(planPath / PlanSpecPath)
      if newSpec != prevSpec:
        gitRun(planPath, "add", PlanSpecPath)
        gitRun(planPath, "commit", "-m", fmt"scriptorium: plan session turn {turnNum}")
        if not quiet:
          echo fmt"[spec.md updated — turn {turnNum}]"
    0
  )

proc runOrchestrator*(repoPath: string) =
  ## Start the orchestrator daemon with HTTP MCP and an idle event loop.
  let endpoint = loadOrchestratorEndpoint(repoPath)
  echo fmt"scriptorium: orchestrator listening on http://{endpoint.address}:{endpoint.port}"
  let httpServer = createOrchestratorServer()
  runOrchestratorLoop(repoPath, httpServer, endpoint, -1, runAgent)
