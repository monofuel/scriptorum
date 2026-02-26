import std/[os, strformat]
import ./scriptorium/[init, orchestrator]

const
  Version = "0.1.0"
  Usage = """scriptorium - agent orchestration system

Usage:
  scriptorium --init [path]    Initialize a new scriptorium workspace
  scriptorium run              Start the orchestrator daemon
  scriptorium status           Show ticket counts and agent activity
  scriptorium plan             Conversation with the Architect to build or revise spec.md
  scriptorium worktrees        List active git worktrees and their tickets
  scriptorium --version        Print version
  scriptorium --help           Show this help"""

proc cmdInit(path: string) =
  ## Initialize a new scriptorium workspace at the given path.
  runInit(path)

proc cmdRun() =
  ## Start the orchestrator daemon.
  runOrchestrator(getCurrentDir())

proc cmdStatus() =
  ## Show ticket counts and current agent activity.
  echo "scriptorium: status not yet implemented"
  quit(1)

proc cmdPlan() =
  ## Open an interactive conversation with the Architect to build or revise spec.md.
  echo "scriptorium: plan not yet implemented"
  quit(1)

proc cmdWorktrees() =
  ## List active git worktrees and which tickets they belong to.
  echo "scriptorium: worktrees not yet implemented"
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
    echo fmt"scriptorium: unknown command '{args[0]}'"
    echo Usage
    quit(1)
