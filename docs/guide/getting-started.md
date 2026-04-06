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

Using built-in `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({
  "https://github.com/olimorris/codecompanion.nvim",
  "https://github.com/bassamsdata/hive.nvim",
})

require("codecompanion").setup({
  extensions = {
    hive = {
      enabled = true,
      opts = {
        -- your hive config here
      },
    },
  },
})
```

Hive loads automatically through CodeCompanion's extension system. No separate `setup()` call needed.

## Verify Installation

Open Neovim and run:

```vim
:Hive status
```

This should show the current agent state and configuration.

Then open a chat and verify agent switching:

```vim
:CodeCompanionChat
:Hive list
```

If Hive is active, `:Hive list` should show the built-in agents and `:Hive status` should report the current runtime state.

## Beta Behavior

Hive's delegation features are currently in beta.

- Swarms should not be started automatically unless you explicitly ask for them
- If you want a direct, single-agent workflow, just keep working in the current chat without delegation

## Your First Agent Session

1. Open a CodeCompanion chat with `:CodeCompanionChat`
2. Run `:Hive agent build` to activate the build agent in the current chat, or `:Hive! agent build` to open a new build-agent chat directly
3. Use `<Tab>` to cycle agents or `]o` to switch explicitly
4. Run `:Hive status` if you want to confirm the active agent, current state, and model configuration
5. Press `]?` to see all available keymaps

## Agent Workflow

A typical workflow looks like:

1. **Plan agent** — Describe what you want to build. The plan agent helps you think through architecture and approach
2. **Build agent** — Switch to build and let it implement. It can read files, run commands, edit code, and delegate when needed
3. **Subagents** — If you explicitly ask for parallel exploration or analysis, the build agent can spawn focused subagents to help
4. **Advisors** — When the agent faces complex decisions, it can consult specialist advisors such as `sage`, `reviewer`, `security`, or `performance`

## Next Steps

- [Agents](/guide/agents) — Understand the agent system
- [Tools](/guide/tools) — See what tools are available
- [Context Lifecycle](/guide/context-lifecycle) — How long sessions are managed
- [Configuration](/reference/config) — Customize everything
