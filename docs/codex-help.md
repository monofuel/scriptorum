Codex CLI

Usage: codex [OPTIONS] [PROMPT]
       codex [OPTIONS] <COMMAND> [ARGS]

Commands:
  exec        Run Codex non-interactively [aliases: e]
  review      Run a code review non-interactively
  login       Manage login
  logout      Remove stored authentication credentials
  mcp         Manage external MCP servers for Codex
  mcp-server  Start Codex as an MCP server (stdio)
  app-server  [experimental] Run the app server or related tooling
  completion  Generate shell completion scripts
  sandbox     Run commands within a Codex-provided sandbox
  debug       Debugging tools
  apply       Apply the latest diff produced by Codex agent as a `git apply` to your local working tree [aliases: a]
  resume      Resume a previous interactive session (picker by default; use --last to continue the most recent)
  fork        Fork a previous interactive session (picker by default; use --last to fork the most recent)
  cloud       [EXPERIMENTAL] Browse tasks from Codex Cloud and apply changes locally
  features    Inspect feature flags
  help        Print this message or the help of the given subcommand(s)

Arguments:
  [PROMPT]  Optional user prompt to start the session

Options:
  -c, --config <key=value>                        Override a configuration value that would otherwise be loaded from `~/.codex/config.toml`. Use a dotted path (`foo.bar.baz`) to override nested values.
                                                  The `value` portion is parsed as TOML. If it fails to parse as TOML, the raw string is used as a literal
      --enable <FEATURE>                          Enable a feature (repeatable). Equivalent to `-c features.<name>=true`
      --disable <FEATURE>                         Disable a feature (repeatable). Equivalent to `-c features.<name>=false`
  -i, --image <FILE>...                           Optional image(s) to attach to the initial prompt
  -m, --model <MODEL>                             Model the agent should use
      --oss                                       Convenience flag to select the local open source model provider. Equivalent to -c model_provider=oss; verifies a local LM Studio or Ollama server is
                                                  running
      --local-provider <OSS_PROVIDER>             Specify which local provider to use (lmstudio or ollama). If not specified with --oss, will use config default or show selection
  -p, --profile <CONFIG_PROFILE>                  Configuration profile from config.toml to specify default options
  -s, --sandbox <SANDBOX_MODE>                    Select the sandbox policy to use when executing model-generated shell commands [possible values: read-only, workspace-write, danger-full-access]
  -a, --ask-for-approval <APPROVAL_POLICY>        Configure when the model requires human approval before executing a command [possible values: untrusted, on-failure, on-request, never]
      --full-auto                                 Convenience alias for low-friction sandboxed automatic execution (-a on-request, --sandbox workspace-write)
      --dangerously-bypass-approvals-and-sandbox  Skip all confirmation prompts and execute commands without sandboxing. EXTREMELY DANGEROUS. Intended solely for running in environments that are
                                                  externally sandboxed
  -C, --cd <DIR>                                  Tell the agent to use the specified directory as its working root
      --search                                    Enable live web search. When enabled, the native Responses `web_search` tool is available to the model (no per‑call approval)
      --add-dir <DIR>                             Additional directories that should be writable alongside the primary workspace
      --no-alt-screen                             Disable alternate screen mode
  -h, --help                                      Print help (see more with '--help')
  -V, --version                                   Print version
