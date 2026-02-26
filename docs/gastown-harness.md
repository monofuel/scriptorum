# gastown-harness notes

- asked grok 4.2 for some notes on how gastown uses harnesses
- grok 4.2 drank way too much of the gastown cool-aid it was hard to get a direct answer

- basically, gastown uses tmux and had daemons to handle 'poking' stdin on claude/codex/whatever.
- tmux is really cool. but for scriptorium v1, I would like to try sticking simply to processes and stdin/stdout.


`````
**At the raw process level for the `claude` (or `codex`) binary:**

Gastown launches it exactly like this (simplified):

```bash
tmux new-session -d -s <session-name> -c <dedicated-work-dir>
tmux send-keys -t <session-name> "claude" Enter   # or whatever your runtime command is
```

(or equivalent Go `os/exec` + `tmux` wrapper).

The `claude` binary runs as a normal child process inside that tmux pane. Gastown does **not** hold any long-lived stdin/stdout pipe to it. Communication is:
- Files written to the work dir before launch (`.claude/settings.local.json`, mail files, task descriptions, etc.)
- Occasional `tmux send-keys` to poke it
- `tmux capture-pane` to read its output

**When the agent stops mid-task / ends the current message early:**

The `claude` process is still alive (sitting at the `❯` prompt) or has exited the current turn.  
Gastown’s background daemon polls every ~10-30s with `tmux` commands:

- `tmux list-panes -F '#{pane_current_command}'` → checks if it still says “claude” (or “node” for the Electron version)
- `tmux capture-pane -p` → looks for the ready prompt
- Plus it checks git status / files in the work dir to see if the actual task finished

If it detects “process is idle but work is unfinished”, it either:
- `tmux send-keys` a nudge (e.g. “continue” or a command), **or**
- kills the tmux pane/session and immediately does a fresh launch of `claude` in the exact same work dir after re-writing the latest task files.

New process starts, reads the files, picks up exactly where the previous one stopped. No tokens wasted re-explaining everything.

**When the harness crashes or the whole system reboots:**

Everything dies: tmux server, all `claude` processes, all sessions.

The only thing that survives is plain files on disk (the per-agent work directories + git).

After reboot you (or a startup script) just run the normal start commands again:

- Gastown re-creates every tmux session
- Re-launches a fresh `claude` binary in each work dir
- The new process reads the exact same files the old one left behind and continues

That’s literally it. No persistent daemon pipe, no magic long-running stdin, just “start fresh claude process + read files from disk”. The tmux part is only there so you can watch/attach if you want.

This is why your old one-shot scripts hung forever but this doesn’t.
When it needs to nudge a running claude (or codex) process that's gone idle mid-task:

Gastown does tmux send-keys -t <session> "continue" Enter (or similar short command).
That literally feeds keystrokes into the process's stdin exactly like you typing in the terminal.

If the nudge doesn't work or the health check sees the session as dead/zombie/stalled:

It does tmux kill-pane (or kill-session), then immediately starts a brand newclaude process in the exact same directory.

No long-lived pipe from Gastown to the process.
The process always has its own normal tty (managed by tmux). Gastown only pokes it occasionally via tmux, or just kills + restarts it.
On crash or reboot: all processes die, but the work dir files are still there, so it just does the "new process" step again on startup. Nothing else survives or needs to.
That's the entire low-level mechanism.
``````
