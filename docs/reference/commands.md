# Commands

Hive provides the `:Hive` command with subcommands for runtime control.

## Usage

```vim
:Hive <subcommand> [args]
```

## Subcommands

### `status`

Show current Hive state — active agent, loaded modules, configuration.

```vim
:Hive status
```

### `agent`

Activate a specific agent by name.

```vim
:Hive agent build
:Hive agent plan
```

### `model`

Set the model for subagents at runtime. Changes persist for the session.

```vim
:Hive model small claude-sonnet-4-20250514
:Hive model big claude-opus-4-20250514
```

### `list`

List available agents.

```vim
:Hive list
```

### `debug`

Toggle debug mode. When enabled, additional logging is written to the debug log.

```vim
:Hive debug
```

### `setup`

Re-run setup with current configuration. Useful after changing `vim.g` settings.

```vim
:Hive setup
```

## Tab Completion

All subcommands support tab completion. Type `:Hive ` and press `<Tab>` to see available subcommands. Model names also complete based on your configured adapter.
