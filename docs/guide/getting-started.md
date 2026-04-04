# Getting Started

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "olimorris/codecompanion.nvim",
  dependencies = {
    "bassamsdata/hive.nvim",
  },
  opts = {
    extensions = {
      hive = {
        enabled = true,
        opts = {
          -- your hive config here
        },
      },
    },
  },
}
```

Hive loads automatically through CodeCompanion's extension system. No separate `setup()` call needed.

## Verify Installation

Open Neovim and run:

```vim
:Hive status
```

This should show the current agent state and configuration.

## Your First Agent Session

1. Open a CodeCompanion chat (`:CodeCompanion`)
2. The **build** agent activates by default — it has access to file editing, command running, diagnostics, and more
3. Press `]o` to switch agents, or `<Tab>` to cycle between them
4. Press `]?` to see all available keymaps

## Agent Workflow

A typical workflow looks like:

1. **Plan agent** — Describe what you want to build. The plan agent helps you think through architecture and approach
2. **Build agent** — Switch to build and let it implement. It can read files, run commands, edit code, and delegate to subagents for exploration
3. **Subagents** — The build agent can spawn parallel subagents to explore your codebase, analyze code, or research across multiple files simultaneously
4. **Advisors** — When the agent faces complex decisions, it can consult specialist advisors (sage for architecture, reviewer for code review, security, performance)

## Next Steps

- [Agents](/guide/agents) — Understand the agent system
- [Tools](/guide/tools) — See what tools are available
- [Context Lifecycle](/guide/context-lifecycle) — How long sessions are managed
- [Configuration](/reference/config) — Customize everything
