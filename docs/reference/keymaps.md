# Keymaps

All keymaps are active in CodeCompanion chat buffers. Press `]?` to see the full reference inside Neovim.

## Chat Buffer Keymaps

All keymaps are configurable through `agents.keymap` in the [config](/reference/config). The default prefix is `]`.

### Agent Controls

| Keymap | Name | Description |
|--------|------|-------------|
| `]o` / `]A` | `agent_switch` | Open agent picker |
| `<Tab>` | `agent_cycle` | Cycle to next agent |
| `gA` / `]a` | `agent_manager` | Toggle agent manager sidebar |

### Navigation

| Keymap | Name | Description |
|--------|------|-------------|
| `]s` | `next_subagent` | Jump to next subagent chat |
| `[s` | `prev_subagent` | Jump to previous subagent chat |
| `]p` | `parent_agent` | Jump to parent agent chat |
| `]S` / `]l` | `list_subagents` | List all subagents (picker) |

### Tools

| Keymap | Name | Description |
|--------|------|-------------|
| `]T` | `todo_viewer` | View task list (floating window) |
| `]t` | `todo_split` | Toggle task list (split) |
| `gH` / `]q` | `toggle_ask_user` | Toggle ask_user form |
| `gm` / `]m` | `subagent_model` | Set subagent model (small/big) |

### Debug

| Keymap | Name | Description |
|--------|------|-------------|
| `gP` / `]P` | `prunable_viewer` | Show prunable context |
| `]?` | `hive_keymap_help` | Hive keymap reference |

## Agent Manager Keymaps

These are active in the agent manager sidebar (`gA`):

| Key | Action |
|-----|--------|
| `j` / `k` | Navigate up/down |
| `<CR>` | Open selected chat |
| `x` | Close selected chat |
| `f` | Toggle fold |
| `R` | Refresh |
| `q` | Close sidebar |

## Ask User Form Keymaps

These are active when an ask_user form is open:

| Key | Action |
|-----|--------|
| `<Tab>` / `<S-Tab>` | Next / previous question |
| `j` / `k` or `<Down>` / `<Up>` | Navigate choices |
| `<CR>` / `<Space>` | Select choice |
| `S` / `<C-s>` | Submit form |
| `H` | Hide form |
| `q` | Cancel |

## Todo Viewer Keymaps

These are active in the floating todo viewer (`]T`):

| Key | Action |
|-----|--------|
| `q` / `<Esc>` / `<CR>` | Close viewer |
| `R` | Refresh |

## Changing the Prefix

Set `prefix` in your config to change all prefix-derived keymaps at once:

```lua
agents = {
  keymap = {
    prefix = "s", -- ]s → ss, ]t → st, ]p → sp, etc.
  },
}
```

Keymaps with `g` prefixes (like `gA`, `gP`) are independent of the prefix setting. Override them individually if needed.
