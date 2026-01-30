---
name: neovim-help
description: Extracts a specific Neovim help section programmatically from the command line, given a Lua help topic like "vim.diagnostic.get". Use when you want to retrieve precise Neovim API help without dumping the full help file.
---

# neovim-help

## When to use this skill
Use this skill when the user asks for help on a specific Neovim Lua API
function or help tag and expects only the relevant formatted documentation
section, not the entire help file.

## How to use

Given a help topic (e.g., `vim.diagnostic.get`), run the following script:

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
