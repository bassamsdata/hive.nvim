-- Chat Hub: live sidebar showing all open chats and their subagents
-- Data sources: codecompanion chatmap, state.lua view, hierarchy sessions
-- Renders with per-segment highlights, single-pass rebuild per tick

local api = vim.api
local fmt = string.format

-- ============================================================================
-- Constants
-- ============================================================================

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local STATUS_LABELS = {
  sending = "Sending",
  streaming = "Streaming",
  tool_running = "Executing Tool",
  completed = "Done",
  error = "Error",
  cancelled = "Cancelled",
  idle = "Idle",
  running = "Running",
  pending = "Pending",
  failed = "Failed",
  stopped = "Stopped",
}

local STATUS_ICONS = {
  completed = "✓",
  error = "✗",
  failed = "✗",
  cancelled = "⊘",
  stopped = "⊘",
}

local ANIMATING_STATUSES = {
  sending = true,
  streaming = true,
  tool_running = true,
  running = true,
  pending = true,
}

local TERMINAL_STATUSES = {
  completed = true,
  error = true,
  cancelled = true,
  failed = true,
  stopped = true,
}

local DEFAULT_CONFIG = {
  width = 28,
  title = " Chats",
  update_interval_ms = 100,
  filetype = "codecompanion-chat-hub",
}

-- Reuse spinner highlight groups for visual consistency
local HL = {
  TITLE = "SpinnerInfo",
  SEPARATOR = "SpinnerConnector",
  AGENT_NAME = "SpinnerSubagent",
  CHAT_NAME = "Normal",
  MODEL = "SpinnerInfo",
  ADAPTER = "SpinnerDim",
  STATUS_ACTIVE = "SpinnerActive",
  STATUS_SUCCESS = "SpinnerSuccess",
  STATUS_ERROR = "SpinnerError",
  STATUS_DIM = "SpinnerDim",
  TIMESTAMP = "SpinnerLabel",
  CONNECTOR = "SpinnerConnector",
  FOCUS_ICON = "SpinnerSuccess",
  SUBAGENT_NAME = "SpinnerSubagent",
  CHILD_FOCUSED = "SpinnerSuccess",
  TOOL_COUNT = "SpinnerLabel",
  EMPTY = "SpinnerDim",
  INLINE_LABEL = "SpinnerActive",
}

-- ============================================================================
-- Type Definitions
-- ============================================================================

---@class CCExtra.HubEntry
---@field kind "parent"|"child"|"inline"
---@field bufnr? number
---@field line_start number  First line index (0-based) for this entry

---@class CCExtra.HubSegment
---@field text string
---@field hl string  Highlight group name

-- ============================================================================
-- ChatHub Class
-- ============================================================================

---@class CCExtra.ChatHub
---@field config table
---@field bufnr? number Panel buffer
---@field winnr? number Panel window
---@field ns_id number
---@field timer? uv.uv_timer_t
---@field entries CCExtra.HubEntry[] Flat navigable list
---@field cursor_idx number
---@field origin_win? number Window to return to when opening a chat
---@field aug? number Autocmd group ID
---@field frame number Spinner frame counter
---@field folded table<number, boolean> bufnr → folded state for subagents
local ChatHub = {}
ChatHub.__index = ChatHub

local _instance = nil

---@return CCExtra.ChatHub
function ChatHub.new()
  local self = setmetatable({}, ChatHub)
  self.config = vim.deepcopy(DEFAULT_CONFIG)
  self.bufnr = nil
  self.winnr = nil
  self.ns_id = api.nvim_create_namespace("codecompanion_chat_hub")
  self.timer = nil
  self.entries = {}
  self.cursor_idx = 1
  self.origin_win = nil
  self.aug = nil
  self.frame = 1
  self.folded = {}
  return self
end

-- ============================================================================
-- Validation & Window
-- ============================================================================

function ChatHub:_is_valid()
  return self.winnr and self.bufnr and api.nvim_win_is_valid(self.winnr) and api.nvim_buf_is_valid(self.bufnr)
end

function ChatHub:_panel_width()
  return self.config.width
end

function ChatHub:_create_window()
  self.origin_win = api.nvim_get_current_win()

  vim.cmd("topleft vsplit")
  self.winnr = api.nvim_get_current_win()

  self.bufnr = api.nvim_create_buf(false, true)
  api.nvim_win_set_buf(self.winnr, self.bufnr)

  local buf_opts =
    { buftype = "nofile", bufhidden = "wipe", swapfile = false, filetype = self.config.filetype, modifiable = false }
  for opt, val in pairs(buf_opts) do
    api.nvim_set_option_value(opt, val, { buf = self.bufnr })
  end
  vim.b[self.bufnr].miniindentscope_disable = true

  local win_opts = {
    cursorline = true,
    number = false,
    relativenumber = false,
    wrap = false,
    winfixwidth = true,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
  }
  for opt, val in pairs(win_opts) do
    api.nvim_set_option_value(opt, val, { win = self.winnr })
  end

  api.nvim_win_set_width(self.winnr, self:_panel_width())

  self:_setup_keymaps()
end

-- ============================================================================
-- Keymaps
-- ============================================================================

function ChatHub:_setup_keymaps()
  local opts = { buffer = self.bufnr, nowait = true, silent = true }
  -- stylua: ignore start 
  vim.keymap.set("n", "q",    function() self:close() end,           opts)
  vim.keymap.set("n", "j",    function() self:_move_cursor(1) end,   opts)
  vim.keymap.set("n", "k",    function() self:_move_cursor(-1) end,  opts)
  vim.keymap.set("n", "<CR>", function() self:_open_selected() end,  opts)
  vim.keymap.set("n", "x",    function() self:_close_selected() end, opts)
  vim.keymap.set("n", "R",    function() self:_render() end,         opts)
  vim.keymap.set("n", "f",    function() self:_toggle_fold() end,    opts)
  -- stylua: ignore end
end

-- ============================================================================
-- Cursor Navigation
-- ============================================================================

function ChatHub:_move_cursor(delta)
  if #self.entries == 0 then return end
  self.cursor_idx = math.max(1, math.min(#self.entries, self.cursor_idx + delta))
  self:_sync_cursor_to_entry()
end

function ChatHub:_sync_cursor_to_entry()
  if not self:_is_valid() or #self.entries == 0 then return end
  local entry = self.entries[self.cursor_idx]
  if not entry then return end
  local line = entry.line_start + 1
  local max_line = api.nvim_buf_line_count(self.bufnr)
  line = math.min(line, max_line)
  pcall(api.nvim_win_set_cursor, self.winnr, { line, 0 })
end

-- ============================================================================
-- Actions
-- ============================================================================

function ChatHub:_open_selected()
  if #self.entries == 0 then return end
  local entry = self.entries[self.cursor_idx]
  if not entry or not entry.bufnr then return end
  if not api.nvim_buf_is_valid(entry.bufnr) then return end

  local ok, codecompanion = pcall(require, "codecompanion")
  if not ok then return end

  -- Hide the currently visible chat UI (if any)
  local focused_bufnr = self:_get_focused_bufnr()
  if focused_bufnr then
    local prev_ok, prev_chat = pcall(codecompanion.buf_get_chat, focused_bufnr)
    if prev_ok and prev_chat and prev_chat.ui then prev_chat.ui:hide() end
  end

  -- Open the target chat UI using codecompanion's own mechanism
  local target_ok, target_chat = pcall(codecompanion.buf_get_chat, entry.bufnr)
  if target_ok and target_chat and target_chat.ui then
    local window_opts = target_chat.ui.window_opts or { default = true }
    target_chat.ui:open({ window_opts = window_opts })
  end

  -- Unhide in hierarchy if it was hidden
  local h_ok, hierarchy = pcall(require, "codecompanion-extra.agents.hierarchy")
  if h_ok and hierarchy.is_hidden(entry.bufnr) then hierarchy.show(entry.bufnr) end
end

function ChatHub:_close_selected()
  if #self.entries == 0 then return end
  local entry = self.entries[self.cursor_idx]
  if not entry or not entry.bufnr then return end
  if not api.nvim_buf_is_valid(entry.bufnr) then return end

  local ok, codecompanion = pcall(require, "codecompanion")
  if not ok then return end

  local chat_ok, chat = pcall(codecompanion.buf_get_chat, entry.bufnr)
  if chat_ok and chat and type(chat.close) == "function" then
    chat:close()
    self:_render()
  end
end

---Toggle fold of subagents for the selected parent entry
function ChatHub:_toggle_fold()
  if #self.entries == 0 then return end
  local entry = self.entries[self.cursor_idx]
  if not entry or not entry.bufnr then return end

  local bufnr = entry.kind == "child" and self:_get_parent_bufnr(entry.bufnr) or entry.bufnr
  if not bufnr then return end

  self.folded[bufnr] = not self.folded[bufnr]
  self:_render()
end

---Get the parent bufnr for a child bufnr
---@param child_bufnr number
---@return number|nil
function ChatHub:_get_parent_bufnr(child_bufnr)
  local ok, hierarchy = pcall(require, "codecompanion-extra.agents.hierarchy")
  if not ok then return nil end
  local session = hierarchy.get_session(child_bufnr)
  return session and session.parent_bufnr or nil
end

-- ============================================================================
-- Data Discovery
-- ============================================================================

---Get the focused codecompanion buffer (if any visible window has one)
---@return number|nil
function ChatHub:_get_focused_bufnr()
  local current_win = api.nvim_get_current_win()
  if current_win == self.winnr then
    if self.origin_win and api.nvim_win_is_valid(self.origin_win) then
      local buf = api.nvim_win_get_buf(self.origin_win)
      if api.nvim_buf_is_valid(buf) and api.nvim_get_option_value("filetype", { buf = buf }) == "codecompanion" then
        return buf
      end
    end
  else
    local buf = api.nvim_win_get_buf(current_win)
    if api.nvim_buf_is_valid(buf) and api.nvim_get_option_value("filetype", { buf = buf }) == "codecompanion" then
      return buf
    end
  end

  for _, win in ipairs(api.nvim_list_wins()) do
    if win ~= self.winnr then
      local buf = api.nvim_win_get_buf(win)
      if api.nvim_buf_is_valid(buf) and api.nvim_get_option_value("filetype", { buf = buf }) == "codecompanion" then
        return buf
      end
    end
  end

  return nil
end

---Get agent display name for a buffer
---@param bufnr number
---@return string|nil
function ChatHub:_get_agent_name(bufnr)
  local ok, agents = pcall(require, "codecompanion-extra.agents")
  if not ok then return nil end

  local agent_name = agents.active(bufnr)
  if not agent_name then return nil end

  local agent = agents.get(agent_name)
  if agent and (agent.display_name or agent.name) then
    local name = agent.display_name or agent.name
    return name:sub(1, 1):upper() .. name:sub(2)
  end

  return agent_name:sub(1, 1):upper() .. agent_name:sub(2)
end

---Discover all chats from _G.codecompanion_buffers, merged with state + hierarchy
---@return table[] parents List of parent chat data tables, sorted by bufnr
---@return table inline Inline interaction state
function ChatHub:_discover_chats()
  local state = require("codecompanion-extra.state")
  local manager = state.instance()
  local view = manager and manager:get_view() or { parents = {}, inline = {} }

  local hierarchy_ok, hierarchy = pcall(require, "codecompanion-extra.agents.hierarchy")

  -- Discover all chat buffers from codecompanion's global buffer list
  local all_bufnrs = {}
  local global_bufs = _G.codecompanion_buffers or {} ---@diagnostic disable-line: undefined-field
  for _, bufnr in ipairs(global_bufs) do
    if api.nvim_buf_is_valid(bufnr) then all_bufnrs[bufnr] = true end
  end

  -- Also include any bufnrs from state.parents (in case global list is out of sync)
  for bufnr, _ in pairs(view.parents) do
    if api.nvim_buf_is_valid(bufnr) then all_bufnrs[bufnr] = true end
  end

  -- Build parent list (filter out children)
  local parents = {}
  local focused_bufnr = self:_get_focused_bufnr()

  for bufnr, _ in pairs(all_bufnrs) do
    local is_child = hierarchy_ok and hierarchy.is_child(bufnr)
    if is_child then goto continue end
    if not api.nvim_buf_is_valid(bufnr) then goto continue end

    local state_parent = view.parents[bufnr]

    -- Get chat object from codecompanion for adapter/model info and title
    local chat_obj = nil
    local chatmap_name = nil
    local cc_ok, codecompanion = pcall(require, "codecompanion")
    if cc_ok then
      local get_ok, chat = pcall(codecompanion.buf_get_chat, bufnr)
      if get_ok and chat then
        chat_obj = chat
        chatmap_name = chat.title
      end
    end

    -- Agent name (highest priority) → chatmap name → fallback
    local agent_name = self:_get_agent_name(bufnr)
    local label = agent_name or chatmap_name or fmt("Chat #%d", bufnr)

    -- Adapter / model info
    local adapter_name = state_parent and state_parent.adapter
    local model_name = state_parent and state_parent.model

    if not adapter_name and chat_obj and chat_obj.adapter then
      adapter_name = chat_obj.adapter.formatted_name or chat_obj.adapter.name
      local m = chat_obj.adapter.schema and chat_obj.adapter.schema.model and chat_obj.adapter.schema.model.default
      if type(m) == "function" then m = m(chat_obj.adapter) end
      if type(m) == "table" then m = m.name or m.default or m.id end
      model_name = model_name or m
    end

    local status = state_parent and state_parent.status or "idle"
    local subagents = state_parent and state_parent.subagents or {}

    -- Children from hierarchy
    local children = {}
    if hierarchy_ok then
      local child_bufnrs = hierarchy.get_children(bufnr)
      for _, child_bufnr in ipairs(child_bufnrs) do
        local session = hierarchy.get_session(child_bufnr)
        if session then
          local child_state_parent = view.parents[child_bufnr]
          local child_agent = self:_get_agent_name(child_bufnr)
          local child_label = child_agent or session.agent_name
          if child_label then child_label = child_label:sub(1, 1):upper() .. child_label:sub(2) end
          child_label = child_label or fmt("Child #%d", child_bufnr)

          table.insert(children, {
            bufnr = child_bufnr,
            label = child_label,
            description = session.description or "",
            status = session.status or "pending",
            tool_count = session.tool_count or 0,
            duration_ms = session.duration_ms,
            started_at = session.started_at,
            hidden = session.hidden,
            current_tool = session.current_tool,
            is_focused = focused_bufnr == child_bufnr,
          })
        end
      end
    end

    -- Also merge subagent info from state view for children not in hierarchy
    for child_bufnr, info in pairs(subagents) do
      local already_listed = false
      for _, child in ipairs(children) do
        if child.bufnr == child_bufnr then
          already_listed = true
          break
        end
      end
      if not already_listed then
        local child_label = info.agent_name or "Unknown"
        child_label = child_label:sub(1, 1):upper() .. child_label:sub(2)
        table.insert(children, {
          bufnr = child_bufnr,
          label = child_label,
          description = info.description or "",
          status = info.status or "running",
          tool_count = info.tool_count or 0,
          duration_ms = info.duration_ms,
          started_at = info.start_time,
          hidden = true,
          is_focused = focused_bufnr == child_bufnr,
        })
      end
    end

    table.sort(children, function(a, b)
      if ANIMATING_STATUSES[a.status] and not ANIMATING_STATUSES[b.status] then return true end
      if not ANIMATING_STATUSES[a.status] and ANIMATING_STATUSES[b.status] then return false end
      return a.bufnr < b.bufnr
    end)

    -- Parent is focused if directly focused, or if any of its children are focused
    local parent_is_focused = focused_bufnr == bufnr
    if not parent_is_focused then
      for _, child in ipairs(children) do
        if child.is_focused then
          parent_is_focused = true
          break
        end
      end
    end

    table.insert(parents, {
      bufnr = bufnr,
      label = label,
      adapter = adapter_name,
      model = model_name,
      status = status,
      is_focused = parent_is_focused,
      request_started = state_parent and state_parent.request_started,
      total_started = state_parent and state_parent.total_started,
      duration_ms = state_parent and state_parent.duration_ms,
      completed_at = state_parent and state_parent.completed_at,
      current_tool = state_parent and state_parent.current_tool,
      children = children,
    })

    ::continue::
  end

  -- Stable order: sort by bufnr only (active chat is highlighted, not reordered)
  table.sort(parents, function(a, b)
    return a.bufnr < b.bufnr
  end)

  return parents, view.inline
end

-- ============================================================================
-- Time Formatting
-- ============================================================================

---@param ms number|nil
---@return string
function ChatHub:_format_duration(ms)
  if not ms then return "0s" end
  if ms < 1000 then return fmt("%dms", ms) end
  if ms < 60000 then return fmt("%.1fs", ms / 1000) end
  local mins = math.floor(ms / 60000)
  local secs = math.floor((ms % 60000) / 1000)
  return fmt("%dm %ds", mins, secs)
end

---@param parent table
---@return string
function ChatHub:_format_elapsed(parent)
  if TERMINAL_STATUSES[parent.status] then
    local ms = parent.duration_ms
    if not ms and parent.completed_at and parent.total_started then
      ms = parent.completed_at - parent.total_started
    elseif not ms and parent.completed_at and parent.request_started then
      ms = parent.completed_at - parent.request_started
    end
    return self:_format_duration(ms)
  end

  local start = parent.total_started or parent.request_started
  if not start then return "" end
  local elapsed_ms = vim.uv.now() - start
  return self:_format_duration(elapsed_ms)
end

---@param child table
---@return string
function ChatHub:_format_child_elapsed(child)
  if child.duration_ms then return self:_format_duration(child.duration_ms) end
  if not child.started_at then return "" end
  -- started_at is hrtime nanoseconds for hierarchy sessions
  local elapsed_ms = math.floor((vim.uv.hrtime() - child.started_at) / 1000000)
  return self:_format_duration(elapsed_ms)
end

-- ============================================================================
-- Line Building (per-segment highlights)
-- ============================================================================

---@return string
function ChatHub:_spinner_char()
  return SPINNER_FRAMES[self.frame] or SPINNER_FRAMES[1]
end

---Build a separator line
---@param width number
---@return CCExtra.HubSegment[]
function ChatHub:_build_separator(width)
  return { { text = string.rep("─", width), hl = HL.SEPARATOR } }
end

---Build the header line for a parent chat
---@param parent table
---@param is_folded boolean
---@return CCExtra.HubSegment[]
function ChatHub:_build_parent_header(parent, is_folded)
  local segments = {}

  -- Focus indicator
  if parent.is_focused then
    table.insert(segments, { text = "● ", hl = HL.FOCUS_ICON })
  else
    table.insert(segments, { text = "  ", hl = HL.EMPTY })
  end

  -- Agent/chat name
  local name_hl = parent.is_focused and HL.AGENT_NAME or HL.CHAT_NAME
  table.insert(segments, { text = parent.label, hl = name_hl })

  -- Fold indicator (only when there are children)
  if #parent.children > 0 then
    local fold_icon = is_folded and " ▸" or " ▾"
    table.insert(segments, { text = fold_icon, hl = HL.STATUS_DIM })
  end

  -- Current label
  if parent.is_focused then table.insert(segments, { text = " (current)", hl = HL.FOCUS_ICON }) end

  return segments
end

---Build the model/adapter info line
---@param parent table
---@return CCExtra.HubSegment[]|nil
function ChatHub:_build_model_line(parent)
  local model = parent.model
  local adapter = parent.adapter
  if not model and not adapter then return nil end

  local segments = {}
  table.insert(segments, { text = "  ", hl = HL.EMPTY })

  if model then
    if type(model) == "table" then model = model.name or model.default or model.id end
    table.insert(segments, { text = tostring(model), hl = HL.MODEL })
  end

  if adapter then
    if model then table.insert(segments, { text = " ", hl = HL.EMPTY }) end
    table.insert(segments, { text = "(", hl = HL.ADAPTER })
    table.insert(segments, { text = tostring(adapter), hl = HL.ADAPTER })
    table.insert(segments, { text = ")", hl = HL.ADAPTER })
  end

  return segments
end

---Build the status line for a parent chat (skip idle — no status line needed)
---@param parent table
---@return CCExtra.HubSegment[]|nil
function ChatHub:_build_status_line(parent)
  local status = parent.status or "idle"
  if status == "idle" then return nil end

  local segments = {}
  table.insert(segments, { text = "  ", hl = HL.EMPTY })

  local status_label = STATUS_LABELS[status] or status

  if ANIMATING_STATUSES[status] then
    table.insert(segments, { text = status_label .. " ", hl = HL.STATUS_ACTIVE })
    table.insert(segments, { text = self:_spinner_char(), hl = HL.STATUS_ACTIVE })

    if parent.current_tool and status == "tool_running" then
      table.insert(segments, { text = ": " .. parent.current_tool, hl = HL.STATUS_DIM })
    end
  elseif status == "completed" then
    local icon = STATUS_ICONS.completed or "✓"
    table.insert(segments, { text = icon .. " " .. status_label, hl = HL.STATUS_SUCCESS })
  elseif status == "error" or status == "failed" then
    local icon = STATUS_ICONS.error or "✗"
    table.insert(segments, { text = icon .. " " .. status_label, hl = HL.STATUS_ERROR })
  elseif status == "cancelled" or status == "stopped" then
    local icon = STATUS_ICONS[status] or "⊘"
    table.insert(segments, { text = icon .. " " .. status_label, hl = HL.STATUS_DIM })
  end

  local elapsed = self:_format_elapsed(parent)
  if elapsed ~= "" then table.insert(segments, { text = "  " .. elapsed, hl = HL.TIMESTAMP }) end

  return segments
end

---Build a child/subagent line
---@param child table
---@param is_last boolean
---@return CCExtra.HubSegment[] header_segments
---@return CCExtra.HubSegment[] status_segments
function ChatHub:_build_child_lines(child, is_last)
  local connector = is_last and "└─ " or "├─ "
  local status_pad = is_last and "   " or "│  "
  local status = child.status or "running"

  -- Header line: focus dot + connector + name + description
  local header = {}
  if child.is_focused then
    table.insert(header, { text = "● ", hl = HL.CHILD_FOCUSED })
  else
    table.insert(header, { text = "  ", hl = HL.EMPTY })
  end
  table.insert(header, { text = connector, hl = HL.CONNECTOR })
  table.insert(header, { text = child.label, hl = HL.SUBAGENT_NAME })
  if child.description and child.description ~= "" then
    local desc = child.description
    if #desc > 30 then desc = desc:sub(1, 27) .. "..." end
    table.insert(header, { text = ": " .. desc, hl = HL.STATUS_DIM })
  end

  -- Status line: status + tool count + elapsed
  local status_segs = {}
  local status_indent = child.is_focused and "  " or "  "
  table.insert(status_segs, { text = status_indent .. status_pad, hl = HL.CONNECTOR })

  local status_label = STATUS_LABELS[status] or status

  if ANIMATING_STATUSES[status] then
    table.insert(status_segs, { text = self:_spinner_char() .. " ", hl = HL.STATUS_ACTIVE })
    table.insert(status_segs, { text = status_label, hl = HL.STATUS_ACTIVE })
  elseif status == "completed" then
    table.insert(
      status_segs,
      { text = (STATUS_ICONS.completed or "✓") .. " " .. status_label, hl = HL.STATUS_SUCCESS }
    )
  elseif status == "error" or status == "failed" then
    table.insert(status_segs, { text = (STATUS_ICONS.error or "✗") .. " " .. status_label, hl = HL.STATUS_ERROR })
  else
    local icon = STATUS_ICONS[status] or ""
    local prefix = icon ~= "" and (icon .. " ") or ""
    table.insert(status_segs, { text = prefix .. status_label, hl = HL.STATUS_DIM })
  end

  local calls_text = child.tool_count and child.tool_count > 0 and fmt("  %d calls", child.tool_count) or "  0 calls"
  table.insert(status_segs, { text = calls_text, hl = HL.TOOL_COUNT })

  local elapsed = self:_format_child_elapsed(child)
  if elapsed ~= "" then table.insert(status_segs, { text = "  " .. elapsed, hl = HL.TIMESTAMP }) end

  if child.hidden then table.insert(status_segs, { text = "  (hidden)", hl = HL.STATUS_DIM }) end

  return header, status_segs
end

---Build inline interaction line
---@param inline table
---@return CCExtra.HubSegment[]
function ChatHub:_build_inline_line(inline)
  local segments = {}
  table.insert(segments, { text = "  ", hl = HL.EMPTY })

  local status = inline.status or "idle"

  if status == "sending" then
    table.insert(segments, { text = "Inline ", hl = HL.INLINE_LABEL })
    table.insert(segments, { text = self:_spinner_char(), hl = HL.STATUS_ACTIVE })
  elseif status == "completed" then
    table.insert(segments, { text = "✓ Inline Done", hl = HL.STATUS_SUCCESS })
  elseif status == "error" then
    table.insert(segments, { text = "✗ Inline Error", hl = HL.STATUS_ERROR })
  end

  if inline.started_at then
    local elapsed_ms
    if inline.duration_ms then
      elapsed_ms = inline.duration_ms
    else
      elapsed_ms = vim.uv.now() - inline.started_at
    end
    table.insert(segments, { text = "  " .. self:_format_duration(elapsed_ms), hl = HL.TIMESTAMP })
  end

  if inline.model then table.insert(segments, { text = "  " .. tostring(inline.model), hl = HL.MODEL }) end

  return segments
end

-- ============================================================================
-- Full Render
-- ============================================================================

---Convert segments to plain text
---@param segments CCExtra.HubSegment[]
---@return string
local function segments_to_text(segments)
  local parts = {}
  for _, seg in ipairs(segments) do
    table.insert(parts, seg.text)
  end
  return table.concat(parts)
end

---Apply segment highlights to a buffer line
---@param bufnr number
---@param ns_id number
---@param line_idx number 0-based
---@param segments CCExtra.HubSegment[]
local function apply_segment_highlights(bufnr, ns_id, line_idx, segments)
  local col = 0
  for _, seg in ipairs(segments) do
    local byte_len = #seg.text
    if byte_len > 0 then
      pcall(api.nvim_buf_set_extmark, bufnr, ns_id, line_idx, col, { end_col = col + byte_len, hl_group = seg.hl })
    end

    col = col + byte_len
  end
end

function ChatHub:_render()
  if not self:_is_valid() then return end

  local parents, inline = self:_discover_chats()

  -- Build all lines
  local all_lines = {} -- { { text, segments, entry? } }
  local panel_width = self:_panel_width()

  -- Title
  table.insert(all_lines, {
    text = nil,
    segments = { { text = self.config.title, hl = HL.TITLE } },
  })
  table.insert(all_lines, { text = nil, segments = self:_build_separator(panel_width) })

  -- Inline interaction (if active)
  if inline and inline.active then
    local inline_segs = self:_build_inline_line(inline)
    table.insert(all_lines, {
      text = nil,
      segments = inline_segs,
      entry = { kind = "inline", bufnr = nil },
    })
    table.insert(all_lines, { text = nil, segments = { { text = "", hl = HL.EMPTY } } })
  end

  -- Parent chats
  if #parents == 0 and not (inline and inline.active) then
    table.insert(all_lines, {
      text = nil,
      segments = { { text = "  No open chats", hl = HL.EMPTY } },
    })
  end

  for parent_idx, parent in ipairs(parents) do
    -- Blank line between parents (but not before the first one)
    if parent_idx > 1 then table.insert(all_lines, { text = nil, segments = { { text = "", hl = HL.EMPTY } } }) end

    -- Parent header (navigable)
    local header_segs = self:_build_parent_header(parent, self.folded[parent.bufnr])
    table.insert(all_lines, {
      text = nil,
      segments = header_segs,
      entry = { kind = "parent", bufnr = parent.bufnr },
    })

    -- Model line
    local model_segs = self:_build_model_line(parent)
    if model_segs then table.insert(all_lines, { text = nil, segments = model_segs }) end

    -- Status line (omitted when idle)
    local status_segs = self:_build_status_line(parent)
    if status_segs then table.insert(all_lines, { text = nil, segments = status_segs }) end

    -- Children (skip when parent is folded)
    if not self.folded[parent.bufnr] then
      for child_idx, child in ipairs(parent.children) do
        local is_last = child_idx == #parent.children
        local child_header, child_status = self:_build_child_lines(child, is_last)

        table.insert(all_lines, {
          text = nil,
          segments = child_header,
          entry = child.bufnr and { kind = "child", bufnr = child.bufnr } or nil,
        })
        table.insert(all_lines, { text = nil, segments = child_status })
      end
    elseif #parent.children > 0 then
      table.insert(all_lines, {
        text = nil,
        segments = { { text = fmt("  ▸ %d subagent(s) folded", #parent.children), hl = HL.STATUS_DIM } },
      })
    end
  end

  -- Convert to buffer text and track entries
  local buf_lines = {}
  local line_segments = {}
  self.entries = {}

  for _, item in ipairs(all_lines) do
    local text = item.text or segments_to_text(item.segments)
    table.insert(buf_lines, text)
    table.insert(line_segments, item.segments)

    if item.entry then
      item.entry.line_start = #buf_lines - 1
      table.insert(self.entries, item.entry)
    end
  end

  -- Write to buffer
  api.nvim_set_option_value("modifiable", true, { buf = self.bufnr })
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, buf_lines)
  api.nvim_set_option_value("modifiable", false, { buf = self.bufnr })

  -- Apply highlights
  api.nvim_buf_clear_namespace(self.bufnr, self.ns_id, 0, -1)
  for line_idx, segments in ipairs(line_segments) do
    apply_segment_highlights(self.bufnr, self.ns_id, line_idx - 1, segments)
  end

  -- Restore cursor
  if #self.entries > 0 then
    self.cursor_idx = math.max(1, math.min(self.cursor_idx, #self.entries))
    self:_sync_cursor_to_entry()
  end
end

-- ============================================================================
-- Timer
-- ============================================================================

---Check if any interaction needs animation
---@return boolean
function ChatHub:_needs_animation()
  local state = require("codecompanion-extra.state")
  local manager = state.instance()
  if not manager then return false end

  local view = manager:get_view()
  if view.inline and view.inline.active and view.inline.status == "sending" then return true end

  for _, parent in pairs(view.parents) do
    if ANIMATING_STATUSES[parent.status] then return true end
  end

  return false
end

function ChatHub:_start_timer()
  if self.timer then return end
  self.timer = vim.uv.new_timer()
  self.timer:start(
    0,
    self.config.update_interval_ms,
    vim.schedule_wrap(function()
      if not self:_is_valid() then
        self:_stop_timer()
        return
      end
      self.frame = (self.frame % #SPINNER_FRAMES) + 1
      self:_render()

      if not self:_needs_animation() then self:_stop_timer() end
    end)
  )
end

function ChatHub:_stop_timer()
  if self.timer and not self.timer:is_closing() then
    self.timer:stop()
    self.timer:close()
  end
  self.timer = nil
end

---Ensure timer is running if needed, start it if not
function ChatHub:_ensure_timer()
  if not self:_is_valid() then return end
  if self:_needs_animation() and not self.timer then self:_start_timer() end
end

-- ============================================================================
-- Event Subscriptions
-- ============================================================================

function ChatHub:_subscribe_events()
  self.aug = api.nvim_create_augroup("CodeCompanionChatHub", { clear = true })

  local state = require("codecompanion-extra.state")
  local manager = state.instance()

  if manager then
    local function on_state_change()
      if not self:_is_valid() then return end
      self:_render()
      self:_ensure_timer()
    end

    manager:on("parent_updated", on_state_change)
    manager:on("parent_created", on_state_change)
    manager:on("parent_removed", on_state_change)
    manager:on("parent_reset", on_state_change)
    manager:on("inline_updated", on_state_change)
    manager:on("active_parent_changed", on_state_change)
  end

  -- Catch chats that codecompanion creates (might not trigger state events immediately)
  api.nvim_create_autocmd("User", {
    group = self.aug,
    pattern = {
      "CodeCompanionChatCreated",
      "CodeCompanionChatOpened",
      "CodeCompanionChatClosed",
      "CodeCompanionChatAdapter",
      "CodeCompanionChatModel",
    },
    callback = function()
      if not self:_is_valid() then return end
      vim.schedule(function()
        self:_render()
        self:_ensure_timer()
      end)
    end,
  })

  -- Focus tracking
  api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = self.aug,
    callback = function()
      if not self:_is_valid() then return end
      self:_render()
    end,
  })

  -- Clean up when panel buffer is wiped
  api.nvim_create_autocmd("BufWipeout", {
    group = self.aug,
    buffer = self.bufnr,
    callback = function()
      self:_stop_timer()
      self.winnr = nil
      self.bufnr = nil
    end,
  })
end

function ChatHub:_unsubscribe_events()
  if self.aug then
    pcall(api.nvim_del_augroup_by_id, self.aug)
    self.aug = nil
  end
end

-- ============================================================================
-- Public Lifecycle
-- ============================================================================

function ChatHub:open()
  if self:_is_valid() then
    api.nvim_set_current_win(self.winnr)
    return
  end

  self:_create_window()
  self:_subscribe_events()
  self:_render()
  self:_ensure_timer()
end

function ChatHub:close()
  self:_stop_timer()
  self:_unsubscribe_events()
  if self.winnr and api.nvim_win_is_valid(self.winnr) then api.nvim_win_close(self.winnr, true) end
  self.winnr = nil
  self.bufnr = nil
end

function ChatHub:toggle()
  if self:_is_valid() then
    self:close()
  else
    self:open()
  end
end

-- ============================================================================
-- Module (singleton)
-- ============================================================================

local M = {}

function M.open()
  if not _instance then _instance = ChatHub.new() end
  _instance:open()
end

function M.close()
  if _instance then _instance:close() end
end

function M.toggle()
  if not _instance then _instance = ChatHub.new() end
  _instance:toggle()
end

function M.refresh()
  if not _instance or not _instance:_is_valid() then return end
  _instance:_render()
  _instance:_ensure_timer()
end

return M
