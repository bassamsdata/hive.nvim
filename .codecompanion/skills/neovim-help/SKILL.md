---
-name: neovim-docs
-description: Extracts a specific Neovim documentation/help section programmatically from the command line, given a Lua help topic like "vim.diagnostic.get" or "wrap". Use when you want utlizie neovim API and want precise Neovim API docs without dumping the full help file.
---

# neovim-help

## When to use this skill
- When you need details on a Neovim Lua API.
- When you are unsure about using a function.
- When the user asks for documentation.
- Retrieve the exact Neovim API documentation needed for correct usage.

## How to use

Given a help topic (e.g., `vim.diagnostic.get`), run the following script:
you can use it with everything in neovim docs. Examples:
- 'wrap" -- for options
- "vim.system"
- "find" -- for functions start with vim.fn.fnid

```bash
neovim-help.sh "<help-topic>"
```

## other examples:

```bash
neovim-help.sh "vim.diagnostic.get"
# for things like vim.api functions: remove the "vim.api." prefix
neovim-help.sh "nvim_buf_set_extmark"
neovim-help.sh "nvim_buf_get_lines"
neovim-help.sh "vim.fs.find"
neovim-help.sh "uv.fs_scandir"
neovim-help.sh "nvim_echo"
```
