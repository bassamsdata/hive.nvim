local api = vim.api

---@class CCExtra.ConfirmOpts
---@field msg string The prompt message
---@field choices string[] Array of choice labels (first is default)
---@field on_choice fun(idx: number?, label: string?) Callback: idx=1-based selection, nil=dismissed
---@field title? string Window title (default: "Confirm")

---Show a floating confirm dialog with custom choices
---Non-blocking: calls on_choice when user picks or dismisses
---@param opts CCExtra.ConfirmOpts
return function(opts)
  local msg = opts.msg
  local choices = opts.choices or { "Ok" }
  local on_choice = opts.on_choice
  local title = opts.title or "Confirm"

  local choice_parts = {}
  for i, label in ipairs(choices) do
    choice_parts[i] = string.format("[%d] %s", i, label)
  end
  local choice_line = table.concat(choice_parts, "  ")

  local lines = {}
  for line in (msg .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  table.insert(lines, "")
  table.insert(lines, choice_line)

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width + 4, 30), 80)

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = buf })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - #lines - 2) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })

  local resolved = false
  local function resolve(idx)
    if resolved then return end
    resolved = true
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    vim.schedule(function()
      on_choice(idx, idx and choices[idx] or nil)
    end)
  end

  for i = 1, math.min(#choices, 9) do
    vim.keymap.set("n", tostring(i), function()
      resolve(i)
    end, { buffer = buf, nowait = true })
  end
  vim.keymap.set("n", "<CR>", function()
    resolve(1)
  end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    resolve(nil)
  end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", function()
    resolve(nil)
  end, { buffer = buf, nowait = true })

  api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      resolve(nil)
    end,
  })
end
