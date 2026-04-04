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
    model = {
      small = nil,  -- auto-detected from adapter
      big = nil,    -- auto-detected from adapter
    },
    confirm_expensive_model = true,
  },

  tools = {
    cmd_runner = { enabled = true },
    get_diagnostics = { enabled = true },
    task = { enabled = true },
    consult = { enabled = true },
    ask_user = { enabled = true },
    prune = { enabled = true },
    todo = { enabled = true },
    list_directory = { enabled = true },
    skill = { enabled = true },
    swarm = { enabled = true },
  },

  context_lifecycle = {
    enabled = true,
    nudge = {
      start_percent = 50,
      end_percent = 60,
    },
    compact = {
      threshold_percent = 75,
    },
    reset = {
      threshold_percent = 90,
    },
  },

  spinner = { enabled = true },
  notify = { enabled = true },
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
vim.g.HIVE_SMALL_MODEL = "claude-sonnet-4-20250514"
vim.g.HIVE_BIG_MODEL = "claude-opus-4-20250514"
```

Or at runtime:

```vim
:Hive model small claude-sonnet-4-20250514
:Hive model big claude-opus-4-20250514
```

## Disabling Features

Disable individual tools or modules:

```lua
{
  tools = {
    swarm = { enabled = false },
  },
  spinner = { enabled = false },
  context_lifecycle = { enabled = false },
}
```

## Full Reference

See [`lua/hive/config.lua`](https://github.com/bassamsdata/hive.nvim/blob/main/lua/hive/config.lua) for the complete configuration with all options and type annotations.
