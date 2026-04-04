local api = vim.api
local fmt = string.format

local M = {}

---@type number|nil
local _float_win = nil
---@type number|nil
local _float_buf = nil

local HIVE_KEYMAP_NAMES = {
  "agent_switch",
  "agent_cycle",
  "agent_manager",
  "next_subagent",
  "prev_subagent",
  "parent_agent",
  "list_subagents",
  "todo_viewer",
  "todo_split",
  "toggle_ask_user",
  "subagent_model",
  "prunable_viewer",
  "hive_keymap_help",
}

function M.close()
  if _float_win and api.nvim_win_is_valid(_float_win) then api.nvim_win_close(_float_win, true) end
  _float_win = nil
  _float_buf = nil
end

---@class KeymapHelp.Entry
---@field keys string[] Individual key strings like "n:gA", "n:]A"
---@field description string
---@field group string

---@return KeymapHelp.Entry[]
local function _collect_keymaps()
  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return {} end

  local keymaps = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.keymaps
  if not keymaps then return {} end

  local name_set = {}
  for _, name in ipairs(HIVE_KEYMAP_NAMES) do
    name_set[name] = true
  end

  local entries = {}
  for name, def in pairs(keymaps) do
    if not name_set[name] then goto continue end

    local desc = def.description or name
    local group = desc:match("^%[([^%]]+)%]") or "Other"
    local label = desc:gsub("^%[[^%]]+%]%s*", "")

    local keys = {}
    if def.modes then
      for mode, binding in pairs(def.modes) do
        if type(binding) == "table" then
          for _, k in ipairs(binding) do
            table.insert(keys, fmt("%s:%s", mode, k))
          end
        else
          table.insert(keys, fmt("%s:%s", mode, binding))
        end
      end
    end
    table.sort(keys)

    table.insert(entries, { keys = keys, description = label, group = group })
    ::continue::
  end

  table.sort(entries, function(a, b)
    if a.group ~= b.group then return a.group < b.group end
    return (a.keys[1] or "") < (b.keys[1] or "")
  end)

  return entries
end

---@return string[] lines
---@return table[] highlights { line_idx, col_start, col_end, hl_group }
local function _build_content()
  local ins = table.insert
  local entries = _collect_keymaps()

  if #entries == 0 then return { " No keymaps registered" }, {} end

  local lines = {}
  local highlights = {}

  ins(lines, " Hive Keymaps")
  ins(highlights, { #lines - 1, 0, #lines[#lines], "Title" })
  ins(lines, "") -- placeholder for top separator
  ins(highlights, { #lines - 1, 0, 0, "Comment" })
  local top_sep_idx = #lines
  ins(lines, "")

  local SEP = " │ "
  local INDENT = 3
  local GAP = 3

  local max_keys_display = 0
  for _, e in ipairs(entries) do
    local joined = table.concat(e.keys, SEP)
    max_keys_display = math.max(max_keys_display, vim.fn.strdisplaywidth(joined))
  end
  local desc_col = INDENT + max_keys_display + GAP

  local current_group = nil
  for _, e in ipairs(entries) do
    if e.group ~= current_group then
      if current_group then ins(lines, "") end
      current_group = e.group
      local group_line = fmt(" %s", current_group)
      ins(lines, group_line)
      ins(highlights, { #lines - 1, 0, #lines[#lines], "Type" })
    end

    local keys_joined = table.concat(e.keys, SEP)
    local keys_display_w = vim.fn.strdisplaywidth(keys_joined)
    local padding = string.rep(" ", desc_col - INDENT - keys_display_w)
    local key_part = string.rep(" ", INDENT) .. keys_joined .. padding
    local line = key_part .. e.description
    local line_idx = #lines
    ins(lines, line)

    local col = INDENT
    for i, k in ipairs(e.keys) do
      ins(highlights, { line_idx, col, col + #k, "String" })
      col = col + #k
      if i < #e.keys then
        ins(highlights, { line_idx, col, col + #SEP, "Comment" })
        col = col + #SEP
      end
    end
    ins(highlights, { line_idx, #key_part, #line, "Normal" })
  end

  ins(lines, "") -- placeholder for bottom separator
  local bottom_sep_idx = #lines
  ins(highlights, { #lines - 1, 0, 0, "Comment" })
  ins(lines, " Press q/Esc to close")
  ins(highlights, { #lines - 1, 0, #lines[#lines], "Comment" })

  local max_display_w = 0
  for _, l in ipairs(lines) do
    max_display_w = math.max(max_display_w, vim.fn.strdisplaywidth(l))
  end
  local sep_line = string.rep("─", max_display_w)
  lines[top_sep_idx] = sep_line
  lines[bottom_sep_idx] = sep_line
  highlights[2] = { top_sep_idx - 1, 0, #sep_line, "Comment" }
  highlights[#highlights - 1] = { bottom_sep_idx - 1, 0, #sep_line, "Comment" }

  return lines, highlights
end

function M.open()
  M.close()

  local lines, highlights = _build_content()

  _float_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(_float_buf, 0, -1, false, lines)
  vim.bo[_float_buf].modifiable = false
  vim.bo[_float_buf].bufhidden = "wipe"
  vim.bo[_float_buf].filetype = "codecompanion-keymap-help"

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end

  local max_width = math.floor(vim.o.columns * 0.85)
  local max_height = math.floor(vim.o.lines * 0.7)

  width = math.min(math.max(width + 4, 60), max_width)
  local height = math.min(#lines, max_height)

  local row = math.max(0, math.floor((vim.o.lines - height - 4) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width - 4) / 2))

  _float_win = api.nvim_open_win(_float_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = (vim.fn.exists("+winborder") == 0 or vim.o.winborder == "") and "rounded" or nil,
    title = " Hive Keymaps ",
    title_pos = "center",
  })

  local ns = api.nvim_create_namespace("keymap_help")
  for _, hl in ipairs(highlights) do
    pcall(api.nvim_buf_set_extmark, _float_buf, ns, hl[1], hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
  end

  local function close_float()
    M.close()
  end

  vim.keymap.set("n", "q", close_float, { buffer = _float_buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close_float, { buffer = _float_buf, nowait = true })

  api.nvim_create_autocmd("BufLeave", {
    buffer = _float_buf,
    once = true,
    callback = close_float,
  })
end

function M.toggle()
  if _float_win and api.nvim_win_is_valid(_float_win) then
    M.close()
    return
  end
  M.open()
end

function M.setup()
  local hive_config = require("hive.config")

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local keymaps = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.keymaps
  if not keymaps then return end

  local modes = hive_config.keymap_modes("hive_keymap_help")
  if not modes then return end

  keymaps["hive_keymap_help"] = {
    modes = modes,
    index = 70,
    callback = function()
      M.open()
    end,
    description = "[Help] Hive keymap reference",
  }
end

return M
