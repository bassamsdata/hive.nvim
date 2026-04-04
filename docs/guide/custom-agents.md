# Custom Agents

You can define your own agents with custom system prompts, tool sets, and model configurations.

## Agent Definition

Agents are defined in the Hive config under `agents.definitions`:

```lua
{
  agents = {
    definitions = {
      my_agent = {
        description = "My custom agent",
        system_prompt = "You are a specialized agent for ...",
        tools = { "cmd_runner", "get_diagnostics", "task" },
        model = "big", -- or "small"
      },
    },
  },
}
```

## Loading from Files

For complex system prompts, load agents from Lua files:

```lua
{
  agents = {
    load = {
      "~/.config/nvim/agents/my_agent.lua",
    },
  },
}
```

Each file should return a table with the agent definition:

```lua
-- ~/.config/nvim/agents/my_agent.lua
return {
  name = "my_agent",
  description = "My custom agent",
  system_prompt = [[
    You are a specialized agent for ...
  ]],
  tools = { "cmd_runner", "get_diagnostics" },
}
```

## Tool Access

Each agent gets a specific set of tools. When switching agents, the old tools are removed and the new tools are loaded. This provides tool isolation — a plan agent can't accidentally run destructive commands.

Available tools to assign:

| Tool | Description |
|------|-------------|
| `cmd_runner` | Run shell commands |
| `get_diagnostics` | LSP diagnostics |
| `task` | Delegate to subagents |
| `consult` | Expert advisor consultation |
| `ask_user` | Interactive user forms |
| `prune` | Context pruning |
| `todowrite` | Create/update task lists |
| `todoread` | Read task lists |
| `list_directory` | Directory listing |
| `skill` | Load specialized instructions |
| `swarm` | Multi-agent swarm orchestration |
