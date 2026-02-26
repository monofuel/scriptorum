## Tests for the sanctum CLI and core utilities.

import std/[unittest, os, osproc, strutils]
import sanctum/[init]

proc makeTestRepo(path: string) =
  ## Create a minimal git repository at path suitable for testing.
  createDir(path)
  discard execCmdEx("git -C " & path & " init")
  discard execCmdEx("git -C " & path & " config user.email test@test.com")
  discard execCmdEx("git -C " & path & " config user.name Test")
  discard execCmdEx("git -C " & path & " commit --allow-empty -m initial")

suite "sanctum --init":
  test "creates sanctum/plan branch":
    let tmp = getTempDir() / "sanctum_test_init_branch"
    makeTestRepo(tmp)
    defer: removeDir(tmp)

    runInit(tmp)

    let (_, rc) = execCmdEx("git -C " & tmp & " rev-parse --verify sanctum/plan")
    check rc == 0

  test "plan branch contains correct folder structure":
    let tmp = getTempDir() / "sanctum_test_init_structure"
    makeTestRepo(tmp)
    defer: removeDir(tmp)

    runInit(tmp)

    let (files, _) = execCmdEx("git -C " & tmp & " ls-tree -r --name-only sanctum/plan")
    check "spec.md" in files
    check "areas/.gitkeep" in files
    check "tickets/open/.gitkeep" in files
    check "tickets/in-progress/.gitkeep" in files
    check "tickets/done/.gitkeep" in files
    check "decisions/.gitkeep" in files

  test "raises on already initialized workspace":
    let tmp = getTempDir() / "sanctum_test_init_dupe"
    makeTestRepo(tmp)
    defer: removeDir(tmp)

    runInit(tmp)
    expect ValueError:
      runInit(tmp)

  test "raises on non-git directory":
    let tmp = getTempDir() / "sanctum_test_not_a_repo"
    createDir(tmp)
    defer: removeDir(tmp)

    expect ValueError:
      runInit(tmp)
