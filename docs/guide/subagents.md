# Subagents

Subagents are child agents spawned by a primary agent to handle focused tasks in parallel. They run in their own chat context, complete their work, and return results to the parent.

## How Subagents Work

1. The user explicitly asks for subagents, delegation, or parallel exploration
2. It calls the `task` tool with one or more subagent definitions
3. Each subagent gets its own chat buffer with focused tools
4. Subagents work independently (and in parallel if multiple)
5. Results are returned to the parent agent when complete

## Beta Note

Subagent spawning is currently beta behavior.

- Hive should not spawn subagents automatically just because delegation seems helpful
- Subagents should only be started when the user explicitly asks for them
- If the user has not asked for delegation, the agent should continue in the current chat

## Subagent Types

### Explorer

Fast, read-only codebase exploration. Use when you need to find files, search code, or understand project structure.

**Tools:** `read_file`, `grep_search`, `file_search`, `list_directory`

### Analyzer

Code analysis and diagnostics. Use for finding issues, checking errors, or analyzing patterns.

**Tools:** `read_file`, `grep_search`, `get_diagnostics`, `file_search`, `list_directory`

### General

Multi-step research that may need command execution. The most capable subagent type.

**Tools:** `read_file`, `grep_search`, `cmd_runner`, `file_search`, `list_directory`

## Parallel Execution

The primary agent can spawn multiple subagents simultaneously:

```
Parent Agent
├── Explorer: "Find all auth-related files"
├── Analyzer: "Check for type errors in src/"
└── General: "Run the test suite and summarize failures"
```

All three run in parallel. The parent waits for all to complete and receives consolidated results.

## Navigation

Navigate between parent and subagent chat buffers:

| Keymap | Action |
|--------|--------|
| `]s` | Jump to next subagent |
| `[s` | Jump to previous subagent |
| `]p` | Jump back to parent |
| `]S` / `]l` | List all subagents (select from list) |

## Model Configuration

By default, subagents use the configured `small_model` when set. If no subagent override is configured, they inherit from the parent chat.

Override models at runtime:

```vim
:Hive model small openai/gpt-4.1-mini
:Hive model big openai/o3
```

Or press `gm` / `]m` in a chat buffer to set the subagent model interactively.

Persistent overrides via environment-style globals:

```lua
vim.g.HIVE_SMALL_MODEL = "openai/gpt-4.1-mini"
vim.g.HIVE_BIG_MODEL = "openai/o3"
```
