## Unit tests for the backend-agnostic agent runner interface.

import
  std/[os, strutils, tempfiles, unittest],
  scriptorium/[agent_runner, config]

proc withTempAgentDir(action: proc(tmpDir: string)) =
  ## Run action inside a temporary directory and remove it afterwards.
  let tmpDir = createTempDir("scriptorium_test_agent_runner_", "", getTempDir())
  defer:
    removeDir(tmpDir)
  action(tmpDir)

proc writeExecutableScript(path: string, body: string) =
  ## Write a bash script to path and mark it executable.
  let scriptContent = "#!/usr/bin/env bash\nset -euo pipefail\n" & body
  writeFile(path, scriptContent)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

suite "agent runner":
  test "runAgent routes codex models to codex backend":
    withTempAgentDir(proc(tmpDir: string) =
      let codexPath = tmpDir / "fake-codex.sh"
      writeExecutableScript(codexPath, """
last_message=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) last_message="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
printf '{"type":"message","text":"ok"}\n'
printf 'done\n' > "$last_message"
""")

      let worktreePath = tmpDir / "worktree"
      createDir(worktreePath)
      let request = AgentRunRequest(
        prompt: "Write code.",
        workingDir: worktreePath,
        model: "gpt-5.1-codex-mini",
        ticketId: "0001",
        codexBinary: codexPath,
        logRoot: tmpDir / "logs",
      )
      let result = runAgent(request)

      check result.backend == harnessCodex
      check result.exitCode == 0
      check result.timeoutKind == "none"
      check result.lastMessage.contains("done")
    )

  test "runAgent rejects unsupported backends for now":
    withTempAgentDir(proc(tmpDir: string) =
      let request = AgentRunRequest(
        prompt: "Write code.",
        workingDir: tmpDir,
        model: "claude-opus-4-6",
      )
      expect ValueError:
        discard runAgent(request)
    )
