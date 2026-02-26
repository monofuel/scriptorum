import
  std/[os, strformat, strutils],
  ./scriptorium/[init, orchestrator]

const
  Version = "0.1.0"
  Usage = """scriptorium - agent orchestration system

Usage:
  scriptorium --init [path]    Initialize a new scriptorium workspace
  scriptorium run              Start the orchestrator daemon
  scriptorium status           Show ticket counts and agent activity
  scriptorium plan <prompt>    Ask the Architect to revise spec.md
  scriptorium worktrees        List active git worktrees and their tickets
  scriptorium --version        Print version
  scriptorium --help           Show this help"""
  WorktreesHeader = "WORKTREE\tTICKET\tBRANCH"

proc cmdInit(path: string) =
  ## Initialize a new scriptorium workspace at the given path.
  runInit(path)

proc cmdRun() =
  ## Start the orchestrator daemon.
  runOrchestrator(getCurrentDir())

proc cmdStatus() =
  ## Show ticket counts and current agent activity.
  let status = readOrchestratorStatus(getCurrentDir())
  echo fmt"Open: {status.openTickets}"
  echo fmt"In Progress: {status.inProgressTickets}"
  echo fmt"Done: {status.doneTickets}"
  if status.activeTicketId.len == 0:
    echo "Active Agent: none"
  else:
    echo fmt"Active Agent Ticket: {status.activeTicketId} ({status.activeTicketPath})"
    echo fmt"Active Agent Branch: {status.activeTicketBranch}"
    if status.activeTicketWorktree.len > 0:
      echo fmt"Active Agent Worktree: {status.activeTicketWorktree}"
    else:
      echo "Active Agent Worktree: unknown"

proc cmdPlan(args: seq[string]) =
  ## Ask the architect model to revise spec.md using a prompt.
  if args.len == 0:
    raise newException(ValueError, "plan prompt is required")
  let prompt = args.join(" ").strip()
  let changed = updateSpecFromArchitect(getCurrentDir(), prompt)
  if changed:
    echo "scriptorium: updated spec.md on scriptorium/plan"
  else:
    echo "scriptorium: spec.md unchanged"

proc cmdWorktrees() =
  ## List active git worktrees and which tickets they belong to.
  let worktrees = listActiveTicketWorktrees(getCurrentDir())
  if worktrees.len == 0:
    echo "scriptorium: no active ticket worktrees"
  else:
    echo WorktreesHeader
    for item in worktrees:
      echo item.worktree & "\t" & item.ticketId & "\t" & item.branch

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
    let planArgs = if args.len > 1: args[1..^1] else: @[]
    cmdPlan(planArgs)
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
