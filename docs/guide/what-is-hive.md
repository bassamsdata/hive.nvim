# What is Hive?

Hive is an extension plugin for [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim) that adds a multi-agent system with parallel subagent orchestration, context lifecycle management, and extended tooling — designed for long, autonomous coding workflows.

## Why Hive?

CodeCompanion provides a solid foundation for AI-assisted coding in Neovim. Hive builds on top of it to enable:

- **Agent-based workflows** — Instead of a single chat, you work with role-specific agents (build, plan) that each have the right tools and system prompts for their job
- **Parallel subagent delegation** — Spawn explorer, analyzer, and general subagents that work simultaneously on different parts of your codebase and report back
- **Long session sustainability** — Automatic context window management prevents context overflow during extended coding sessions
- **Expert consultations** — Get architectural advice, code reviews, security analysis, and performance guidance from specialized advisor agents

## Architecture

Hive integrates with CodeCompanion through its extension system. It doesn't modify the core plugin — it adds capabilities on top.

```
┌───────────────────────────────────────────┐
│              CodeCompanion                │
│         (chat, adapters, core)            │
├───────────────────────────────────────────┤
│                  Hive                     │
│  ┌───────────┐ ┌───────────┐ ┌─────────┐  │
│  │  Agents   │ │   Tools   │ │ Context │  │
│  │build,plan │ │ task,ask  │ │Lifecycle│  │
│  └───────────┘ └───────────┘ └─────────┘  │
│  ┌───────────┐ ┌───────────┐ ┌─────────┐  │
│  │ Subagents │ │ Advisors  │ │  Swarm  │  │
│  │ explorer, │ │sage,rev,  │ │  multi  │  │
│  │ analyzer  │ │sec,perf   │ │ worker  │  │
│  └───────────┘ └───────────┘ └─────────┘  │
└───────────────────────────────────────────┘
```

## Key Concepts

| Concept | Description |
|---------|-------------|
| **Agent** | A role with a system prompt, tool set, and model configuration |
| **Subagent** | A child agent spawned by the primary agent for parallel work |
| **Advisor** | A specialized consultant (sage, reviewer, security, performance) |
| **Context Lifecycle** | Automatic management of the context window as it fills up |
| **Tool** | An action the agent can take (run commands, read files, delegate tasks) |

## Requirements

- Neovim >= 0.11
- [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim)
