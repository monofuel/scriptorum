## Unit tests for the codex process harness.

import
  std/[os, strutils, tempfiles, unittest],
  scriptorium/harness_codex

proc withTempHarnessDir(action: proc(tmpDir: string)) =
  ## Run action inside a temporary directory and remove it afterwards.
  let tmpDir = createTempDir("scriptorium_test_harness_codex_", "", getTempDir())
  defer:
    removeDir(tmpDir)
  action(tmpDir)

proc writeExecutableScript(path: string, body: string) =
  ## Write a bash script to path and mark it executable.
  let scriptContent = "#!/usr/bin/env bash\nset -euo pipefail\n" & body
  writeFile(path, scriptContent)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc newBaseRequest(tmpDir: string, codexPath: string, ticketId: string): CodexRunRequest =
  ## Build a baseline codex run request for fake harness tests.
  let worktreePath = tmpDir / "worktree"
  createDir(worktreePath)
  result = CodexRunRequest(
    prompt: "Implement the task.",
    workingDir: worktreePath,
    model: "gpt-5.1-codex-mini",
    ticketId: ticketId,
    codexBinary: codexPath,
    logRoot: tmpDir / "logs",
  )

suite "harness codex":
  test "buildCodexExecArgs matches expected arg order":
    let request = CodexRunRequest(
      workingDir: "/tmp/worktree",
      model: "gpt-5.1-codex-mini",
      skipGitRepoCheck: true,
    )

    let args = buildCodexExecArgs(request, "/tmp/last-message.txt")
    check args == @[
      "-c",
      "developer_instructions=\"\"",
      "exec",
      "--json",
      "--output-last-message",
      "/tmp/last-message.txt",
      "--cd",
      "/tmp/worktree",
      "--model",
      "gpt-5.1-codex-mini",
      "--dangerously-bypass-approvals-and-sandbox",
      "-c",
      "model_reasoning_effort=\"high\"",
      "--skip-git-repo-check",
      "-",
    ]

  test "buildCodexExecArgs sets mini reasoning effort to high by default":
    let request = CodexRunRequest(
      workingDir: "/tmp/worktree",
      model: "gpt-5.1-codex-mini",
    )

    let args = buildCodexExecArgs(request, "/tmp/last-message.txt")
    check "model_reasoning_effort=\"high\"" in args

  test "buildCodexMcpListArgs includes mcp config and mcp list --json":
    let request = CodexRunRequest(
      mcpEndpoint: "http://127.0.0.1:8097",
    )

    let args = buildCodexMcpListArgs(request)
    check args[0] == "-c"
    check "mcp_servers.scriptorium" in args[1]
    check "mcp" in args
    check "list" in args
    check "--json" in args

  test "buildCodexMcpListArgs returns only subcommand when no endpoint":
    let request = CodexRunRequest()

    let args = buildCodexMcpListArgs(request)
    check args == @["mcp", "list", "--json"]

  test "buildCodexExecArgs includes mcp server when endpoint is configured":
    let request = CodexRunRequest(
      workingDir: "/tmp/worktree",
      model: "gpt-5.1-codex-mini",
      mcpEndpoint: "http://127.0.0.1:8097",
    )

    let args = buildCodexExecArgs(request, "/tmp/last-message.txt")
    let expectedMcpArg = "mcp_servers.scriptorium={url = \"http://127.0.0.1:8097/mcp\", enabled = true, required = true}"
    check expectedMcpArg in args

  test "buildCodexExecArgs trims trailing slash from mcp endpoint":
    let request = CodexRunRequest(
      workingDir: "/tmp/worktree",
      model: "gpt-5.1-codex-mini",
      mcpEndpoint: "http://127.0.0.1:8097/",
    )

    let args = buildCodexExecArgs(request, "/tmp/last-message.txt")
    let expectedMcpArg = "mcp_servers.scriptorium={url = \"http://127.0.0.1:8097/mcp\", enabled = true, required = true}"
    check expectedMcpArg in args

  test "buildCodexExecArgs includes reasoning effort override when configured":
    let request = CodexRunRequest(
      workingDir: "/tmp/worktree",
      model: "gpt-5.1-codex-mini",
      reasoningEffort: "high",
    )

    let args = buildCodexExecArgs(request, "/tmp/last-message.txt")
    check "-c" in args
    check "model_reasoning_effort=\"high\"" in args

  test "buildCodexExecArgs keeps xhigh for non-mini models":
    let request = CodexRunRequest(
      workingDir: "/tmp/worktree",
      model: "gpt-5.3-codex",
      reasoningEffort: "xhigh",
    )

    let args = buildCodexExecArgs(request, "/tmp/last-message.txt")
    check "model_reasoning_effort=\"xhigh\"" in args

  test "buildCodexExecArgs maps mini xhigh to high":
    let request = CodexRunRequest(
      workingDir: "/tmp/worktree",
      model: "gpt-5.1-codex-mini",
      reasoningEffort: "xhigh",
    )

    let args = buildCodexExecArgs(request, "/tmp/last-message.txt")
    check "model_reasoning_effort=\"high\"" in args

  test "buildCodexExecArgs leaves reasoning unset for non-mini models":
    let request = CodexRunRequest(
      workingDir: "/tmp/worktree",
      model: "gpt-5.3-codex",
    )

    let args = buildCodexExecArgs(request, "/tmp/last-message.txt")
    check "model_reasoning_effort=\"high\"" notin args

  test "buildCodexExecArgs rejects unsupported reasoning effort values":
    let request = CodexRunRequest(
      workingDir: "/tmp/worktree",
      model: "gpt-5.1-codex-mini",
      reasoningEffort: "maximum",
    )

    expect ValueError:
      discard buildCodexExecArgs(request, "/tmp/last-message.txt")

  test "runCodex captures output log and last message":
    withTempHarnessDir(proc(tmpDir: string) =
      let codexPath = tmpDir / "fake-codex-success.sh"
      writeExecutableScript(codexPath, """
last_message=""
model=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) last_message="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
prompt="$(cat)"
printf '{"type":"message","text":"%s"}\n' "$prompt"
printf 'final:%s\n' "$model" > "$last_message"
""")

      var request = newBaseRequest(tmpDir, codexPath, "ticket-success")
      request.skipGitRepoCheck = true
      let result = runCodex(request)

      check result.exitCode == 0
      check result.attempt == 1
      check result.attemptCount == 1
      check result.timeoutKind == codexTimeoutNone
      check fileExists(result.logFile)
      check result.stdout.contains("\"type\":\"message\"")
      check result.lastMessage.contains("final:gpt-5.1-codex-mini")
      check result.command.len > 0
      check result.command[0] == codexPath
    )

  test "runCodex emits heartbeat and parsed stream events":
    withTempHarnessDir(proc(tmpDir: string) =
      let codexPath = tmpDir / "fake-codex-events.sh"
      writeExecutableScript(codexPath, """
last_message=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) last_message="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
sleep 0.25
printf '{"type":"reasoning","summary":"checking project docs"}\n'
printf '{"type":"tool_call","name":"read_file","status":"started"}\n'
printf '{"type":"tool_call","name":"read_file","status":"completed"}\n'
printf '{"type":"message","text":"done"}\n'
printf 'done\n' > "$last_message"
""")

      var request = newBaseRequest(tmpDir, codexPath, "ticket-events")
      request.heartbeatIntervalMs = 100
      var events: seq[string] = @[]
      request.onEvent = proc(event: CodexStreamEvent) =
        ## Collect stream events for assertions.
        events.add($event.kind & ":" & event.text)

      let result = runCodex(request)

      var sawHeartbeat = false
      var sawReasoning = false
      var sawToolStart = false
      var sawToolDone = false
      for event in events:
        if event.startsWith("heartbeat:"):
          sawHeartbeat = true
        if event.contains("reasoning:checking project docs"):
          sawReasoning = true
        if event.contains("tool:read_file (started)"):
          sawToolStart = true
        if event.contains("tool:read_file (completed)"):
          sawToolDone = true

      check result.exitCode == 0
      check sawHeartbeat
      check sawReasoning
      check sawToolStart
      check sawToolDone
    )

  test "runCodex parses nested json event fields":
    withTempHarnessDir(proc(tmpDir: string) =
      let codexPath = tmpDir / "fake-codex-nested-events.sh"
      writeExecutableScript(codexPath, """
last_message=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) last_message="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
printf '{"type":"analysis","data":{"summary":"reading nested event"}}\n'
printf '{"type":"tool_call","tool":{"tool_name":"read_file"},"state":"started"}\n'
printf '{"type":"tool_call","event":{"toolName":"read_file","phase":"completed"}}\n'
printf '{"type":"message","data":{"content":"done nested"}}\n'
printf 'done\n' > "$last_message"
""")

      var request = newBaseRequest(tmpDir, codexPath, "ticket-nested-events")
      var events: seq[string] = @[]
      request.onEvent = proc(event: CodexStreamEvent) =
        ## Collect stream events for nested JSON assertions.
        events.add($event.kind & ":" & event.text)

      let result = runCodex(request)

      var sawReasoning = false
      var sawToolStart = false
      var sawToolDone = false
      var sawMessage = false
      for event in events:
        if event.contains("reasoning:reading nested event"):
          sawReasoning = true
        if event.contains("tool:read_file (started)"):
          sawToolStart = true
        if event.contains("tool:read_file (completed)"):
          sawToolDone = true
        if event.contains("message:done nested"):
          sawMessage = true

      check result.exitCode == 0
      check sawReasoning
      check sawToolStart
      check sawToolDone
      check sawMessage
    )

  test "runCodex preserves malformed output lines without crashing":
    withTempHarnessDir(proc(tmpDir: string) =
      let codexPath = tmpDir / "fake-codex-malformed.sh"
      writeExecutableScript(codexPath, """
last_message=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) last_message="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
printf 'this is not json\n'
printf '{"type":"message","text":"valid after malformed"}\n'
printf 'ok\n' > "$last_message"
""")

      let request = newBaseRequest(tmpDir, codexPath, "ticket-malformed")
      let result = runCodex(request)

      check result.exitCode == 0
      check result.timeoutKind == codexTimeoutNone
      check result.stdout.contains("this is not json")
      check result.stdout.contains("\"valid after malformed\"")
      check result.lastMessage.contains("ok")
    )

  test "runCodex returns non-zero exit without retries by default":
    withTempHarnessDir(proc(tmpDir: string) =
      let codexPath = tmpDir / "fake-codex-fail.sh"
      writeExecutableScript(codexPath, """
last_message=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) last_message="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
printf '{"type":"error","message":"failed"}\n'
printf 'failed\n' > "$last_message"
exit 7
""")

      let request = newBaseRequest(tmpDir, codexPath, "ticket-fail")
      let result = runCodex(request)

      check result.exitCode == 7
      check result.attempt == 1
      check result.attemptCount == 1
      check result.timeoutKind == codexTimeoutNone
      check result.lastMessage.contains("failed")
    )

  test "runCodex retries and uses continuation prompt":
    withTempHarnessDir(proc(tmpDir: string) =
      let codexPath = tmpDir / "fake-codex-retry.sh"
      writeExecutableScript(codexPath, """
last_message=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) last_message="$2"; shift 2 ;;
    *) shift ;;
  esac
done
prompt="$(cat)"
prompt_file="${last_message%.last_message.txt}.prompt.txt"
printf '%s' "$prompt" > "$prompt_file"
if [[ "$last_message" == *"attempt-01.last_message.txt" ]]; then
  printf '{"type":"error","message":"retry"}\n'
  printf 'first attempt failed\n' > "$last_message"
  exit 9
fi
printf '{"type":"message","message":"ok"}\n'
printf 'second attempt success\n' > "$last_message"
""")

      var request = newBaseRequest(tmpDir, codexPath, "ticket-retry")
      request.maxAttempts = 2
      let result = runCodex(request)
      let secondPromptPath = request.logRoot / "ticket-retry" / "attempt-02.prompt.txt"

      check result.exitCode == 0
      check result.attempt == 2
      check result.attemptCount == 2
      check result.timeoutKind == codexTimeoutNone
      check fileExists(secondPromptPath)
      check readFile(secondPromptPath).contains("Attempt 1 failed")
    )

  test "runCodex flags no-output timeout":
    withTempHarnessDir(proc(tmpDir: string) =
      let codexPath = tmpDir / "fake-codex-stall.sh"
      writeExecutableScript(codexPath, """
cat >/dev/null
sleep 3
printf '{"type":"message","message":"late"}\n'
""")

      var request = newBaseRequest(tmpDir, codexPath, "ticket-timeout-no-output")
      request.noOutputTimeoutMs = 150
      request.hardTimeoutMs = 2000
      let result = runCodex(request)

      check result.timeoutKind == codexTimeoutNoOutput
      check result.exitCode != 0
      check result.attemptCount == 1
    )

  test "runCodex flags hard timeout":
    withTempHarnessDir(proc(tmpDir: string) =
      let codexPath = tmpDir / "fake-codex-hard-timeout.sh"
      writeExecutableScript(codexPath, """
cat >/dev/null
while true; do
  printf '{"type":"message","message":"tick"}\n'
  sleep 0.05
done
""")

      var request = newBaseRequest(tmpDir, codexPath, "ticket-timeout-hard")
      request.noOutputTimeoutMs = 0
      request.hardTimeoutMs = 250
      let result = runCodex(request)

      check result.timeoutKind == codexTimeoutHard
      check result.exitCode != 0
      check result.attemptCount == 1
    )
