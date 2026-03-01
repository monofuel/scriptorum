## Integration tests for live MCP submit_pr transport and real Codex tool calling.

import
  std/[httpclient, json, os, osproc, strformat, strutils, tempfiles, times, unittest],
  mcport,
  scriptorium/[harness_codex, orchestrator]

const
  LiveMcpBasePort = 22000
  DefaultIntegrationModel = "gpt-5.3-codex"
  CodexAuthPathEnv = "CODEX_AUTH_FILE"
  RpcTimeoutMs = 30_000
  CodexHardTimeoutMs = 120_000
  CodexNoOutputTimeoutMs = 45_000
  ServerStartupSleepMs = 250
  ClientProtocolVersion = "2025-06-18"

type
  ServerThreadArgs = tuple[
    httpServer: HttpMcpServer,
    address: string,
    port: int,
  ]

var
  liveServers: seq[HttpMcpServer] = @[]

proc runHttpServer(args: ServerThreadArgs) {.thread.} =
  ## Run one MCP HTTP server in a background thread.
  args.httpServer.serve(args.port, args.address)

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

proc mcpPort(offset: int): int =
  ## Return a deterministic local MCP port for one test offset.
  result = LiveMcpBasePort + (getCurrentProcessId().int mod 1000) + offset

proc mcpBaseUrl(port: int): string =
  ## Return the base MCP HTTP URL for one local port.
  result = &"http://127.0.0.1:{port}"

proc mcpRequest(mcpUrl: string, requestId: int, methodName: string, params: JsonNode): JsonNode =
  ## Send one MCP JSON-RPC request over HTTP and return parsed JSON response.
  let payload = %*{
    "jsonrpc": "2.0",
    "id": requestId,
    "method": methodName,
    "params": params,
  }
  var client = newHttpClient(timeout = RpcTimeoutMs)
  defer:
    client.close()

  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
  })
  let response = client.request(mcpUrl, httpMethod = HttpPost, body = $payload)
  let responseBody = response.body
  doAssert response.code == Http200, &"MCP HTTP request failed ({response.code}): {responseBody}"
  result = parseJson(responseBody)

proc initializeMcpSession(mcpUrl: string) =
  ## Perform one MCP initialize request to establish a client session.
  discard mcpRequest(
    mcpUrl,
    1,
    "initialize",
    %*{
      "protocolVersion": ClientProtocolVersion,
      "capabilities": {},
      "clientInfo": {
        "name": "scriptorium-integration-tests",
        "version": "1.0.0",
      },
    },
  )

suite "integration mcp submit_pr live":
  test "IT-LIVE-01 real MCP HTTP tools/list and tools/call for submit_pr":
    discard consumeSubmitPrSummary()
    let port = mcpPort(1)
    let mcpUrl = mcpBaseUrl(port) & "/mcp"

    let httpServer = createOrchestratorServer()
    var serverThread: Thread[ServerThreadArgs]
    createThread(serverThread, runHttpServer, (httpServer, "127.0.0.1", port))
    sleep(ServerStartupSleepMs)
    liveServers.add(httpServer)

    initializeMcpSession(mcpUrl)

    let listResponse = mcpRequest(mcpUrl, 2, "tools/list", %*{})
    let tools = listResponse["result"]["tools"]
    var foundSubmitPr = false
    for tool in tools:
      if tool["name"].getStr() == "submit_pr":
        foundSubmitPr = true

    check foundSubmitPr

    let summary = "integration-live-mcp-http"
    let callResponse = mcpRequest(
      mcpUrl,
      3,
      "tools/call",
      %*{
        "name": "submit_pr",
        "arguments": {
          "summary": summary,
        },
      },
    )
    let responseText = callResponse["result"]["content"][0]["text"].getStr()
    check responseText == "Merge request enqueued."
    check consumeSubmitPrSummary() == summary
    check consumeSubmitPrSummary() == ""

  test "IT-LIVE-02 real Codex calls submit_pr against live MCP HTTP server":
    let codexPath = findExe("codex")
    doAssert codexPath.len > 0, "codex binary is required for live integration tests"
    doAssert hasCodexAuth(),
      "OPENAI_API_KEY/CODEX_API_KEY or a Codex OAuth auth file is required for live integration tests (" &
      codexAuthPath() & ")"

    discard consumeSubmitPrSummary()
    let port = mcpPort(2)
    let endpoint = mcpBaseUrl(port)

    let httpServer = createOrchestratorServer()
    var serverThread: Thread[ServerThreadArgs]
    createThread(serverThread, runHttpServer, (httpServer, "127.0.0.1", port))
    sleep(ServerStartupSleepMs)
    liveServers.add(httpServer)

    let tmpDir = createTempDir("scriptorium_integration_live_mcp_codex_", "", getTempDir())
    defer:
      removeDir(tmpDir)

    let
      worktreePath = tmpDir / "worktree"
      timestamp = now().utc().format("yyyyMMddHHmmss")
      nonce = &"it-live-02-{getCurrentProcessId()}-{timestamp}"
      expectedMcpArg = "mcp_servers.scriptorium={url = \"" & endpoint & "/mcp\", enabled = true, required = true}"
      prompt =
        "You are running an integration test. " &
        "You have a function called submit_pr in your tool list. " &
        "Use the submit_pr function exactly once with the argument summary=\"" & nonce & "\". " &
        "Do not execute any shell commands. Do not search the filesystem. " &
        "if the function is missing, fail immediately." &
        "After the function call succeeds, reply with exactly DONE."
    createDir(worktreePath)

    let request = CodexRunRequest(
      prompt: prompt,
      workingDir: worktreePath,
      model: integrationModel(),
      mcpEndpoint: endpoint,
      ticketId: "integration-live-submit-pr",
      skipGitRepoCheck: true,
      logRoot: tmpDir / "logs",
      hardTimeoutMs: CodexHardTimeoutMs,
      noOutputTimeoutMs: CodexNoOutputTimeoutMs,
    )

    let runResult = runCodex(request)
    doAssert runResult.exitCode == 0,
      "codex failed to complete live MCP submit_pr integration.\n" &
      "Command: " & runResult.command.join(" ") & "\n" &
      "Stdout:\n" & runResult.stdout
    check expectedMcpArg in runResult.command
    check runResult.stdout.contains("\"type\":\"mcp_tool_call\"")
    check runResult.stdout.contains("\"tool\":\"submit_pr\"")
    let consumedSummary = consumeSubmitPrSummary()
    doAssert consumedSummary == nonce,
      "expected live submit_pr summary was not captured.\n" &
      "Expected: " & nonce & "\n" &
      "Actual: " & consumedSummary & "\n" &
      "Stdout:\n" & runResult.stdout

  test "IT-LIVE-03 codex mcp list confirms server is enabled and required":
    let codexPath = findExe("codex")
    doAssert codexPath.len > 0, "codex binary is required for live integration tests"

    let port = mcpPort(3)
    let endpoint = mcpBaseUrl(port)

    let httpServer = createOrchestratorServer()
    var serverThread: Thread[ServerThreadArgs]
    createThread(serverThread, runHttpServer, (httpServer, "127.0.0.1", port))
    sleep(ServerStartupSleepMs)
    liveServers.add(httpServer)

    let request = CodexRunRequest(
      mcpEndpoint: endpoint,
    )
    let args = buildCodexMcpListArgs(request)
    let cmdParts = @[codexPath] & args
    var quotedCommandParts: seq[string] = @[]
    for part in cmdParts:
      quotedCommandParts.add(quoteShell(part))
    let fullCommand = quotedCommandParts.join(" ")
    let (output, exitCode) = execCmdEx(fullCommand)

    doAssert exitCode == 0,
      "codex mcp list --json failed.\n" &
      "Command: " & fullCommand & "\n" &
      "Output:\n" & output

    let jsonOutput = parseJson(output.strip())
    doAssert jsonOutput.kind == JArray,
      "expected codex mcp list output to be a JSON array.\n" &
      "Output:\n" & output

    var foundScriptorium = false
    var isEnabled = false
    var isRequired = false
    var hasRequired = false

    for server in jsonOutput:
      if server["name"].getStr() == "scriptorium":
        foundScriptorium = true
        isEnabled = server["enabled"].getBool()
        if server.hasKey("required"):
          hasRequired = true
          isRequired = server["required"].getBool()

    check foundScriptorium
    check isEnabled
    if hasRequired:
      check isRequired
