## Integration tests for running the real codex binary.

import
  std/[os, strutils, tempfiles, unittest],
  scriptorium/harness_codex

const
  DefaultIntegrationModel = "gpt-5.1-codex-mini"

proc integrationModel(): string =
  ## Return the configured integration model, or the default model.
  result = getEnv("CODEX_INTEGRATION_MODEL", DefaultIntegrationModel)

suite "integration codex harness":
  test "real codex exec one-shot smoke test":
    let hasApiKey = getEnv("OPENAI_API_KEY", "").len > 0 or getEnv("CODEX_API_KEY", "").len > 0
    let codexPath = findExe("codex")
    doAssert codexPath.len > 0, "codex binary is required for integration tests"
    doAssert hasApiKey, "OPENAI_API_KEY or CODEX_API_KEY is required for integration tests"

    let tmpDir = createTempDir("scriptorium_integration_codex_", "", getTempDir())
    defer:
      removeDir(tmpDir)

    let worktreePath = tmpDir / "worktree"
    createDir(worktreePath)
    let request = CodexRunRequest(
      prompt: "Reply with exactly: ok",
      workingDir: worktreePath,
      model: integrationModel(),
      ticketId: "integration-smoke",
      skipGitRepoCheck: true,
      logRoot: tmpDir / "logs",
      hardTimeoutMs: 180_000,
      noOutputTimeoutMs: 60_000,
    )

    let runResult = runCodex(request)
    doAssert runResult.exitCode == 0,
      "codex exec failed with non-zero exit code.\n" &
      "Model: " & integrationModel() & "\n" &
      "Command: " & runResult.command.join(" ") & "\n" &
      "Stdout:\n" & runResult.stdout
    doAssert runResult.lastMessage.strip().len > 0,
      "codex did not produce a last message.\n" &
      "Last message file: " & runResult.lastMessageFile & "\n" &
      "Stdout:\n" & runResult.stdout
    check fileExists(runResult.logFile)
    check fileExists(runResult.lastMessageFile)
