# Agents

Hive provides a multi-agent system where each agent has a specific role, tool set, and system prompt.

## Primary Agents

### Build

The default agent. Designed for implementation work — editing files, running commands, fixing errors, and writing code.

**Tools available:** `cmd_runner`, `get_diagnostics`, `task` (subagent delegation), `consult`, `ask_user`, `prune`, `todowrite`, `todoread`, `list_directory`, `skill`, `swarm`

### Plan

Architecture and planning agent. Helps think through design decisions, break down tasks, and create implementation plans before coding.

**Tools available:** `consult`, `task` (read-only subagents), `todowrite`, `todoread`

## Switching Agents

| Keymap | Action |
|--------|--------|
| `]o` | Select agent from list |
| `<Tab>` | Cycle to next agent |
| `gA` / `]a` | Toggle agent manager sidebar |

When you switch agents, the previous agent's tools are removed and the new agent's tools are loaded. The chat context is preserved.

## Agent Manager

Press `gA` or `]a` to open the agent manager sidebar. It shows all active chats grouped by agent, with subagent relationships.

| Key | Action |
|-----|--------|
| `j` / `k` | Navigate |
| `<CR>` | Open selected chat |
| `x` | Close selected chat |
| `f` | Toggle fold |
| `R` | Refresh |
| `q` | Close sidebar |

## Subagents

Primary agents can delegate work to subagents using the `task` tool. Subagents run in their own chat context with focused tools and return results when complete.

### Subagent Types

| Type | Purpose | Tools |
|------|---------|-------|
| **explorer** | Fast codebase exploration | `read_file`, `grep_search`, `file_search`, `list_directory` |
| **analyzer** | Code analysis and diagnostics | `read_file`, `grep_search`, `get_diagnostics`, `file_search` |
| **general** | Multi-step research | `read_file`, `grep_search`, `cmd_runner`, `file_search`, `list_directory` |

Subagents can run in parallel — spawn multiple explorers to search different parts of your codebase simultaneously.

### Navigation

| Keymap | Action |
|--------|--------|
| `]s` | Next subagent |
| `[s` | Previous subagent |
| `]p` | Parent agent |
| `]S` / `]l` | List all subagents |

See [Subagents](/guide/subagents) for details.

## Advisors

The `consult` tool lets agents get expert opinions from specialist advisors:

| Advisor | Expertise |
|---------|-----------|
| **sage** | Architecture, strategy, complex decisions |
| **reviewer** | Code review, correctness, maintainability |
| **security** | Vulnerabilities, auth, data protection |
| **performance** | Bottlenecks, scaling, optimization |

Advisors read relevant files and provide informed guidance without making changes.

## Custom Agents

See [Custom Agents](/guide/custom-agents) for creating your own agents.
