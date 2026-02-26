import
  std/[os, strformat, strutils, uri]
import
  mcport
import
  ./config

when defined(posix):
  import std/posix

const
  DefaultLocalEndpoint* = "http://127.0.0.1:8097"
  IdleSleepMs = 200
  OrchestratorServerName = "scriptorium-orchestrator"
  OrchestratorServerVersion = "0.1.0"

type
  OrchestratorEndpoint* = object
    address*: string
    port*: int

when compileOption("threads"):
  type
    ServerThreadArgs = tuple[
      httpServer: HttpMcpServer,
      address: string,
      port: int,
    ]

var shouldRun {.volatile.} = true

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

proc createOrchestratorServer*(): HttpMcpServer =
  ## Create the orchestrator MCP HTTP server.
  let server = newMcpServer(OrchestratorServerName, OrchestratorServerVersion)
  result = newHttpMcpServer(server, logEnabled = false)

proc handleCtrlC() {.noconv.} =
  ## Stop the orchestrator loop on Ctrl+C.
  shouldRun = false

when defined(posix):
  proc handlePosixSignal(signalNumber: cint) {.noconv.} =
    ## Stop the orchestrator loop on SIGINT/SIGTERM.
    discard signalNumber
    shouldRun = false

proc installSignalHandlers() =
  ## Install signal handlers used by the orchestrator run loop.
  setControlCHook(handleCtrlC)
  when defined(posix):
    posix.signal(SIGINT, handlePosixSignal)
    posix.signal(SIGTERM, handlePosixSignal)

when compileOption("threads"):
  proc runHttpServer(args: ServerThreadArgs) {.thread.} =
    ## Run the MCP HTTP server in a background thread.
    args.httpServer.serve(args.port, args.address)

proc runOrchestratorLoop(httpServer: HttpMcpServer, endpoint: OrchestratorEndpoint, maxTicks: int) =
  ## Start HTTP transport and execute the orchestrator idle event loop.
  shouldRun = true
  installSignalHandlers()

  when compileOption("threads"):
    var serverThread: Thread[ServerThreadArgs]
    createThread(serverThread, runHttpServer, (httpServer, endpoint.address, endpoint.port))

    var ticks = 0
    while shouldRun:
      if maxTicks >= 0 and ticks >= maxTicks:
        break
      sleep(IdleSleepMs)
      inc ticks

    shouldRun = false
    httpServer.close()
    joinThread(serverThread)
  else:
    httpServer.serve(endpoint.port, endpoint.address)

proc runOrchestratorForTicks*(repoPath: string, maxTicks: int) =
  ## Run the orchestrator loop for a bounded number of ticks. Used by tests.
  let endpoint = loadOrchestratorEndpoint(repoPath)
  let httpServer = createOrchestratorServer()
  runOrchestratorLoop(httpServer, endpoint, maxTicks)

proc runOrchestrator*(repoPath: string) =
  ## Start the orchestrator daemon with HTTP MCP and an idle event loop.
  let endpoint = loadOrchestratorEndpoint(repoPath)
  echo fmt"scriptorium: orchestrator listening on http://{endpoint.address}:{endpoint.port}"
  let httpServer = createOrchestratorServer()
  runOrchestratorLoop(httpServer, endpoint, -1)
