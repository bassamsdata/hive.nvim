# Context Lifecycle

Long coding sessions generate a lot of context — tool outputs, file contents, conversation history. Without management, the context window fills up and the agent loses coherence or hits token limits.

Hive's context lifecycle system manages this automatically through three escalating layers.

## How It Works

The system monitors context usage as a percentage of the model's context window. When thresholds are crossed, it takes action:

```
0%──────50%────60%──────75%──────90%────100%
         │      │        │        │
       nudge  nudge   compact   reset
       start   end
```

### Layer 1: Nudge (50–60%)

A gentle reminder injected into the conversation telling the agent to be mindful of context usage. The agent is instructed to use the `prune` tool proactively to remove tool outputs it no longer needs.

### Layer 2: Compact (75%)

Automatic compaction. The system:
1. Summarizes the conversation so far
2. Replaces older messages with the summary
3. Preserves recent messages and the agent's current state

The agent continues working with full awareness of what happened, but with a compressed history.

### Layer 3: Reset (90%)

Emergency measure. If compaction isn't enough:
1. Full conversation summary is generated
2. A new chat is spawned with the summary as context
3. The agent continues in the new chat seamlessly

## Configuration

```lua
{
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
}
```

## Prunable Context

Press `gP` or `]P` in a chat buffer to see which tool outputs can be pruned. This helps the agent (and you) understand what's consuming context space.

## Tips for Long Sessions

1. **Let the agent prune** — Build agents are instructed to prune proactively. Don't fight it.
2. **Use subagents for exploration** — Subagent results are summarized when returned, keeping the parent's context lean.
3. **Check context usage** — The prunable viewer shows current usage percentage.
4. **Compaction is transparent** — The agent doesn't lose track of what it was doing after compaction.
