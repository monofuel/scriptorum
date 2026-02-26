## Tests for the scriptorium CLI and core utilities.

import std/[unittest, os, osproc, strutils]
import scriptorium/[init, config]

proc makeTestRepo(path: string) =
  ## Create a minimal git repository at path suitable for testing.
  createDir(path)
  discard execCmdEx("git -C " & path & " init")
  discard execCmdEx("git -C " & path & " config user.email test@test.com")
  discard execCmdEx("git -C " & path & " config user.name Test")
  discard execCmdEx("git -C " & path & " commit --allow-empty -m initial")

suite "scriptorium --init":
  test "creates scriptorium/plan branch":
    let tmp = getTempDir() / "scriptorium_test_init_branch"
    makeTestRepo(tmp)
    defer: removeDir(tmp)

    runInit(tmp)

    let (_, rc) = execCmdEx("git -C " & tmp & " rev-parse --verify scriptorium/plan")
    check rc == 0

  test "plan branch contains correct folder structure":
    let tmp = getTempDir() / "scriptorium_test_init_structure"
    makeTestRepo(tmp)
    defer: removeDir(tmp)

    runInit(tmp)

    let (files, _) = execCmdEx("git -C " & tmp & " ls-tree -r --name-only scriptorium/plan")
    check "spec.md" in files
    check "areas/.gitkeep" in files
    check "tickets/open/.gitkeep" in files
    check "tickets/in-progress/.gitkeep" in files
    check "tickets/done/.gitkeep" in files
    check "decisions/.gitkeep" in files

  test "raises on already initialized workspace":
    let tmp = getTempDir() / "scriptorium_test_init_dupe"
    makeTestRepo(tmp)
    defer: removeDir(tmp)

    runInit(tmp)
    expect ValueError:
      runInit(tmp)

  test "raises on non-git directory":
    let tmp = getTempDir() / "scriptorium_test_not_a_repo"
    createDir(tmp)
    defer: removeDir(tmp)

    expect ValueError:
      runInit(tmp)

suite "config":
  test "defaults to codex-mini for both roles":
    let cfg = defaultConfig()
    check cfg.models.architect == "codex-mini"
    check cfg.models.coding == "codex-mini"

  test "loads from scriptorium.json":
    let tmp = getTempDir() / "scriptorium_test_config"
    createDir(tmp)
    defer: removeDir(tmp)
    writeFile(tmp / "scriptorium.json", """{"models":{"architect":"claude-opus-4-6","coding":"grok-code-fast-1"},"endpoints":{"local":"http://localhost:1234/v1"}}""")

    let cfg = loadConfig(tmp)
    check cfg.models.architect == "claude-opus-4-6"
    check cfg.models.coding == "grok-code-fast-1"
    check cfg.endpoints.local == "http://localhost:1234/v1"

  test "missing file returns defaults":
    let tmp = getTempDir() / "scriptorium_test_config_missing"
    createDir(tmp)
    defer: removeDir(tmp)

    let cfg = loadConfig(tmp)
    check cfg.models.architect == "codex-mini"
    check cfg.models.coding == "codex-mini"

  test "harness routing":
    check harness("claude-opus-4-6") == harnessClaudeCode
    check harness("claude-haiku-4-5") == harnessClaudeCode
    check harness("codex-mini") == harnessCodex
    check harness("gpt-4o") == harnessCodex
    check harness("grok-code-fast-1") == harnessTypoi
    check harness("local/qwen3.5-35b-a3b") == harnessTypoi
