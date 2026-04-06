# Tools

Hive extends CodeCompanion with additional tools that agents can use during conversations.

## Available Tools

### cmd_runner

Run shell commands on the user's system. Output is shared with the user before being returned to the agent.

```
Agent: Let me check the test output
→ runs: make test
→ shows output to user
→ agent sees results
```

### get_diagnostics

Retrieve LSP diagnostics (errors, warnings, hints) from any file. Agents use this after edits to verify no issues were introduced.

### task

Delegate work to subagents. Supports single sequential tasks or multiple parallel tasks.

In the current beta, this should be used only when the user explicitly asks for subagents or parallel delegation.

```lua
-- Agent spawns parallel exploration
task({
  { type = "explorer", prompt = "Find auth files" },
  { type = "analyzer", prompt = "Check API errors" },
})
```

### consult

Get expert advice from specialist advisors (sage, reviewer, security, performance). Unlike task delegation, consult is for getting opinions, not completing work.

### ask_user

Present interactive forms to the user for clarification. Supports text input, single choice, and multi-choice questions.

| Key | Action |
|-----|--------|
| `<Tab>` / `<S-Tab>` | Next / previous question |
| `j` / `k` | Navigate choices |
| `<CR>` / `<Space>` | Select |
| `S` / `<C-s>` | Submit |
| `q` | Cancel |

### todowrite / todoread

Track progress on multi-step tasks. Agents create task lists and update them as work progresses.

| Status | Meaning |
|--------|---------|
| `pending` | Not started |
| `in_progress` | Currently working (one at a time) |
| `completed` | Done |
| `cancelled` | No longer needed |

Press `]T` to view the task list in a floating window, or `]t` to toggle a split view.

### prune

Remove tool outputs from the agent's context to free space. Used proactively to manage long sessions.

### list_directory

List directory contents with type indicators and optional depth/pattern filtering.

### skill

Load specialized instructions for specific task types. Skills provide domain-specific knowledge and workflows.

### swarm

Orchestrate multiple persistent agents working in parallel on a shared task queue. Unlike `task` (fire-and-forget subagents), swarm agents coordinate via messages and file locking.

Swarm is more powerful and more invasive than normal delegation. In the current beta, it should only be started when the user explicitly asks for a swarm.
