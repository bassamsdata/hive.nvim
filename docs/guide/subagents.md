# Subagents

Subagents are child agents spawned by a primary agent to handle focused tasks in parallel. They run in their own chat context, complete their work, and return results to the parent.

## How Subagents Work

1. The primary agent decides it needs exploration or analysis
2. It calls the `task` tool with one or more subagent definitions
3. Each subagent gets its own chat buffer with focused tools
4. Subagents work independently (and in parallel if multiple)
5. Results are returned to the parent agent when complete

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

By default, subagents use a "small" model (fast and cheap) for exploration tasks. The primary agent uses the "big" model for complex work.

Override models at runtime:

```vim
:Hive model small claude-sonnet-4-20250514
:Hive model big claude-opus-4-20250514
```

Or press `gm` / `]m` in a chat buffer to set the subagent model interactively.

Persistent overrides via environment-style globals:

```lua
vim.g.HIVE_SMALL_MODEL = "claude-sonnet-4-20250514"
vim.g.HIVE_BIG_MODEL = "claude-opus-4-20250514"
```
