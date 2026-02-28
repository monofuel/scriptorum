import
  std/strformat,
  ./[config, harness_codex]

type
  AgentStreamEventKind* = enum
    agentEventHeartbeat = "heartbeat"
    agentEventReasoning = "reasoning"
    agentEventTool = "tool"
    agentEventStatus = "status"
    agentEventMessage = "message"

  AgentStreamEvent* = object
    kind*: AgentStreamEventKind
    text*: string
    rawLine*: string

  AgentEventHandler* = proc(event: AgentStreamEvent)

  AgentRunRequest* = object
    prompt*: string
    workingDir*: string
    model*: string
    reasoningEffort*: string
    ticketId*: string
    attempt*: int
    codexBinary*: string
    skipGitRepoCheck*: bool
    logRoot*: string
    noOutputTimeoutMs*: int
    hardTimeoutMs*: int
    heartbeatIntervalMs*: int
    maxAttempts*: int
    continuationPrompt*: string
    onEvent*: AgentEventHandler

  AgentRunResult* = object
    backend*: Harness
    command*: seq[string]
    exitCode*: int
    attempt*: int
    attemptCount*: int
    stdout*: string
    logFile*: string
    lastMessageFile*: string
    lastMessage*: string
    timeoutKind*: string

  AgentRunner* = proc(request: AgentRunRequest): AgentRunResult

proc mapCodexEvent(event: CodexStreamEvent): AgentStreamEvent =
  ## Convert one codex stream event into an agent stream event.
  result = AgentStreamEvent(
    text: event.text,
    rawLine: event.rawLine,
  )
  case event.kind
  of codexEventHeartbeat:
    result.kind = agentEventHeartbeat
  of codexEventReasoning:
    result.kind = agentEventReasoning
  of codexEventTool:
    result.kind = agentEventTool
  of codexEventStatus:
    result.kind = agentEventStatus
  of codexEventMessage:
    result.kind = agentEventMessage

proc runAgent*(request: AgentRunRequest): AgentRunResult =
  ## Run the configured agent backend for one coding request.
  if request.workingDir.len == 0:
    raise newException(ValueError, "workingDir is required")
  if request.model.len == 0:
    raise newException(ValueError, "model is required")

  let backend = harness(request.model)
  case backend
  of harnessCodex:
    let codexResult = runCodex(CodexRunRequest(
      prompt: request.prompt,
      workingDir: request.workingDir,
      model: request.model,
      reasoningEffort: request.reasoningEffort,
      ticketId: request.ticketId,
      attempt: request.attempt,
      codexBinary: request.codexBinary,
      skipGitRepoCheck: request.skipGitRepoCheck,
      logRoot: request.logRoot,
      noOutputTimeoutMs: request.noOutputTimeoutMs,
      hardTimeoutMs: request.hardTimeoutMs,
      heartbeatIntervalMs: request.heartbeatIntervalMs,
      maxAttempts: request.maxAttempts,
      continuationPrompt: request.continuationPrompt,
      onEvent: proc(event: CodexStreamEvent) =
        ## Forward codex streaming events to the optional agent callback.
        if not request.onEvent.isNil:
          request.onEvent(mapCodexEvent(event))
    ))
    result = AgentRunResult(
      backend: backend,
      command: codexResult.command,
      exitCode: codexResult.exitCode,
      attempt: codexResult.attempt,
      attemptCount: codexResult.attemptCount,
      stdout: codexResult.stdout,
      logFile: codexResult.logFile,
      lastMessageFile: codexResult.lastMessageFile,
      lastMessage: codexResult.lastMessage,
      timeoutKind: $codexResult.timeoutKind,
    )
  else:
    raise newException(ValueError, &"agent backend '{backend}' is not implemented")
