# Swarm Orchestration

Swarm is a multi-agent system where persistent worker agents claim tasks from a shared queue, coordinate via messages, and use file locking to avoid conflicts.

## Beta Note

Swarm is currently a beta workflow.

- It should not start automatically unless the user explicitly asks for a swarm
- Prefer normal single-agent work or targeted subagents unless the user clearly wants coordinated parallel execution
- Use swarm when the user wants deliberate multi-agent orchestration, not just because it might be helpful

## When to Use Swarm

Use swarm instead of regular subagents when:

- Multiple files need editing simultaneously by different specialists
- Tasks have dependencies (task B depends on task A)
- Work requires coordination between agents
- The workload has 3+ distinct tasks that map to different expertise areas

For simple parallel reads/analysis, use the `task` tool instead.

## How It Works

1. The primary agent defines agents and tasks
2. Each agent has a name, category, system prompt, and tool list
3. Each task has content, category (matching an agent), and optional priority/dependencies
4. Agents autonomously claim tasks, lock files, edit, unlock, and mark complete
5. The primary agent can monitor progress, send messages, and add tasks

## Example

```
Swarm: "Refactor auth module"
├── Agent: backend_dev (category: backend)
│   ├── Task: "Update auth middleware" [high]
│   └── Task: "Add rate limiting" [medium, depends on above]
├── Agent: test_writer (category: testing)
│   └── Task: "Write auth integration tests" [medium, depends on middleware]
└── Agent: docs_writer (category: docs)
    └── Task: "Update API documentation" [low]
```

Agents work in parallel where possible, respecting dependency ordering.

## Commands

The primary agent controls the swarm through commands:

| Command | Description |
|---------|-------------|
| `start` | Initialize swarm with agents and tasks |
| `status` | Check current progress |
| `add_tasks` | Add more tasks to the queue |
| `send_message` | Send instructions to agents |
| `stop` | Terminate the swarm |
