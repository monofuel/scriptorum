import std/[os, osproc, streams, strformat, strutils]

const
  PlanBranch = "sanctum/plan"
  SpecPlaceholder = "# Spec\n\nRun `sanctum plan` to build your spec with the Architect.\n"
  PlanDirs = [
    "areas",
    "tickets/open",
    "tickets/in-progress",
    "tickets/done",
    "decisions",
  ]

proc gitRun(dir: string, args: varargs[string]) =
  ## Run a git subcommand in dir, raising IOError on non-zero exit.
  let argsSeq = @args
  let allArgs = @["-C", dir] & argsSeq
  let p = startProcess("git", args = allArgs, options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  if rc != 0:
    let argsStr = argsSeq.join(" ")
    raise newException(IOError, fmt"git {argsStr} failed: {output.strip()}")

proc gitCheck(dir: string, args: varargs[string]): int =
  ## Run a git subcommand in dir, returning exit code and discarding output.
  let allArgs = @["-C", dir] & @args
  let p = startProcess("git", args = allArgs, options = {poUsePath, poStdErrToStdOut})
  discard p.outputStream.readAll()
  result = p.waitForExit()
  p.close()

proc runInit*(path: string) =
  ## Initialize a new sanctum workspace in the given git repository.
  let target = if path.len > 0: absolutePath(path) else: getCurrentDir()

  if gitCheck(target, "rev-parse", "--git-dir") != 0:
    raise newException(ValueError, fmt"{target} is not a git repository")

  if gitCheck(target, "rev-parse", "--verify", PlanBranch) == 0:
    raise newException(ValueError, "workspace already initialized (sanctum/plan branch exists)")

  let tmpPlan = getTempDir() / "sanctum_plan_init"
  if dirExists(tmpPlan):
    removeDir(tmpPlan)

  gitRun(target, "worktree", "add", "--orphan", "-b", PlanBranch, tmpPlan)
  defer:
    discard execCmdEx(
      "git -C " & quoteShell(target) & " worktree remove --force " & quoteShell(tmpPlan)
    )

  for d in PlanDirs:
    createDir(tmpPlan / d)
    writeFile(tmpPlan / d / ".gitkeep", "")
  writeFile(tmpPlan / "spec.md", SpecPlaceholder)

  gitRun(tmpPlan, "add", ".")
  gitRun(tmpPlan, "commit", "-m", "sanctum: initialize plan branch")

  echo "Initialized sanctum workspace."
  echo fmt"  Plan branch: {PlanBranch}"
  echo ""
  echo "Next steps:"
  echo "  sanctum plan   — build your spec with the Architect"
  echo "  sanctum run    — start the orchestrator"
