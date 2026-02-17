-- Spinner UI backed by state.lua
-- Renders a floating window with status, adapter info, and subagent progress

local state = require("codecompanion-extra.state")

local api = vim.api
local uv = vim.uv

-- ============================================================================
-- CONSTANTS AND CONFIGURATION DEFAULTS
-- ============================================================================
local CONSTANTS = {
  MAX_WIDTH_PERCENT = 0.35,
  WINDOW_BLEND = 100,
  ZINDEX = 1000,
  RIGHT_OFFSET = 1,

  COMPLETION_DISPLAY_TIME = 3000,
  SUBAGENT_COMPLETION_DISPLAY_TIME = 2500,
  SPINNER_INTERVAL = 80,

  STATUS = {
    SENDING = "Sending",
    STREAMING = "Streaming",
    TOOL_RUNNING = "Executing Tool",
    PROCESSING = "Processing",
    COMPLETED = "Done ",
    ERROR = " Error ",
    CANCELLED = "Cancelled ",
  },

  -- stylua: ignore start
  SPINNER_FRAMES                   = {
    corner        = { "◜", "◝", "◞", "◟" },
    toggle        = { "⊶", "⊷", },
    toggle3       = { "□", "■" },
    braille       = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    building      = { "⣼", "⣹", "⢻", "⠿", "⡟", "⣏", "⣧", "⣶" },
    simple_pounce = { ".  ", ".. ", "...", " ..", "  .", "   " },
    star          = { "✶", "✸", "✹", "✺", "✹", "✷" },
    binary        = { "010010", "001100", "100101", "111010", "111101", "010111", "101011", "111000", "110011", "110101" },
    line          = { "-", "\\", "|", "/" },
    dots_bounce   = { "⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈" },
    arrow         = { "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" },
    scramble      = { "abc", "ghi", "def", "jkl", "pqr", "mno", "stu", "yz!", "vwx" },
    box           = { "◰", "◳", "◲", "◱" },
    pulse         = { "○", "◔", "◑", "◕", "●", "◕", "◑", "◔" },
    pipe          = { "┤", "┘", "┴", "└", "├", "┌", "┬", "┐" },
    snake         = { "⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈" },
    moon          = { "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" },
    minimal       = { ".", "..", "..." },
    bars          = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃", "▂" },
    slide_bar     = { "=== ", " === ", " === ", " === ", " === ", " === " },
    bounce        = {
      "⠁", "⠁", "⠉", "⠙", "⠚", "⠒", "⠂", "⠂", "⠒", "⠲", "⠴", "⠤", "⠄", "⠄", "⠤", "⠠",
      "⠠", "⠤", "⠦", "⠖", "⠒", "⠐", "⠐", "⠒", "⠓", "⠋", "⠉", "⠈", "⠈",
    },
  },
  -- stylua: ignore end

  HIGHLIGHT_LINKS = {
    SpinnerActive = "DiagnosticInfo",
    SpinnerDim = "Comment",
    SpinnerSuccess = "DiagnosticOk",
    SpinnerError = "DiagnosticError",
    SpinnerInfo = "Special",
    SpinnerLabel = "Comment",
    SpinnerProvider = "DiagnosticHint",
    SpinnerSubagent = "DiagnosticWarn",
    SpinnerConnector = "NonText",
  },
}

local DEFAULT_CONFIG = {
  spinner = {
    frames = CONSTANTS.SPINNER_FRAMES.binary,
    interval = CONSTANTS.SPINNER_INTERVAL,
    brackets = false,
  },
  subagent_spinner = {
    frames = CONSTANTS.SPINNER_FRAMES.braille,
  },
  display = {
    show_model = true,
    show_tool_name = false,
    show_tool_status = true,
    show_timestamps = true,
    show_subagents = true,
    show_subagent_timers = true,
    completion_display_time = CONSTANTS.COMPLETION_DISPLAY_TIME,
    subagent_completion_display_time = CONSTANTS.SUBAGENT_COMPLETION_DISPLAY_TIME,
  },
  window = {
    max_width_percent = CONSTANTS.MAX_WIDTH_PERCENT,
    blend = CONSTANTS.WINDOW_BLEND,
    right_offset = CONSTANTS.RIGHT_OFFSET,
    enabled = true,
  },
}

local Spinner = {}
Spinner.__index = Spinner

function Spinner.new(config)
  local self = setmetatable({}, Spinner)
  self.config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_CONFIG), config or {})
  self.ns_id = api.nvim_create_namespace("spinner_info_new")
  self.state = {
    win = nil,
    buf = nil,
    frame = 1,
    subagent_frame = 1,
    animation_timer = nil,
    last_height = nil,
    last_win_config = nil,
    last_buf = nil,
    last_parent_durations = {},
  }
  self:_validate_spinner_frames()
  self:_validate_subagent_spinner_frames()
  return self
end

function Spinner:_validate_spinner_frames()
  self.config.spinner.frames = self:_resolve_frames(self.config.spinner.frames)
end

function Spinner:_validate_subagent_spinner_frames()
  self.config.subagent_spinner.frames = self:_resolve_frames(self.config.subagent_spinner.frames)
end

function Spinner:_resolve_frames(frames)
  if type(frames) == "string" then
    local preset = CONSTANTS.SPINNER_FRAMES[frames]
    if preset then return preset end
    vim.notify(string.format("Spinner: Unknown preset '%s', using default", frames), vim.log.levels.WARN)
    return CONSTANTS.SPINNER_FRAMES.braille
  end

  if type(frames) == "function" then frames = frames() end

  if type(frames) ~= "table" or vim.tbl_isempty(frames) then
    vim.notify("Spinner: Invalid frames config, using default", vim.log.levels.WARN)
    return CONSTANTS.SPINNER_FRAMES.braille
  end

  return frames
end

function Spinner:_setup_highlights()
  for group_name, link_to in pairs(CONSTANTS.HIGHLIGHT_LINKS) do
    api.nvim_set_hl(0, group_name, { link = link_to, default = true })
  end
end

function Spinner:_get_spinner_char()
  local char = self.config.spinner.frames[self.state.frame]
  if self.config.spinner.brackets then char = "[" .. char .. "]" end
  return char
end

function Spinner:_get_subagent_spinner_char()
  return self.config.subagent_spinner.frames[self.state.subagent_frame]
end

function Spinner:_format_time(seconds)
  if seconds < 60 then return string.format("%.1fs", seconds) end
  local minutes = math.floor(seconds / 60)
  local secs = seconds % 60
  return string.format("%dm %.1fs", minutes, secs)
end

function Spinner:_get_elapsed_time(parent)
  if not parent.request_started then return "0.0s" end
  local elapsed = (uv.now() - parent.request_started) / 1000
  return self:_format_time(elapsed)
end

function Spinner:_get_final_duration(parent, bufnr)
  if parent.duration_ms then
    if bufnr then self.state.last_parent_durations[bufnr] = parent.duration_ms end
    return self:_format_time(parent.duration_ms / 1000)
  end
  if parent.completed_at and parent.total_started then
    local duration_ms = parent.completed_at - parent.total_started
    if bufnr then self.state.last_parent_durations[bufnr] = duration_ms end
    return self:_format_time(duration_ms / 1000)
  end
  if bufnr and self.state.last_parent_durations[bufnr] then
    return self:_format_time(self.state.last_parent_durations[bufnr] / 1000)
  end
  local start = parent.total_started or parent.request_started
  if not start then return "0.0s" end
  local elapsed = (uv.now() - start) / 1000
  if bufnr then self.state.last_parent_durations[bufnr] = elapsed * 1000 end
  return self:_format_time(elapsed)
end

function Spinner:_get_total_elapsed_time(parent)
  if not parent.total_started then return self:_get_elapsed_time(parent) end
  local elapsed = (uv.now() - parent.total_started) / 1000
  return self:_format_time(elapsed)
end

function Spinner:_get_inline_elapsed(inline)
  if not inline or not inline.started_at then return "0.0s" end
  local elapsed = (uv.now() - inline.started_at) / 1000
  return self:_format_time(elapsed)
end

function Spinner:_is_child_bufnr(bufnr)
  if not bufnr then return false end
  local ok, hierarchy = pcall(require, "codecompanion-extra.agents.hierarchy")
  return ok and hierarchy.is_child(bufnr) or false
end

function Spinner:_get_focused_parent_bufnr()
  local current_win = api.nvim_get_current_win()
  local current_buf = api.nvim_win_get_buf(current_win)
  if
    api.nvim_buf_is_valid(current_buf)
    and api.nvim_get_option_value("filetype", { buf = current_buf }) == "codecompanion"
  then
    return current_buf
  end

  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_buf_is_valid(buf) and api.nvim_get_option_value("filetype", { buf = buf }) == "codecompanion" then
      return buf
    end
  end

  return nil
end

---@param args table
---@return number|nil
function Spinner:_event_bufnr(args)
  return (args.data and args.data.bufnr) or args.buf
end

---@param args table
---@return boolean
function Spinner:_is_chat_request_event(args)
  local data = args.data or {}
  local bufnr = self:_event_bufnr(args)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return false end
  if data.interaction and data.interaction ~= "chat" then return false end
  local ft = api.nvim_get_option_value("filetype", { buf = bufnr })
  return ft == "codecompanion"
end

---@param args table
---@return boolean
function Spinner:_is_inline_request_event(args)
  local data = args.data or {}
  return data.interaction == "inline" or data.interaction == "cmd"
end

---@param args table
---@return boolean
function Spinner:_is_chat_tool_event(args)
  local bufnr = self:_event_bufnr(args)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return false end
  local ft = api.nvim_get_option_value("filetype", { buf = bufnr })
  return ft == "codecompanion"
end

function Spinner:_get_active_parent(view)
  local focused = self:_get_focused_parent_bufnr()
  if focused and view.parents[focused] and view.parents[focused].status ~= "idle" then
    return view.parents[focused], focused
  end

  if view.active_parent_bufnr and view.parents[view.active_parent_bufnr] then
    local active = view.parents[view.active_parent_bufnr]
    if active.status ~= "idle" then return active, view.active_parent_bufnr end
  end

  for bufnr, parent in pairs(view.parents) do
    if parent.status ~= "idle" then return parent, bufnr end
  end

  return nil, nil
end

function Spinner:_build_adapter_line(parent)
  if not self.config.display.show_model then return nil end
  local chunks = {}
  local model = parent.model
  if type(model) == "table" then model = model.name or model.default or model.id or model.model end
  if model then table.insert(chunks, { tostring(model), "SpinnerInfo" }) end
  if parent.adapter then
    if #chunks > 0 then table.insert(chunks, { " ", "SpinnerInfo" }) end
    table.insert(chunks, { "(", "SpinnerDim" })
    table.insert(chunks, { parent.adapter, "SpinnerInfo" })
    table.insert(chunks, { ")", "SpinnerDim" })
  end
  if #chunks == 0 then return nil end
  return chunks
end

function Spinner:_build_status_line(parent, active_parent_count, bufnr)
  local spinner_char = self:_get_spinner_char()
  local chunks = {}
  local chat_label = ""

  if parent.status == "sending" then
    table.insert(chunks, { CONSTANTS.STATUS.SENDING .. chat_label .. " ", "SpinnerActive" })
    table.insert(chunks, { spinner_char, "SpinnerActive" })
  elseif parent.status == "streaming" then
    table.insert(chunks, { CONSTANTS.STATUS.STREAMING .. chat_label .. " ", "SpinnerActive" })
    table.insert(chunks, { spinner_char, "SpinnerActive" })
  elseif parent.status == "tool_running" then
    if self.config.display.show_tool_status then
      local label = CONSTANTS.STATUS.TOOL_RUNNING
      if self.config.display.show_tool_name and parent.current_tool then
        label = label .. ": " .. parent.current_tool
      end
      table.insert(chunks, { label .. chat_label .. " ", "SpinnerActive" })
      table.insert(chunks, { spinner_char, "SpinnerActive" })
    else
      table.insert(chunks, { CONSTANTS.STATUS.PROCESSING .. chat_label .. " ", "SpinnerActive" })
      table.insert(chunks, { spinner_char, "SpinnerActive" })
    end
  elseif parent.status == "completed" then
    table.insert(chunks, { CONSTANTS.STATUS.COMPLETED .. chat_label, "SpinnerSuccess" })
  elseif parent.status == "error" then
    table.insert(chunks, { CONSTANTS.STATUS.ERROR .. chat_label, "SpinnerError" })
  elseif parent.status == "cancelled" then
    table.insert(chunks, { CONSTANTS.STATUS.CANCELLED .. chat_label, "SpinnerLabel" })
  else
    table.insert(chunks, { CONSTANTS.STATUS.PROCESSING .. chat_label .. " ", "SpinnerActive" })
    table.insert(chunks, { spinner_char, "SpinnerActive" })
  end

  if self.config.display.show_timestamps then
    local is_terminal = parent.status == "completed" or parent.status == "error" or parent.status == "cancelled"
    if is_terminal then
      local final_duration = self:_get_final_duration(parent, bufnr)
      table.insert(chunks, { " · " .. final_duration, "SpinnerLabel" })
    else
      table.insert(chunks, { " [" .. self:_get_elapsed_time(parent) .. "]", "SpinnerLabel" })
      if parent.total_started then
        local total_elapsed = (uv.now() - parent.total_started) / 1000
        if total_elapsed >= 60 then
          table.insert(chunks, { " · " .. self:_get_total_elapsed_time(parent), "SpinnerDim" })
        end
      end
    end
  end

  return chunks
end

function Spinner:_build_subagent_line(info)
  local name = info.agent_name or "Unknown"
  name = name:sub(1, 1):upper() .. name:sub(2)
  local time_str = self.config.display.show_subagent_timers
      and (info.duration_ms and self:_format_time(info.duration_ms / 1000) or self:_format_time(
        (uv.now() - info.start_time) / 1000
      ))
    or nil
  local calls_str = info.tool_count > 0 and string.format("%d calls", info.tool_count) or nil
  local prefix = { "↳ ", "SpinnerConnector" }

  local chunks = { prefix }
  if info.status == "running" then
    table.insert(chunks, { name .. " ", "SpinnerSubagent" })
    table.insert(chunks, { self:_get_subagent_spinner_char(), "SpinnerSubagent" })
    if calls_str then table.insert(chunks, { " " .. calls_str, "SpinnerLabel" }) end
    if time_str then table.insert(chunks, { " " .. time_str, "SpinnerLabel" }) end
    return chunks
  end

  local status_icon, hl = "✗", "SpinnerError"
  if info.status == "completed" then
    status_icon, hl = "✓", "SpinnerSuccess"
  end

  table.insert(chunks, { status_icon .. " ", hl })
  table.insert(chunks, { name, hl })
  local detail_parts = {}
  if calls_str then table.insert(detail_parts, calls_str) end
  if time_str then table.insert(detail_parts, time_str) end
  if #detail_parts > 0 then
    table.insert(chunks, { " (" .. table.concat(detail_parts, ", ") .. ")", "SpinnerLabel" })
  end

  return chunks
end

function Spinner:_build_compact_subagents_line(subagents)
  local sub_spinner = self:_get_subagent_spinner_char()
  local total = vim.tbl_count(subagents)
  local running = 0
  local completed = 0
  local failed = 0

  for _, info in pairs(subagents) do
    if info.status == "running" then
      running = running + 1
    elseif info.status == "completed" then
      completed = completed + 1
    else
      failed = failed + 1
    end
  end

  local chunks = {}
  table.insert(chunks, { "Subagents: " .. total .. " ", "SpinnerSubagent" })
  table.insert(chunks, { string.format("%d ", running), "SpinnerLabel" })
  table.insert(chunks, { sub_spinner, "SpinnerSubagent" })
  if completed > 0 then
    table.insert(chunks, { "  " .. completed .. " ", "SpinnerLabel" })
    table.insert(chunks, { "✓", "SpinnerSuccess" })
  end
  if failed > 0 then
    table.insert(chunks, { "  " .. failed .. " ", "SpinnerLabel" })
    table.insert(chunks, { "✗", "SpinnerError" })
  end

  return chunks
end

function Spinner:_build_subagent_lines(subagents)
  if not self.config.display.show_subagents then return {} end

  local visible = {}
  for _, info in pairs(subagents or {}) do
    table.insert(visible, info)
  end
  if #visible == 0 then return {} end

  table.sort(visible, function(a, b)
    if a.status == "running" and b.status ~= "running" then return true end
    if a.status ~= "running" and b.status == "running" then return false end
    return (a.agent_name or "") < (b.agent_name or "")
  end)

  if #visible >= 3 then return { self:_build_compact_subagents_line(subagents) } end

  local lines = {}
  for _, info in ipairs(visible) do
    table.insert(lines, self:_build_subagent_line(info))
  end
  return lines
end

function Spinner:_build_inline_line(inline)
  local chunks = {}

  if inline.status == "sending" then
    table.insert(chunks, { CONSTANTS.STATUS.SENDING .. " ", "SpinnerActive" })
    table.insert(chunks, { self:_get_spinner_char(), "SpinnerActive" })
  elseif inline.status == "completed" then
    table.insert(chunks, { CONSTANTS.STATUS.COMPLETED, "SpinnerSuccess" })
  elseif inline.status == "error" then
    table.insert(chunks, { CONSTANTS.STATUS.ERROR, "SpinnerError" })
  else
    table.insert(chunks, { "Inline ", "SpinnerActive" })
    table.insert(chunks, { self:_get_spinner_char(), "SpinnerActive" })
  end

  if self.config.display.show_timestamps then
    local is_terminal = inline.status == "completed" or inline.status == "error"
    if is_terminal and inline.duration_ms then
      table.insert(chunks, { " · " .. self:_format_time(inline.duration_ms / 1000), "SpinnerLabel" })
    else
      table.insert(chunks, { " [" .. self:_get_inline_elapsed(inline) .. "]", "SpinnerLabel" })
    end
  end

  local interaction_label = inline.interaction == "cmd" and "(cmd)" or "(inline)"
  table.insert(chunks, { " " .. interaction_label, "SpinnerDim" })

  return chunks
end

function Spinner:_build_inline_adapter_line(inline)
  if not self.config.display.show_model then return nil end
  local chunks = {}
  local model = inline.model
  if type(model) == "table" then model = model.name or model.default or model.id or model.model end
  if model then table.insert(chunks, { tostring(model), "SpinnerInfo" }) end
  if inline.adapter then
    if #chunks > 0 then table.insert(chunks, { " ", "SpinnerInfo" }) end
    table.insert(chunks, { "(", "SpinnerDim" })
    table.insert(chunks, { inline.adapter, "SpinnerInfo" })
    table.insert(chunks, { ")", "SpinnerDim" })
  end
  if #chunks == 0 then return nil end
  return chunks
end

function Spinner:_build_display_lines()
  local manager = state.instance()
  if not manager then return {} end
  local view = manager:get_view()
  local parent_view = manager:get_parent_view()
  local active_parent, active_bufnr = self:_get_active_parent(parent_view)

  local lines = {}
  local inline = view.inline or {}
  if inline.active then
    local inline_adapter_line = self:_build_inline_adapter_line(inline)
    if inline_adapter_line then table.insert(lines, inline_adapter_line) end
    table.insert(lines, self:_build_inline_line(inline))
  end

  if not active_parent then
    for _, line in ipairs(lines) do
      table.insert(line, { " ", "SpinnerDim" })
    end
    return lines
  end

  local active_parent_count = 0
  for _, parent in pairs(parent_view.parents) do
    if parent.status ~= "idle" then active_parent_count = active_parent_count + 1 end
  end

  local adapter_line = self:_build_adapter_line(active_parent)
  if adapter_line then table.insert(lines, adapter_line) end

  local status_line = self:_build_status_line(active_parent, active_parent_count, active_bufnr)
  table.insert(lines, status_line)

  if active_parent_count > 1 then
    table.insert(lines, { { "Parents: " .. active_parent_count .. " active", "SpinnerDim" } })
  end

  local subagent_lines = self:_build_subagent_lines(active_parent.subagents)
  for _, line in ipairs(subagent_lines) do
    table.insert(lines, line)
  end

  for _, line in ipairs(lines) do
    table.insert(line, { " ", "SpinnerDim" })
  end

  return lines
end

function Spinner:_virt_line_width(virt_line)
  local width = 0
  for _, chunk in ipairs(virt_line) do
    local text = type(chunk[1]) == "string" and chunk[1] or ""
    width = width + vim.fn.strdisplaywidth(text)
  end
  return width
end

function Spinner:_max_display_width(lines)
  local max_w = 0
  for _, line in ipairs(lines) do
    local w = self:_virt_line_width(line)
    if w > max_w then max_w = w end
  end
  return max_w
end

function Spinner:_is_window_valid()
  return self.state.win
    and self.state.buf
    and api.nvim_win_is_valid(self.state.win)
    and api.nvim_buf_is_valid(self.state.buf)
end

function Spinner:_close_window()
  if self.state.win and api.nvim_win_is_valid(self.state.win) then api.nvim_win_close(self.state.win, true) end
  self.state.win = nil
  self.state.buf = nil
  self.state.last_buf = nil
end

function Spinner:_create_window()
  if not self.config.window.enabled then return end

  local buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  self.state.last_height = nil
  self.state.last_win_config = nil
  self.state.last_buf = buf

  local display_lines = self:_build_display_lines()
  if #display_lines == 0 then return end

  local height = #display_lines
  local content_width = self:_max_display_width(display_lines)
  local max_allowed_width = math.floor(vim.o.columns * self.config.window.max_width_percent)
  local width = math.max(math.min(content_width, max_allowed_width), 1)

  local row = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0) - height
  local col = vim.o.columns - width - self.config.window.right_offset

  local win = api.nvim_open_win(buf, false, {
    relative = "editor",
    border = "none",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    focusable = false,
    zindex = CONSTANTS.ZINDEX,
  })
  api.nvim_set_option_value("winblend", self.config.window.blend, { win = win })

  self.state.buf = buf
  self.state.win = win
end

function Spinner:_update_display()
  if not self:_is_window_valid() then return end

  local display_lines = self:_build_display_lines()
  if #display_lines == 0 then
    self:_close_window()
    self:_stop_animation()
    return
  end

  -- Sanitize virt_text chunks to avoid invalid chunk errors
  local logged_invalid = false
  for i, line in ipairs(display_lines) do
    local sanitized = {}
    for _, chunk in ipairs(line) do
      if type(chunk) == "table" then
        local text = chunk[1]
        local hl = chunk[2]
        if type(text) == "string" then
          table.insert(sanitized, { text, hl })
        elseif text ~= nil then
          if not logged_invalid then logged_invalid = true end
          table.insert(sanitized, { tostring(text), hl })
        end
      elseif type(chunk) == "string" then
        table.insert(sanitized, { chunk, "SpinnerDim" })
      else
        if chunk ~= nil and not logged_invalid then logged_invalid = true end
      end
    end
    display_lines[i] = sanitized
  end

  local height = #display_lines
  local content_width = self:_max_display_width(display_lines)
  local max_allowed_width = math.floor(vim.o.columns * self.config.window.max_width_percent)
  local width = math.max(math.min(content_width, max_allowed_width), 1)

  if self.state.last_buf ~= self.state.buf then
    self.state.last_height = nil
    self.state.last_win_config = nil
    self.state.last_buf = self.state.buf
  end

  if self.state.last_height ~= height or api.nvim_buf_line_count(self.state.buf) < height then
    local empty_lines = {}
    for _ = 1, height do
      table.insert(empty_lines, "")
    end
    api.nvim_buf_set_lines(self.state.buf, 0, -1, false, empty_lines)
    self.state.last_height = height
  end

  local row = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0) - height
  local col = vim.o.columns - width - self.config.window.right_offset

  if
    not self.state.last_win_config
    or self.state.last_win_config.row ~= row
    or self.state.last_win_config.col ~= col
    or self.state.last_win_config.width ~= width
    or self.state.last_win_config.height ~= height
  then
    api.nvim_win_set_config(self.state.win, {
      relative = "editor",
      row = row,
      col = col,
      width = width,
      height = height,
    })
    self.state.last_win_config = { row = row, col = col, width = width, height = height }
  end

  api.nvim_buf_clear_namespace(self.state.buf, self.ns_id, 0, -1)
  for line_idx, virt_line in ipairs(display_lines) do
    api.nvim_buf_set_extmark(self.state.buf, self.ns_id, line_idx - 1, 0, {
      virt_text = virt_line,
      virt_text_pos = "eol_right_align",
      priority = vim.highlight.priorities.user + 1,
    })
  end
end

---Check if any interaction needs an animated spinner (not just a static "Done" display)
---@param view CCExtra.StateView
---@return boolean
function Spinner:_needs_animation(view)
  local inline = view.inline or {}
  if inline.active and inline.status == "sending" then return true end

  local active_parent = self:_get_active_parent(view)
  if not active_parent then return false end

  return active_parent.status ~= "idle"
    and active_parent.status ~= "completed"
    and active_parent.status ~= "error"
    and active_parent.status ~= "cancelled"
end

---Check if any interaction has content to display (including terminal states like "Done")
---@param view CCExtra.StateView
---@return boolean
function Spinner:_has_visible_content(view)
  local inline = view.inline or {}
  if inline.active then return true end

  local active_parent = self:_get_active_parent(view)
  return active_parent ~= nil
end

function Spinner:_start_animation()
  if self.state.animation_timer then return end

  self.state.animation_timer = uv.new_timer()
  self.state.animation_timer:start(
    0,
    self.config.spinner.interval,
    vim.schedule_wrap(function()
      local manager = state.instance()
      if not manager then
        self:_stop_animation()
        return
      end
      local view = manager:get_view()
      if not self:_needs_animation(view) then
        self:_stop_animation()
        return
      end
      self.state.frame = (self.state.frame % #self.config.spinner.frames) + 1
      self.state.subagent_frame = (self.state.subagent_frame % #self.config.subagent_spinner.frames) + 1
      self:_update_display()
    end)
  )
end

function Spinner:_stop_animation()
  if self.state.animation_timer and not self.state.animation_timer:is_closing() then
    self.state.animation_timer:stop()
    self.state.animation_timer:close()
  end
  self.state.animation_timer = nil
end

function Spinner:_ensure_ui_visible()
  local manager = state.instance()
  if not manager then return end

  local view = manager:get_view()
  if not self:_has_visible_content(view) then
    self:_close_window()
    self:_stop_animation()
    return
  end

  if not self:_is_window_valid() then self:_create_window() end
  self:_update_display()
  if self:_needs_animation(view) then self:_start_animation() end
end

local M = {}
local _spinner_instance = nil

function M.setup(user_config)
  if _spinner_instance then
    _spinner_instance:_stop_animation()
    _spinner_instance:_close_window()
  end

  if not state.instance() then state.setup(user_config or {}) end

  _spinner_instance = Spinner.new(user_config)
  _spinner_instance:_setup_highlights()

  -- TODO: Move highlights to its module
  api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup("SpinnerHighlightsNew", { clear = true }),
    callback = function()
      if _spinner_instance then _spinner_instance:_setup_highlights() end
    end,
  })

  local group = api.nvim_create_augroup("CodeCompanionSpinnerNew", { clear = true })
  local manager = state.instance()

  if manager then
    manager:on("parent_updated", function()
      _spinner_instance:_ensure_ui_visible()
    end)
    manager:on("parent_reset", function()
      _spinner_instance:_ensure_ui_visible()
    end)
    manager:on("parent_removed", function()
      _spinner_instance:_ensure_ui_visible()
    end)
    manager:on("parent_created", function()
      _spinner_instance:_ensure_ui_visible()
    end)
    manager:on("active_parent_changed", function()
      _spinner_instance:_ensure_ui_visible()
    end)
    manager:on("inline_updated", function()
      _spinner_instance:_ensure_ui_visible()
    end)
  end

  -- Request lifecycle: route by interaction type (chat vs inline)
  api.nvim_create_autocmd("User", {
    pattern = {
      "CodeCompanionRequestStarted",
      "CodeCompanionRequestFinished",
      "CodeCompanionRequestStreaming",
    },
    group = group,
    callback = function(args)
      if not manager or not _spinner_instance then return end
      local data = args.data or {}
      local event_bufnr = data.bufnr

      if event_bufnr and _spinner_instance:_is_child_bufnr(event_bufnr) then return end

      if data.interaction == "inline" or data.interaction == "cmd" then
        -- Inline and cmd interactions share the same lifecycle (one-shot, no tools)
        if args.match == "CodeCompanionRequestStarted" then
          manager:on_inline_started(event_bufnr, data.adapter, data.interaction)
          debug(
            string.format(
              "event: CodeCompanionRequestStarted [%s] -> on_inline_started(bufnr=%s, adapter=%s, interaction=%s)",
              data.interaction,
              tostring(event_bufnr),
              tostring(data.adapter),
              tostring(data.interaction)
            )
          )
        elseif args.match == "CodeCompanionRequestFinished" then
          manager:on_inline_finished(data.status == "error" and "error" or nil)
          debug(string.format("event: CodeCompanionRequestFinished [%s] -> on_inline_finished()", data.interaction))
        end
        -- No streaming for inline — intentionally no handler
      elseif event_bufnr then
        -- Chat interaction — only process when bufnr is present
        -- Internal HTTP requests (e.g. web_search adapter calls) fire RequestStarted
        -- without bufnr; those are not real chat interactions and must be skipped.
        if args.match == "CodeCompanionRequestStarted" then
          manager:on_request_started(event_bufnr, data.id)
          if data.adapter then manager:on_chat_adapter(event_bufnr, data.adapter) end
          debug(
            string.format(
              "event: CodeCompanionRequestStarted [chat] -> on_request_started(bufnr=%s, id=%s)",
              tostring(event_bufnr),
              tostring(data.id)
            )
          )
        elseif args.match == "CodeCompanionRequestStreaming" then
          manager:on_request_streaming(event_bufnr)
          if data.adapter then manager:on_chat_adapter(event_bufnr, data.adapter) end
          debug(
            string.format(
              "event: CodeCompanionRequestStreaming [chat] -> on_request_streaming(bufnr=%s)",
              tostring(event_bufnr)
            )
          )
        elseif args.match == "CodeCompanionRequestFinished" then
          manager:on_request_finished(event_bufnr, data.status or "unknown")
          debug(
            string.format(
              "event: CodeCompanionRequestFinished [chat] -> on_request_finished(bufnr=%s, status=%s)",
              tostring(event_bufnr),
              data.status or "unknown"
            )
          )
        end
      end

      _spinner_instance:_ensure_ui_visible()
    end,
  })

  api.nvim_create_autocmd("User", {
    pattern = {
      "CodeCompanionToolStarted",
      "CodeCompanionToolFinished",
    },
    group = group,
    callback = function(args)
      if not manager or not _spinner_instance then return end
      if not _spinner_instance:_is_chat_tool_event(args) then return end
      local bufnr = _spinner_instance:_event_bufnr(args)
      if bufnr and _spinner_instance:_is_child_bufnr(bufnr) then return end
      if args.match == "CodeCompanionToolStarted" then
        manager:on_tool_started(bufnr, args.data and (args.data.name or args.data.tool) or "unknown")
      elseif args.match == "CodeCompanionToolFinished" then
        manager:on_tool_finished(bufnr, args.data and (args.data.name or args.data.tool) or "unknown")
      end
      _spinner_instance:_ensure_ui_visible()
    end,
  })

  api.nvim_create_autocmd("User", {
    pattern = {
      "CodeCompanionChatStopped",
      "CodeCompanionChatClosed",
      "CodeCompanionChatOpened",
      "CodeCompanionChatCreated",
      "CodeCompanionChatAdapter",
      "CodeCompanionChatModel",
      "CodeCompanionChatSubmitted",
      "CodeCompanionChatDone",
    },
    group = group,
    callback = function(args)
      if not manager or not _spinner_instance then return end

      local bufnr = _spinner_instance:_event_bufnr(args)
      if not bufnr or _spinner_instance:_is_child_bufnr(bufnr) then return end

      local match = args.match
      local data = args.data or {}

      local handlers = {
        CodeCompanionChatSubmitted = function()
          manager:on_chat_submitted(bufnr)
        end,
        CodeCompanionChatDone = function()
          manager:on_chat_done(bufnr)
        end,
        CodeCompanionChatStopped = function()
          manager:on_chat_stopped(bufnr)
        end,
        CodeCompanionChatClosed = function()
          manager:on_chat_stopped(bufnr)
          manager:on_chat_closed(bufnr)
        end,
        CodeCompanionChatOpened = function()
          manager:on_chat_opened(bufnr)
        end,
        CodeCompanionChatCreated = function()
          manager:on_chat_opened(bufnr)
        end,
        CodeCompanionChatAdapter = function()
          manager:on_chat_adapter(bufnr, data.adapter)
        end,
        CodeCompanionChatModel = function()
          manager:on_chat_model(bufnr, data.model or data.adapter)
        end,
      }

      local handler = handlers[match]
      if handler then handler() end

      _spinner_instance:_ensure_ui_visible()
    end,
  })

  -- Subagent events and InlineFinished (redundant safety cleanup)
  api.nvim_create_autocmd("User", {
    pattern = {
      "CCExtraSubagentStarted",
      "CCExtraSubagentProgress",
      "CCExtraSubagentCompleted",
      "CodeCompanionInlineFinished",
    },
    group = group,
    callback = function(args)
      if not manager then return end
      if args.match == "CodeCompanionInlineFinished" then
        -- Redundant safety: inline tracking is primarily via RequestStarted/Finished
        -- with interaction="inline", but InlineFinished ensures cleanup if missed
        manager:on_inline_finished()
      elseif args.match == "CCExtraSubagentStarted" then
        manager:on_subagent_started(
          args.data and args.data.parent_bufnr,
          args.data and args.data.child_bufnr,
          args.data or {}
        )
      elseif args.match == "CCExtraSubagentProgress" then
        manager:on_subagent_progress(
          args.data and args.data.parent_bufnr,
          args.data and args.data.child_bufnr,
          args.data and args.data.tool_count
        )
      elseif args.match == "CCExtraSubagentCompleted" then
        manager:on_subagent_completed(
          args.data and args.data.parent_bufnr,
          args.data and args.data.child_bufnr,
          args.data and args.data.status,
          args.data and args.data.duration_ms,
          args.data and args.data.tool_count
        )
      end
      _spinner_instance:_ensure_ui_visible()
    end,
  })

  api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = group,
    callback = function(args)
      if not manager then return end
      local bufnr = args.buf
      if api.nvim_buf_is_valid(bufnr) and api.nvim_get_option_value("filetype", { buf = bufnr }) == "codecompanion" then
        manager:set_active_parent(bufnr)
        _spinner_instance:_ensure_ui_visible()
      end
    end,
  })

  api.nvim_create_user_command("SpinnerNewStop", function()
    M.stop()
  end, { desc = "Stop the CodeCompanion spinner (new)" })
end

function M.stop()
  if _spinner_instance then
    _spinner_instance:_stop_animation()
    _spinner_instance:_close_window()
  end
end

function M.get_state()
  local manager = state.instance()
  if not manager then return {} end
  return manager:get_view()
end

function M.get_config()
  if _spinner_instance then return vim.deepcopy(_spinner_instance.config) end
  return vim.deepcopy(DEFAULT_CONFIG)
end

return M
