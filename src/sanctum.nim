import std/[os, strformat]

const
  Version = "0.1.0"
  Usage = """sanctum - agent orchestration system

Usage:
  sanctum --init [path]    Initialize a new sanctum workspace
  sanctum run              Start the orchestrator daemon
  sanctum status           Show ticket counts and agent activity
  sanctum plan             Conversation with the Architect to build or revise spec.md
  sanctum worktrees        List active git worktrees and their tickets
  sanctum --version        Print version
  sanctum --help           Show this help"""

proc cmdInit(path: string) =
  ## Initialize a new sanctum workspace at the given path.
  let target = if path.len > 0: path else: getCurrentDir()
  echo fmt"sanctum: init not yet implemented (target: {target})"
  quit(1)

proc cmdRun() =
  ## Start the orchestrator daemon.
  echo "sanctum: run not yet implemented"
  quit(1)

proc cmdStatus() =
  ## Show ticket counts and current agent activity.
  echo "sanctum: status not yet implemented"
  quit(1)

proc cmdPlan() =
  ## Open an interactive conversation with the Architect to build or revise spec.md.
  echo "sanctum: plan not yet implemented"
  quit(1)

proc cmdWorktrees() =
  ## List active git worktrees and which tickets they belong to.
  echo "sanctum: worktrees not yet implemented"
  quit(1)

when isMainModule:
  let args = commandLineParams()

  if args.len == 0:
    echo Usage
    quit(0)

  case args[0]
  of "run":
    cmdRun()
  of "status":
    cmdStatus()
  of "plan":
    cmdPlan()
  of "worktrees":
    cmdWorktrees()
  of "--init":
    let path = if args.len > 1: args[1] else: ""
    cmdInit(path)
  of "--version":
    echo Version
  of "--help", "-h":
    echo Usage
  else:
    echo fmt"sanctum: unknown command '{args[0]}'"
    echo Usage
    quit(1)
