-- State manager for CodeCompanion Extra UI surfaces
-- Owns parent/subagent/inline state and timers, exposes a safe view for renderers
--
-- Interaction types:
--   "chat"   → tracked in self.parents[bufnr] (CCExtra.ParentState)
--   "inline" → tracked in self.inline (CCExtra.InlineState)
--
-- Adding a future interaction type (e.g. "background"):
--   1. Add a CCExtra.<Type>State class and field on StateManager
--   2. Add on_<type>_started / on_<type>_finished lifecycle methods
--   3. Add the state to get_view() return value
--   4. Wire event routing in spinner.lua

local DEBUG_LOG_PATH = vim.fn.stdpath("data") .. "/ccextra_debug.log"
local M = {}

-- local function debug_log(msg)
--   local f = io.open(DEBUG_LOG_PATH, "a")
--   if f then
--     f:write(string.format("[%s] [state] %s\n", os.date("%H:%M:%S"), msg))
--     f:close()
--   end
-- end

-- ============================================================================
-- Type Definitions
-- ============================================================================

---@class CCExtra.SubagentInfo
---@field child_bufnr number
---@field agent_name string
---@field agent_type string "task"|"consult"
---@field status "running"|"completed"|"failed"|"stopped"|"cancelled"
---@field tool_count number
---@field description? string
---@field start_time number vim.uv.now() milliseconds
---@field duration_ms? number Final duration after completion

---@class CCExtra.ParentState
---@field bufnr number
---@field status "idle"|"sending"|"streaming"|"tool_running"|"completed"|"error"|"cancelled"
---@field request_id? number|string
---@field request_started? number
---@field total_started? number
---@field duration_ms? number
---@field completed_at? number
---@field request_finished boolean
---@field request_final_status? "completed"|"error"|"cancelled"
---@field adapter? string
---@field model? string
---@field provider? string
---@field interaction_type? string
---@field current_tool? string
---@field active_tools table<string, boolean>
---@field subagents table<number, CCExtra.SubagentInfo>
---@field active_subagent_count number
---@field completion_timer? uv.uv_timer_t
---@field subagent_cleanup_timers table<number, uv.uv_timer_t>

---@class CCExtra.InlineState
---@field active boolean Whether an inline interaction is in progress or showing completion
---@field status "idle"|"sending"|"completed"|"error"
---@field request_id? number|string
---@field started_at? number vim.uv.now() milliseconds
---@field completed_at? number
---@field duration_ms? number
---@field adapter? string
---@field model? string
---@field provider? string
---@field bufnr? number The code buffer being modified
---@field completion_timer? uv.uv_timer_t

---@class CCExtra.StateView
---@field parents table<number, table>
---@field active_parent_bufnr? number
---@field inline table

---@class CCExtra.StateManager
---@field config table
---@field parents table<number, CCExtra.ParentState>
---@field inline CCExtra.InlineState
---@field active_parent_bufnr number|nil
---@field callbacks table<string, function[]>
local StateManager = {}
StateManager.__index = StateManager

local COMPLETION_DISPLAY_TIME = 3000 -- ms to show "completed" before transitioning to idle

-- ============================================================================
-- Constructor
-- ============================================================================

---@param config table
---@return CCExtra.StateManager
function StateManager.new(config)
  local self = setmetatable({}, StateManager)
  self.config = config or {}
  self.parents = {}
  self.inline = StateManager._create_inline_state()
  self.active_parent_bufnr = nil
  self.callbacks = {}
  return self
end

-- ============================================================================
-- Event Callback System
-- ============================================================================

---Register a callback for state events
---@param event string
---@param cb fun(...)
function StateManager:on(event, cb)
  if not self.callbacks[event] then self.callbacks[event] = {} end
  table.insert(self.callbacks[event], cb)
end

---@param event string
---@param ... any
function StateManager:_emit(event, ...)
  local list = self.callbacks[event]
  if not list then return end
  for _, cb in ipairs(list) do
    cb(...)
  end
end

-- ============================================================================
-- Chat Parent State
-- ============================================================================

---@param bufnr number
---@return CCExtra.ParentState
function StateManager:_create_parent_state(bufnr)
  return {
    bufnr = bufnr,
    status = "idle",
    request_id = nil,
    request_started = nil,
    total_started = nil,
    duration_ms = nil,
    completed_at = nil,
    request_finished = false,
    request_final_status = nil,
    adapter = nil,
    model = nil,
    provider = nil,
    interaction_type = nil,
    current_tool = nil,
    active_tools = {},
    subagents = {},
    active_subagent_count = 0,
    completion_timer = nil,
    subagent_cleanup_timers = {},
  }
end

---@param bufnr number
---@param create? boolean
---@return CCExtra.ParentState|nil
function StateManager:get_parent(bufnr, create)
  if not bufnr then return nil end
  local parent = self.parents[bufnr]
  if not parent and create then
    parent = self:_create_parent_state(bufnr)
    self.parents[bufnr] = parent
    self:_emit("parent_created", bufnr, parent)
  end
  return parent
end

---Remove a parent entirely
---@param bufnr number
function StateManager:remove_parent(bufnr)
  if not self.parents[bufnr] then return end
  self:cancel_completion_timer(bufnr)
  self:cancel_subagent_cleanup_timers(bufnr)
  self.parents[bufnr] = nil
  if self.active_parent_bufnr == bufnr then self.active_parent_bufnr = nil end
  self:_emit("parent_removed", bufnr)
end

---Reset a parent to idle but keep it registered
---@param bufnr number
function StateManager:reset_parent_state(bufnr)
  local parent = self.parents[bufnr]
  if not parent then return end
  self:cancel_completion_timer(bufnr)
  self:cancel_subagent_cleanup_timers(bufnr)
  parent.status = "idle"
  parent.request_id = nil
  parent.request_started = nil
  parent.total_started = nil
  parent.duration_ms = nil
  parent.completed_at = nil
  parent.request_finished = false
  parent.request_final_status = nil
  parent.current_tool = nil
  parent.active_tools = {}
  parent.subagents = {}
  parent.active_subagent_count = 0
  self:_emit("parent_reset", bufnr, parent)
end

---Update adapter/model/provider on a chat parent
---@param bufnr number
---@param adapter table
function StateManager:set_adapter(bufnr, adapter)
  local parent = self:get_parent(bufnr, true)
  if not parent or not adapter then return end
  parent.adapter = adapter.formatted_name or adapter.name or parent.adapter
  local model = adapter.model
  if type(model) == "table" then model = model.name or model.default or model.id or model.model end
  parent.model = model or parent.model
  parent.provider = adapter.provider or parent.provider
  self:_emit("parent_updated", bufnr, parent)
end

---@param bufnr number
---@param interaction string
function StateManager:set_interaction(bufnr, interaction)
  local parent = self:get_parent(bufnr, true)
  if not parent or not interaction then return end
  parent.interaction_type = interaction
  self:_emit("parent_updated", bufnr, parent)
end

---@param bufnr number
---@param request_id number|string|nil
function StateManager:on_request_started(bufnr, request_id)
  local parent = self:get_parent(bufnr, true)
  if not parent then return end
  parent.status = "sending"
  parent.request_id = request_id
  local now = vim.uv.now()
  parent.request_started = now
  parent.request_finished = false
  parent.request_final_status = nil
  parent.duration_ms = nil
  parent.completed_at = nil
  parent.current_tool = nil
  parent.active_tools = {}
  self:_emit("parent_updated", bufnr, parent)
end

---@param bufnr number
function StateManager:on_chat_submitted(bufnr)
  local parent = self:get_parent(bufnr, true)
  if not parent then return end

  -- NOTE: Cancel any pending completion timer from a previous cycle.
  -- If a timer was running, the previous cycle was finalized (ChatDone fired)
  -- but the idle transition hasn't happened yet = fast resubmit = new cycle.
  local cancelled_timer = self:cancel_completion_timer(bufnr)
  if cancelled_timer then
    parent.total_started = nil
    parent.duration_ms = nil
    parent.completed_at = nil
  end

  M.debug_log(
    string.format(
      "on_chat_submitted: bufnr=%d | cancelled_timer=%s | BEFORE: total_started=%s | duration_ms=%s | completed_at=%s",
      bufnr,
      cancelled_timer and "yes" or "no",
      parent.total_started or "nil",
      parent.duration_ms or "nil",
      parent.completed_at or "nil"
    )
  )

  -- NOTE: This is guard: don't reset total_started during multi-round tool cycles.
  -- Between ChatSubmitted and ChatDone, completed_at is nil (only set by _finalize_chat_duration).
  -- So total_started set + completed_at nil = mid-cycle continuation.
  if parent.total_started and not parent.completed_at then
    M.debug_log(string.format("  early return: mid-cycle continuation"))
    return
  end

  parent.total_started = vim.uv.now()
  parent.duration_ms = nil
  parent.completed_at = nil
  M.debug_log(
    string.format(
      "  AFTER:  total_started=%d | duration_ms=%s | completed_at=%s",
      parent.total_started,
      parent.duration_ms or "nil",
      parent.completed_at or "nil"
    )
  )
  self:_emit("parent_updated", bufnr, parent)
end

---@param bufnr number
---@param final_status "completed"|"cancelled"
function StateManager:_finalize_chat_duration(bufnr, final_status)
  local parent = self:get_parent(bufnr, true)
  if not parent then return end
  if not parent.total_started and not parent.request_started then return end

  parent.completed_at = parent.completed_at or vim.uv.now()
  if parent.total_started then
    parent.duration_ms = parent.completed_at - parent.total_started
  elseif parent.request_started then
    parent.duration_ms = parent.completed_at - parent.request_started
  end

  parent.status = final_status
  self:_emit("request_completed", bufnr, parent)
  self:schedule_completion(bufnr)
  self:_emit("parent_updated", bufnr, parent)
end

---@param bufnr number
function StateManager:on_chat_done(bufnr)
  self:_finalize_chat_duration(bufnr, "completed")
end

---@param bufnr number
function StateManager:on_chat_stopped(bufnr)
  self:_finalize_chat_duration(bufnr, "cancelled")
end

---@param bufnr number
function StateManager:on_request_streaming(bufnr)
  local parent = self:get_parent(bufnr, true)
  if not parent then return end
  if parent.status == "sending" or parent.status == "idle" then parent.status = "streaming" end
  self:_emit("parent_updated", bufnr, parent)
end

---@param bufnr number
---@param status "success"|"error"|"cancelled"|string
function StateManager:on_request_finished(bufnr, status)
  M.debug_log("on_request_finished called, bufnr=" .. tostring(bufnr) .. " status=" .. tostring(status))
  local parent = self:get_parent(bufnr, true)
  if not parent then return end
  local final_status
  if status == "success" then
    final_status = "completed"
  elseif status == "error" then
    final_status = "error"
  else
    final_status = "cancelled"
  end

  parent.request_finished = true
  parent.request_final_status = final_status

  if not parent.current_tool and vim.tbl_isempty(parent.active_tools) then
    parent.status = final_status
    M.debug_log("  set status to: " .. final_status)
  end

  -- NOTE: The idle transition is only triggered
  -- by ChatDone/ChatStopped via _finalize_chat_duration -> schedule_completion.
  -- This prevents premature idle when tools start after a gap.
  self:_emit("parent_updated", bufnr, parent)
end

---@param bufnr number
---@param tool_name string
function StateManager:on_tool_started(bufnr, tool_name)
  local parent = self:get_parent(bufnr, true)
  if not parent or not tool_name then return end
  parent.active_tools[tool_name] = true
  parent.current_tool = tool_name
  parent.status = "tool_running"
  self:_emit("parent_updated", bufnr, parent)
end

---@param bufnr number
---@param tool_name string
function StateManager:on_tool_finished(bufnr, tool_name)
  local parent = self:get_parent(bufnr, true)
  if not parent then return end
  parent.active_tools[tool_name] = nil

  local remaining_tools = vim.tbl_keys(parent.active_tools)
  if #remaining_tools > 0 then
    parent.current_tool = remaining_tools[1]
    parent.status = "tool_running"
  else
    parent.current_tool = nil
    if parent.request_finished then
      parent.status = parent.request_final_status or "completed"
    elseif parent.request_id and parent.status ~= "completed" then
      parent.status = "streaming"
    else
      parent.status = "streaming"
    end
  end

  self:_emit("parent_updated", bufnr, parent)
end

-- ============================================================================
-- Subagent State
-- ============================================================================

---@param parent_bufnr number
---@param child_bufnr number
---@param info table
function StateManager:on_subagent_started(parent_bufnr, child_bufnr, info)
  local parent = self:get_parent(parent_bufnr, true)
  if not parent then return end
  parent.subagents[child_bufnr] = {
    child_bufnr = child_bufnr,
    agent_name = info.agent_name or "unknown",
    agent_type = info.agent_type or "task",
    status = "running",
    tool_count = 0,
    description = info.description,
    start_time = vim.uv.now(),
  }
  parent.active_subagent_count = parent.active_subagent_count + 1
  self:_emit("parent_updated", parent_bufnr, parent)
end

---@param parent_bufnr number
---@param child_bufnr number
---@param tool_count number
function StateManager:on_subagent_progress(parent_bufnr, child_bufnr, tool_count)
  local parent = self.parents[parent_bufnr]
  if not parent then return end
  local info = parent.subagents[child_bufnr]
  if info then info.tool_count = tool_count or (info.tool_count + 1) end
  self:_emit("parent_updated", parent_bufnr, parent)
end

---@param parent_bufnr number
---@param child_bufnr number
---@param status string
---@param duration_ms number
---@param tool_count? number
function StateManager:on_subagent_completed(parent_bufnr, child_bufnr, status, duration_ms, tool_count)
  local parent = self.parents[parent_bufnr]
  if not parent then return end
  local info = parent.subagents[child_bufnr]
  if not info or info.status ~= "running" then return end

  info.status = status == "success" and "completed" or (status or "failed")
  info.tool_count = tool_count or info.tool_count
  info.duration_ms = duration_ms or (vim.uv.now() - info.start_time)
  parent.active_subagent_count = math.max(0, parent.active_subagent_count - 1)

  self:schedule_subagent_cleanup(parent_bufnr, child_bufnr)
  self:_emit("parent_updated", parent_bufnr, parent)
end

-- ============================================================================
-- Inline State
-- ============================================================================

---@return CCExtra.InlineState
function StateManager._create_inline_state()
  return {
    active = false,
    status = "idle",
    request_id = nil,
    started_at = nil,
    completed_at = nil,
    duration_ms = nil,
    adapter = nil,
    model = nil,
    provider = nil,
    bufnr = nil,
    completion_timer = nil,
  }
end

---@param inline CCExtra.InlineState
local function _safe_close_inline_timer(inline)
  if inline.completion_timer and not inline.completion_timer:is_closing() then
    inline.completion_timer:stop()
    inline.completion_timer:close()
  end
  inline.completion_timer = nil
end

---Reset inline state back to idle
function StateManager:_reset_inline()
  _safe_close_inline_timer(self.inline)
  self.inline = StateManager._create_inline_state()
  self:_emit("inline_updated")
end

---@param bufnr? number The code buffer being modified
---@param adapter? table Adapter info from the event data
function StateManager:on_inline_started(bufnr, adapter)
  M.debug_log("on_inline_started called, bufnr=" .. tostring(bufnr))

  -- Cancel any previous inline completion timer
  _safe_close_inline_timer(self.inline)

  self.inline.active = true
  self.inline.status = "sending"
  self.inline.started_at = vim.uv.now()
  self.inline.completed_at = nil
  self.inline.duration_ms = nil
  self.inline.bufnr = bufnr

  if adapter then
    self.inline.adapter = adapter.formatted_name or adapter.name
    local model = adapter.model
    if type(model) == "table" then model = model.name or model.default or model.id or model.model end
    self.inline.model = model
    self.inline.provider = adapter.provider
  end

  self:_emit("inline_updated")
end

---@param status? "success"|"error"|string
function StateManager:on_inline_finished(status)
  M.debug_log("on_inline_finished called, status=" .. tostring(status))
  if not self.inline.active then return end

  local now = vim.uv.now()
  self.inline.completed_at = now
  if self.inline.started_at then self.inline.duration_ms = now - self.inline.started_at end

  if status == "error" then
    self.inline.status = "error"
  else
    self.inline.status = "completed"
  end

  -- Start completion timer to transition back to idle
  local display_time = (self.config.display and self.config.display.completion_display_time) or COMPLETION_DISPLAY_TIME
  local timer = vim.uv.new_timer()
  self.inline.completion_timer = timer
  timer:start(
    display_time,
    0,
    vim.schedule_wrap(function()
      M.debug_log("inline completion timer fired")
      self:_reset_inline()
    end)
  )

  self:_emit("inline_updated")
end

-- ============================================================================
-- Chat Buffer Events
-- ============================================================================

---@param bufnr number
function StateManager:on_chat_opened(bufnr)
  self:get_parent(bufnr, true)
  self:_emit("parent_updated", bufnr, self.parents[bufnr])
end

---@param bufnr number
function StateManager:set_active_parent(bufnr)
  if not bufnr then return end
  self:get_parent(bufnr, true)
  self.active_parent_bufnr = bufnr
  self:_emit("active_parent_changed", bufnr)
end

---@param bufnr number
function StateManager:on_chat_closed(bufnr)
  self:remove_parent(bufnr)
end

---@param bufnr number
---@param adapter table
function StateManager:on_chat_adapter(bufnr, adapter)
  self:set_adapter(bufnr, adapter)
end

---@param bufnr number
---@param adapter table
function StateManager:on_chat_model(bufnr, adapter)
  self:set_adapter(bufnr, adapter)
end

-- ============================================================================
-- Timer Management
-- ============================================================================

---Cancel completion timer for a parent
---@param bufnr number
---@return boolean cancelled Whether a timer was actually cancelled
function StateManager:cancel_completion_timer(bufnr)
  local parent = self.parents[bufnr]
  if not parent or not parent.completion_timer then return false end
  if not parent.completion_timer:is_closing() then
    parent.completion_timer:stop()
    parent.completion_timer:close()
  end
  parent.completion_timer = nil
  return true
end

---Cancel subagent cleanup timers for a parent
---@param bufnr number
function StateManager:cancel_subagent_cleanup_timers(bufnr)
  local parent = self.parents[bufnr]
  if not parent then return end
  for child_bufnr, timer in pairs(parent.subagent_cleanup_timers) do
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    parent.subagent_cleanup_timers[child_bufnr] = nil
  end
end

---Schedule reset of a parent after completion display delay
---@param bufnr number
function StateManager:schedule_completion(bufnr)
  local parent = self.parents[bufnr]
  if not parent then return end
  self:cancel_completion_timer(bufnr)

  local display_time = (self.config.display and self.config.display.completion_display_time) or 3000
  parent.completion_timer = vim.uv.new_timer()
  parent.completion_timer:start(
    display_time,
    0,
    vim.schedule_wrap(function()
      if parent.status == "completed" or parent.status == "error" or parent.status == "cancelled" then
        self:reset_parent_state(bufnr)
      end
    end)
  )
end

---Schedule removal of a subagent entry
---@param parent_bufnr number
---@param child_bufnr number
function StateManager:schedule_subagent_cleanup(parent_bufnr, child_bufnr)
  local parent = self.parents[parent_bufnr]
  if not parent then return end

  local existing = parent.subagent_cleanup_timers[child_bufnr]
  if existing and not existing:is_closing() then
    existing:stop()
    existing:close()
  end

  local delay = (self.config.display and self.config.display.subagent_completion_display_time) or 2500
  local timer = vim.uv.new_timer()
  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      parent.subagents[child_bufnr] = nil
      parent.subagent_cleanup_timers[child_bufnr] = nil
      self:_emit("parent_updated", parent_bufnr, parent)
    end)
  )
  parent.subagent_cleanup_timers[child_bufnr] = timer
end

-- ============================================================================
-- View (safe snapshot for UI consumers)
-- ============================================================================

---Snapshot without userdata for UI consumers
---@return CCExtra.StateView
function StateManager:get_view()
  local ok, hierarchy = pcall(require, "codecompanion-extra.agents.hierarchy")
  local is_child = function(bufnr)
    return ok and hierarchy.is_child(bufnr) or false
  end

  local view = {
    parents = {},
    active_parent_bufnr = self.active_parent_bufnr,
    inline = {
      active = self.inline.active,
      status = self.inline.status,
      started_at = self.inline.started_at,
      completed_at = self.inline.completed_at,
      duration_ms = self.inline.duration_ms,
      adapter = self.inline.adapter,
      model = self.inline.model,
      provider = self.inline.provider,
      bufnr = self.inline.bufnr,
    },
  }

  for bufnr, parent in pairs(self.parents) do
    local parent_view = {
      bufnr = bufnr,
      status = parent.status,
      request_started = parent.request_started,
      total_started = parent.total_started,
      duration_ms = parent.duration_ms,
      completed_at = parent.completed_at,
      adapter = parent.adapter,
      model = parent.model,
      provider = parent.provider,
      current_tool = parent.current_tool,
      subagents = {},
      is_child = is_child(bufnr),
    }

    for child_bufnr, info in pairs(parent.subagents or {}) do
      parent_view.subagents[child_bufnr] = {
        child_bufnr = info.child_bufnr,
        agent_name = info.agent_name,
        agent_type = info.agent_type,
        status = info.status,
        tool_count = info.tool_count,
        description = info.description,
        start_time = info.start_time,
        duration_ms = info.duration_ms,
      }
    end

    view.parents[bufnr] = parent_view
  end

  return view
end

---Get a view with child parents filtered out
---@return CCExtra.StateView
function StateManager:get_parent_view()
  local view = self:get_view()
  local filtered = {
    parents = {},
    active_parent_bufnr = view.active_parent_bufnr,
    inline = view.inline,
  }
  for bufnr, parent in pairs(view.parents) do
    if not parent.is_child then filtered.parents[bufnr] = parent end
  end
  return filtered
end

-- ============================================================================
-- Module (singleton)
-- ============================================================================

local _instance = nil

---@param config table
function M.setup(config)
  if _instance then return end
  _instance = StateManager.new(config or {})
end

---@return CCExtra.StateManager|nil
function M.instance()
  return _instance
end

function M.debug_log(msg)
  local f = io.open(DEBUG_LOG_PATH, "a")
  if f then
    f:write(string.format("[%s] [state] %s\n", os.date("%H:%M:%S"), msg))
    f:close()
  end
end

return M
