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
      "exec",
      "--json",
      "--output-last-message",
      "/tmp/last-message.txt",
      "--cd",
      "/tmp/worktree",
      "--model",
      "gpt-5.1-codex-mini",
      "--dangerously-bypass-approvals-and-sandbox",
      "--skip-git-repo-check",
      "-",
    ]

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
