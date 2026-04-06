# Configuration

Hive is configured through CodeCompanion's extension system:

```lua
{
  "olimorris/codecompanion.nvim",
  dependencies = { "bassamsdata/hive.nvim" },
  opts = {
    extensions = {
      hive = {
        enabled = true,
        opts = {
          -- All configuration goes here
        },
      },
    },
  },
}
```

## Full Default Configuration

```lua
{
  modules = {
    spinner = { enabled = true },
    notify = { enabled = true },
    adapters = { enabled = true },
    tools = { enabled = true },
    agents = { enabled = true },
    skills = { enabled = true },
    context_pruning = { enabled = false },
    context_lifecycle = { enabled = true },
    twinchat = { enabled = false },
  },

  agents = {
    keymap = {
      prefix = "]",
      agent_switch = { modes = { n = { "]o", "]A" } }, desc = "Switch agent" },
      agent_cycle = { modes = { n = "<Tab>" }, desc = "Cycle to next agent" },
      agent_manager = { modes = { n = { "gA", "]a" } }, desc = "Toggle agent manager" },
      next_subagent = { modes = { n = "]s" }, desc = "Next subagent" },
      prev_subagent = { modes = { n = "[s" }, desc = "Previous subagent" },
      parent_agent = { modes = { n = "]p" }, desc = "Parent agent" },
      list_subagents = { modes = { n = { "]S", "]l" } }, desc = "List subagents" },
      todo_viewer = { modes = { n = "]T" }, desc = "View task list" },
      todo_split = { modes = { n = "]t" }, desc = "Toggle split task list" },
      toggle_ask_user = { modes = { n = { "gH", "]q" } }, desc = "Toggle ask_user form" },
      subagent_model = { modes = { n = { "gm", "]m" } }, desc = "Set subagent model" },
      prunable_viewer = { modes = { n = { "gP", "]P" } }, desc = "Show prunable context" },
      hive_keymap_help = { modes = { n = "]?" }, desc = "Hive keymap reference" },
    },
    small_model = nil,
    big_model = nil,
    confirm_expensive_models = { "claude-opus*" },
  },

  tools = {
    cmd_runner = { enabled = true },
    get_diagnostics = { enabled = true },
    task = { enabled = true },
    consult = { enabled = true },
    ask_user = { enabled = true },
    skill = { enabled = true },
    list_directory = { enabled = true },
    grep_search = { enabled = true },
    prune = { enabled = true },
    todowrite = { enabled = true },
    todoread = { enabled = true },
    swarm = { enabled = true },
  },

  context_lifecycle = {
    enabled = true,
    nudge_start = 50,
    nudge_strong = 60,
    compact_threshold = 75,
    reset_threshold = 90,
  },
}
```

## Overriding Keymaps

Override a single keymap:

```lua
agents = {
  keymap = {
    agent_switch = { modes = { n = "<leader>as" } },
  },
}
```

Change the prefix — all prefix-derived keymaps update automatically:

```lua
agents = {
  keymap = {
    prefix = "s", -- ]s becomes ss, ]t becomes st, etc.
  },
}
```

## Model Configuration

Override models globally:

```lua
vim.g.HIVE_SMALL_MODEL = "openai/gpt-4.1-mini"
vim.g.HIVE_BIG_MODEL = "openai/o3"
```

Or at runtime:

```vim
:Hive model small openai/gpt-4.1-mini
:Hive model big openai/o3
```

## Disabling Features

Disable individual tools or modules:

```lua
{
  modules = {
    context_lifecycle = { enabled = false },
  },
  tools = {
    swarm = { enabled = false },
  },
  spinner = {
    window = { enabled = false },
  },
}
```

## Full Reference

See [`lua/hive/config.lua`](https://github.com/bassamsdata/hive.nvim/blob/main/lua/hive/config.lua) for the complete configuration with all options and type annotations.
