# Commands

Hive provides the `:Hive` command with subcommands for runtime control.

## Usage

```vim
:Hive <subcommand> [args]
:Hive! agent [name]
```

## Subcommands

### `status`

Show the current Hive runtime state and configuration.

```vim
:Hive status
```

### `agent`

Activate a specific agent in the current chat, or create a new chat with `!`.

```vim
:Hive agent build
:Hive agent plan
:Hive agent off
:Hive! agent build
```

### `model`

Set the model for subagents at runtime. Changes persist for the session.

```vim
:Hive model
:Hive model small openai/gpt-4.1-mini
:Hive model big openai/o3
:Hive model clear
```

### `list`

List available agents.

```vim
:Hive list
```

### `manager`

Toggle the agent manager sidebar.

```vim
:Hive manager
```

### `next` / `prev` / `parent` / `subagents`

Navigate the parent/subagent hierarchy from commands instead of keymaps.

```vim
:Hive next
:Hive prev
:Hive parent
:Hive subagents
```

### `setup`

Re-run setup with current configuration. Useful after changing `vim.g` settings.

```vim
:Hive setup
```

## Tab Completion

All subcommands support tab completion. Type `:Hive ` and press `<Tab>` to see available subcommands.
