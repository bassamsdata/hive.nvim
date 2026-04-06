# Hive.nvim

Extension plugin for [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim) that adds a multi-agent system with parallel subagent orchestration, context lifecycle management, and extended tooling — designed for long, autonomous coding workflows.

Requires Neovim >= 0.11 and a working codecompanion.nvim installation.

## Features

- **Multi-agent system** — role-based agents (build, plan) with tool isolation, parallel subagent delegation, and expert advisor consultations
- **Context lifecycle** — automatic context window management with nudge, compaction, and reset layers to sustain long-running sessions
- **Extended tools** — diagnostics, task delegation, consult, ask_user, command runner, pruning, todo tracking, directory listing, skills, and swarm orchestration
- **Extra adapters** — Groq, Cerebras, OpenRouter
- **Spinner and notifications** for long-running operations

## Installation

Using `lazy.nvim`:

```lua
{
  "olimorris/codecompanion.nvim",
  dependencies = {
    "bassamsdata/hive.nvim",
  },
}
```

Using built-in `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({
  "https://github.com/olimorris/codecompanion.nvim",
  "https://github.com/bassamsdata/hive.nvim",
})
```

For either installation method, enable Hive in your CodeCompanion setup:

```lua
require("codecompanion").setup({
  extensions = {
    hive = {
      enabled = true,
      opts = {
        -- your config overrides here
      },
    },
  },
})
```

## Agents

The agent system provides structured tool access through named agents. Each agent defines which tools are available, what actions are permitted, and carries its own system prompt.

### Primary Agents

These are the agents you interact with directly in the chat buffer.

**build** -- Autonomous coding agent with full tool access. Can read, write, and delete files, run shell commands, spawn subagents, and consult advisors. This is the default agent for implementation work.

**plan** -- Read-only research agent. Can explore the codebase and delegate to subagents but cannot modify files or run commands. Use it for analysis, planning, and investigation before committing to changes.

Switch between agents with `]o` (select) or `<Tab>` (cycle).

### Subagents

Subagents are fire-and-forget workers spawned by the primary agent through the task tool. They run in isolated chat sessions, complete their work, and return results to the parent. The user can navigate to subagent chats to inspect their progress.

**explorer** -- Fast codebase exploration. Read-only. Uses file search, grep, directory listing, and file reading in parallel.

**general** -- Multi-step research with command execution. Can run shell commands for information gathering (git log, test output) but cannot modify files.

**analyzer** -- Code analysis and diagnostics. Runs LSP diagnostics, reads code, and produces structured reports on errors, warnings, and code quality.

Subagents can run in parallel. The parent agent can spawn multiple subagents simultaneously and receive consolidated results.

### Advisors

Advisors are specialized subagents spawned through the consult tool. They provide expert opinions and return to the parent with recommendations.

**sage** -- Strategic and architectural guidance. For complex decisions, unfamiliar patterns, or when you need a second opinion.

**reviewer** -- Code review. Gets feedback on correctness, maintainability, and patterns after completing implementation.

**security** -- Security analysis. For authentication, authorization, input validation, and data protection concerns.

**performance** -- Performance optimization. For bottlenecks, scaling decisions, and efficiency improvements.

### Custom Agents via Markdown

Define custom agents as markdown files with YAML frontmatter. Place them in `.codecompanion/agents/` in your project root, or in `~/.config/nvim/codecompanion/agents/` for global agents.

```markdown
---
name: my-agent
type: subagent
description: Custom subagent for specific tasks
tools:
  - read_file
  - grep_search
  - file_search
permissions:
  can_spawn_subagents: false
  can_edit_files: false
  can_run_commands: false
opts:
  include_default_system_prompt: false
  include_tools_system_prompt: true
  hidden: true
  auto_submit_errors: true
  auto_submit_success: true
---

Your system prompt goes here as markdown content.
```

### Model Configuration

Subagents and advisors can use different models from the parent chat. Configure small (for subagents) and big (for advisors) models:

```lua
agents = {
  small_model = "copilot/gpt-4.1",        -- for explorer, general, analyzer
  big_model = "copilot/claude-sonnet-4",   -- for sage, reviewer, security, performance
}
```

Override at runtime with `vim.g.EXTRA_SMALL_MODEL` and `vim.g.EXTRA_BIG_MODEL`, or interactively via the model picker keymap.

Expensive models (e.g., `claude-opus*`) trigger a confirmation dialog before spawning subagents. Configure patterns:

```lua
agents = {
  confirm_expensive_models = { "claude-opus*", "gpt-5*" },
}
```

## Tools

### get_diagnostics

Retrieves LSP diagnostics (errors, warnings, info, hints) from any file. Works in the background with the LSP servers -- it does not open buffers in the editor or load files into the LSP beyond what is needed for diagnostics. This keeps the LSP server's memory footprint unchanged.

### cmd_runner

Enhanced shell command runner built on top of codecompanion's builtin. Adds:

- **Timeout**: configurable per-command timeout (default 60s) with a visible countdown timer
- **Safety classification**: commands matching dangerous patterns (recursive deletion, system modification) require explicit user approval
- **Allow/block lists**: `auto_allow_patterns` for commands that run without approval, `always_confirm_patterns` for commands that always require confirmation

```lua
tools = {
  cmd_runner = {
    opts = {
      timeout = 60,
      auto_allow_patterns = { "make *", "npm test*" },
      always_confirm_patterns = { "rm *", "docker *" },
    },
  },
}
```

### task

Delegates work to specialized subagents. Supports single or parallel execution. The parent agent waits for all subagents to complete and receives consolidated results. Real-time status updates appear in the chat buffer showing which subagents are running, their tool usage, and elapsed time.

### consult

Spawns advisor subagents for expert guidance. Unlike task delegation (for work completion), consult is for getting opinions and recommendations. Supports follow-up questions to an existing consultation.

### ask_user

Interactive question forms rendered in a floating window. Supports free-text input, single-choice, and multi-choice questions. The agent uses this when it needs clarification before proceeding.

### prune

Context management tool. Removes tool outputs from the conversation to free up context window space. Works with the context lifecycle system to surface prunable outputs and their token costs.

### todowrite / todoread

Task tracking during complex operations. The agent creates and updates a task list that appears in a floating viewer or a persistent split below the chat buffer. Only the build agent can write; subagents can read.

### list_directory

Lists directory contents with type indicators (directories, symlinks, regular files). Supports depth control, hidden files, and pattern filtering.

### skill

Loads specialized skill instructions from markdown files in the project. Skills provide domain-specific knowledge for specific task types.

### swarm

Orchestrates multiple persistent worker agents operating in parallel on a shared task queue. Workers claim tasks, coordinate via messages, and use file locking to avoid conflicts. Use for large multi-file operations that benefit from autonomous parallel execution.

<!-- Screenshot: swarm workers operating in parallel -->

## Context Lifecycle

Manages context window utilization across three layers:

1. **Nudge (50-60%)** -- injects messages encouraging the LLM to prune tool outputs it no longer needs
2. **Compaction (75%)** -- automatically summarizes conversation history and rebuilds messages to free space
3. **Reset (90%)** -- aggressive compaction to prevent context overflow

The system tracks token usage, detects when thresholds are crossed, and acts automatically. A prunable-tools list is injected into the conversation showing which tool outputs can be pruned and their estimated token cost.

To disable the entire context lifecycle system:

```lua
modules = {
  context_lifecycle = { enabled = false },
}
```

To keep compaction but disable nudges, set the nudge thresholds above 100:

```lua
context_lifecycle = {
  nudge_start = 101,
  nudge_strong = 101,
}
```

## Adapters

Three additional HTTP adapters:

- **Groq** -- fast inference for supported models
- **Cerebras** -- fast inference for supported models
- **OpenRouter** -- access to multiple providers through a single API

## Keymaps

All keymaps are configurable through `agents.keymap` in the config. The default prefix is `]`. Press `]?` in any chat buffer to see the full keymap reference.

| Keymap | Description |
|--------|-------------|
| `]o` / `]A` | Switch agent (select) |
| `<Tab>` | Cycle to next agent |
| `gA` / `]a` | Toggle agent manager sidebar |
| `]s` | Next subagent |
| `[s` | Previous subagent |
| `]p` | Parent agent |
| `]S` / `]l` | List subagents |
| `]T` | View task list (floating) |
| `]t` | Toggle task list (split) |
| `gH` / `]q` | Toggle ask_user form |
| `gm` / `]m` | Set subagent model |
| `gP` / `]P` | View prunable context |
| `]?` | Keymap help |

## Configuration

Full default configuration:

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
    definitions = {},
    model_prompts = {},
    load_from_dir = nil,
    load_cwd_agents = true,
  },

  tools = {
    cmd_runner = {
      enabled = true,
      opts = {
        timeout = 60,
        auto_allow_patterns = {},
        always_confirm_patterns = {},
      },
    },
  },

  context_lifecycle = {
    enabled = true,
    context_window_tokens = nil,
    nudge_start = 50,
    nudge_strong = 60,
    compact_threshold = 75,
    reset_threshold = 90,
    min_messages = 4,
    notify = true,
    compaction = {
      recent_budget = 20000,
      preserve_last_assistant = true,
    },
  },

  skills = {
    enabled = true,
    directories = {},
    scan_to_git_root = true,
    recursive = false,
  },
}
```

See `lua/codecompanion-extra/config.lua` for the complete configuration reference with all options.

To override a single keymap, set only the entry you want to change:

```lua
agents = {
  keymap = {
    agent_switch = { modes = { n = "<leader>as" } },
  },
}
```

To change the prefix, set `prefix` and all prefix-derived keymaps update automatically:

```lua
agents = {
  keymap = {
    prefix = "s", -- ]s becomes ss, ]t becomes st, etc.
  },
}
```

<!-- ## Screenshots -->

<!-- Screenshot: agent switching -->
<!-- Screenshot: subagent status in chat -->
<!-- Screenshot: task list split viewer -->
<!-- Screenshot: prunable context viewer -->
<!-- Screenshot: consult advisor session -->
<!-- Video: full workflow demo -->
