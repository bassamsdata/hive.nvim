-- Task tool for spawning subagents (supports single or parallel execution)
-- Implements async pattern: parent waits for child completion
-- Provides real-time status updates via virtual line notifications with animated spinner

local log = require("codecompanion.utils.log")

local api = vim.api
local fmt = string.format

-- ============================================================================
-- Constants
-- ============================================================================

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local UPDATE_INTERVAL_MS = 100
local SUBAGENT_IDLE_TIMEOUT_MS = 120000 -- 2 minutes of no tool activity triggers timeout

local ICONS = {
  explorer = "",
  general = "",
  analyzer = "",
  default = "",
  tools = "",
  timer = "",
  success = "✓",
  error = "✗",
  cancelled = "",
  pending = "",
  running = "",
  task = "󰤖",
}

local STATUS_ICONS = {
  pending = ICONS.pending,
  running = ICONS.running,
  completed = ICONS.success,
  failed = ICONS.error,
  cancelled = ICONS.cancelled,
}

local HIGHLIGHTS = {
  header = "Title",
  running = "WarningMsg",
  success = "DiagnosticOk",
  error = "ErrorMsg",
  info = "DiagnosticInfo",
  agent = "Function",
  default = "Comment",
}

-- ============================================================================
-- TaskBatch Class
-- ============================================================================

---@class TaskBatch
---@field tasks table[] Task definitions
---@field results table<number, TaskResult>
---@field pending number Count of pending tasks
---@field timer uv.uv_timer_t|nil Animation timer
---@field spinner_index number Current spinner frame
---@field parent_chat table Parent chat reference
---@field child_bufnrs number[] All child buffer numbers
---@field child_chats table<number, table> Child chat references by bufnr
---@field child_states table<number, TaskChildState> Per-child state tracking for timeouts
---@field callback function Final callback when all complete
---@field start_time number Start time in hrtime nanoseconds
---@field ns_id number Namespace ID for extmarks
local TaskBatch = {}
TaskBatch.__index = TaskBatch

---@class TaskResult
---@field status string "success" or "error"
---@field data string Result or error message
---@field agent string Agent name
---@field description string Task description
---@field tool_count number Number of tools used

---@class TaskChildState
---@field last_tool_activity number Last tool activity timestamp (hrtime nanoseconds)
---@field tool_count number Number of tools executed so far
---@field timeout_timer uv.uv_timer_t|nil Idle timeout timer for this child

---@type table<number, TaskBatch>
local _active_batches = {}

---Create a new TaskBatch instance
---@param args { tasks: table[], parent_chat: table, callback: function }
---@return TaskBatch
function TaskBatch.new(args)
  local self = setmetatable({}, TaskBatch)

  self.tasks = args.tasks
  self.parent_chat = args.parent_chat
  self.callback = args.callback
  self.results = {}
  self.pending = #args.tasks
  self.timer = nil
  self.spinner_index = 1
  self.child_bufnrs = {}
  self.child_chats = {}
  self.child_states = {}
  self.start_time = vim.uv.hrtime()
  self.ns_id = api.nvim_create_namespace("codecompanion_task_" .. tostring(args.parent_chat.bufnr))

  _active_batches[args.parent_chat.bufnr] = self

  return self
end

---Get active batch for a parent buffer
---@param parent_bufnr number
---@return TaskBatch|nil
function TaskBatch.get_active(parent_bufnr)
  return _active_batches[parent_bufnr]
end

---Remove batch from active batches
function TaskBatch:cleanup()
  _active_batches[self.parent_chat.bufnr] = nil
end

-- ============================================================================
-- Utility Functions
-- ============================================================================

---Check if a window is valid and visible
---@param winnr number|nil
---@return boolean
local function is_window_valid(winnr)
  if not winnr then return false end
  local ok, valid = pcall(api.nvim_win_is_valid, winnr)
  return ok and valid
end

---Safely hide a child chat UI
---@param child_chat table
local function safe_hide_child_ui(child_chat)
  if not child_chat or not child_chat.ui then return end

  local ui = child_chat.ui
  if ui.is_active and ui:is_active() then
    pcall(vim.cmd, "hide")
    return
  end

  if not ui.winnr then
    local ui_utils = require("codecompanion.interactions.chat.ui.utils")
    ui.winnr = ui_utils.buf_get_win(ui.chat_bufnr)
  end

  if is_window_valid(ui.winnr) then pcall(api.nvim_win_hide, ui.winnr) end
end

---Capitalize agent name for display
---@param name string
---@return string
local function capitalize_agent(name)
  if not name then return "Unknown" end
  return name:sub(1, 1):upper() .. name:sub(2)
end

---Get icon for agent type
---@param agent_name string
---@return string
local function get_agent_icon(agent_name)
  return ICONS[agent_name] or ICONS.default
end

-- ============================================================================
-- TaskBatch Methods - Status Display
-- ============================================================================

---Build status text for all tasks
---@param spinner_char string
---@return string
function TaskBatch:build_status_text(spinner_char)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")

  local elapsed_ns = vim.uv.hrtime() - self.start_time
  local elapsed_ms = math.floor(elapsed_ns / 1000000)
  local elapsed_str = hierarchy.format_duration(elapsed_ms)

  local task_count = #self.tasks
  local completed_count = task_count - self.pending
  local header = task_count > 1
      and fmt("─────── SubAgents (%d/%d) ───────", completed_count, task_count)
    or "─────── SubAgent ───────"

  local lines = { header }

  for i, child_bufnr in ipairs(self.child_bufnrs) do
    local session = hierarchy.get_session(child_bufnr)
    local task_def = self.tasks[i]

    if session then
      local icon = get_agent_icon(session.agent_name)
      local display_name = capitalize_agent(session.agent_name)
      local summary = hierarchy.get_tool_summary(child_bufnr)
      local status_icon
      local status_text

      if session.status == "running" then
        local tool_info = summary.completed > 0 and fmt(" | Tools: %d", summary.completed) or ""
        if summary.current then
          status_icon = spinner_char
          status_text = fmt("Running: `%s`%s", summary.current, tool_info)
        else
          status_icon = spinner_char
          status_text = summary.completed > 0 and fmt("Working... | Tools: %d", summary.completed) or "Working..."
        end
      elseif session.status == "completed" then
        local duration = hierarchy.format_duration(session.duration_ms)
        status_icon = STATUS_ICONS.completed
        status_text = fmt("Done (%d tools, %s)", summary.total, duration)
      elseif session.status == "failed" then
        status_icon = STATUS_ICONS.failed
        status_text = "Failed"
      elseif session.status == "cancelled" then
        status_icon = STATUS_ICONS.cancelled
        status_text = "Cancelled"
      else
        status_icon = STATUS_ICONS.pending
        status_text = "Pending"
      end

      table.insert(lines, fmt("  %s %s: %s", icon, display_name, task_def.description))
      table.insert(lines, fmt("    %s %s", status_icon, status_text))
    elseif task_def then
      local icon = get_agent_icon(task_def.subagent_type)
      table.insert(lines, fmt("  %s %s: %s", icon, capitalize_agent(task_def.subagent_type), task_def.description))
      table.insert(lines, fmt("    %s Starting...", spinner_char))
    end
  end

  table.insert(lines, fmt("  %s Total: %s", ICONS.timer, elapsed_str))

  return table.concat(lines, "\n")
end

---Render status notification in parent chat buffer using virtual lines
---@param status_text string
function TaskBatch:render_status(status_text)
  if not self.parent_chat or not self.parent_chat.bufnr or not api.nvim_buf_is_valid(self.parent_chat.bufnr) then
    return
  end

  local lines = vim.split(status_text, "\n")
  local virt_lines = {}
  table.insert(virt_lines, { { "", "Normal" } })

  for _, line in ipairs(lines) do
    local hl = HIGHLIGHTS.default
    if line:match("^───") then
      hl = HIGHLIGHTS.header
    elseif line:match("Running") or line:match("Working") or line:match("Starting") then
      hl = HIGHLIGHTS.running
    elseif line:match("Done") or line:match(ICONS.success) then
      hl = HIGHLIGHTS.success
    elseif
      line:match("Failed")
      or line:match("Cancelled")
      or line:match(ICONS.error)
      or line:match(ICONS.cancelled)
    then
      hl = HIGHLIGHTS.error
    elseif line:match(ICONS.timer) then
      hl = HIGHLIGHTS.info
    elseif
      line:match("^  " .. ICONS.explorer)
      or line:match("^  " .. ICONS.general)
      or line:match("^  " .. ICONS.analyzer)
      or line:match("^  " .. ICONS.default)
    then
      hl = HIGHLIGHTS.agent
    end
    table.insert(virt_lines, { { line, hl } })
  end

  table.insert(virt_lines, { { "", "Normal" } })

  if not api.nvim_buf_is_valid(self.parent_chat.bufnr) then return end

  pcall(api.nvim_buf_clear_namespace, self.parent_chat.bufnr, self.ns_id, 0, -1)

  local buf_lines = api.nvim_buf_line_count(self.parent_chat.bufnr)
  local target_line = math.max(0, buf_lines - 1)

  pcall(api.nvim_buf_set_extmark, self.parent_chat.bufnr, self.ns_id, target_line, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
    priority = 100,
  })
end

---Clear status notification from parent chat
function TaskBatch:clear_status()
  if not self.parent_chat or not self.parent_chat.bufnr or not api.nvim_buf_is_valid(self.parent_chat.bufnr) then
    return
  end

  vim.schedule(function()
    if api.nvim_buf_is_valid(self.parent_chat.bufnr) then
      pcall(api.nvim_buf_clear_namespace, self.parent_chat.bufnr, self.ns_id, 0, -1)
    end
  end)
end

-- ============================================================================
-- TaskBatch Methods - Timer Management
-- ============================================================================

---Start animation timer for batch status
function TaskBatch:start_timer()
  if self.timer then return end

  self.timer = vim.uv.new_timer()
  self.timer:start(
    0,
    UPDATE_INTERVAL_MS,
    vim.schedule_wrap(function()
      if not self.parent_chat or not self.parent_chat.bufnr then
        self:stop_timer()
        return
      end

      self.spinner_index = (self.spinner_index % #SPINNER_FRAMES) + 1
      local spinner_char = SPINNER_FRAMES[self.spinner_index]

      local status_text = self:build_status_text(spinner_char)
      self:render_status(status_text)
    end)
  )
end

---Stop and cleanup batch timer
function TaskBatch:stop_timer()
  if self.timer and not self.timer:is_closing() then
    self.timer:stop()
    self.timer:close()
  end
  self.timer = nil
end

---Stop timeout timer for a specific child
---@param child_bufnr number
function TaskBatch:stop_child_timeout_timer(child_bufnr)
  local child_state = self.child_states and self.child_states[child_bufnr]
  if child_state and child_state.timeout_timer then
    if not child_state.timeout_timer:is_closing() then
      child_state.timeout_timer:stop()
      child_state.timeout_timer:close()
    end
    child_state.timeout_timer = nil
  end
end

---Stop all child timeout timers
function TaskBatch:stop_all_child_timeout_timers()
  if not self.child_states then return end
  for child_bufnr, _ in pairs(self.child_states) do
    self:stop_child_timeout_timer(child_bufnr)
  end
end

---Reset (restart) the idle timeout timer for a child
---@param child_bufnr number
---@param task_index number
function TaskBatch:reset_child_timeout_timer(child_bufnr, task_index)
  local child_state = self.child_states[child_bufnr]
  if not child_state then return end

  self:stop_child_timeout_timer(child_bufnr)
  child_state.last_tool_activity = vim.uv.hrtime()

  child_state.timeout_timer = vim.uv.new_timer()
  child_state.timeout_timer:start(
    SUBAGENT_IDLE_TIMEOUT_MS,
    0,
    vim.schedule_wrap(function()
      if not _active_batches[self.parent_chat.bufnr] then return end

      local hierarchy = require("codecompanion-extra.agents.hierarchy")
      local session = hierarchy.get_session(child_bufnr)
      if not session or session.status ~= "running" then return end

      local task_def = self.tasks[task_index]
      local elapsed_sec = math.floor(SUBAGENT_IDLE_TIMEOUT_MS / 1000)

      log:warn(
        "[Task] Subagent '%s' timed out after %ds of inactivity (tools used: %d)",
        task_def.subagent_type,
        elapsed_sec,
        child_state.tool_count
      )

      hierarchy.set_status(child_bufnr, "failed")

      local child_chat = self.child_chats[child_bufnr]
      if child_chat and child_chat.stop then pcall(child_chat.stop, child_chat) end

      local timeout_msg = fmt(
        "Subagent '%s' timed out after %d seconds of no tool activity. Tools executed before timeout: %d",
        task_def.subagent_type,
        elapsed_sec,
        child_state.tool_count
      )

      vim.defer_fn(function()
        if self.results[task_index] then return end
        self:on_task_complete(child_bufnr, task_index, "error", timeout_msg, child_state.tool_count)
      end, 500)
    end)
  )
end

-- ============================================================================
-- TaskBatch Methods - Task Completion
-- ============================================================================

---Extract result from child chat
---@param child_chat table
---@param child_bufnr number
---@return string result
---@return number tool_count
function TaskBatch:extract_child_result(child_chat, child_bufnr)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local config = require("codecompanion.config")

  local messages = child_chat.messages or {}
  local final_text = ""

  for i = #messages, 1, -1 do
    local msg = messages[i]
    if msg.role == config.constants.LLM_ROLE and msg.content then
      local content = msg.content
      if type(content) == "table" then
        for _, part in ipairs(content) do
          if part.type == "text" then
            final_text = part.text or ""
            break
          end
        end
      else
        final_text = content
      end
      if final_text ~= "" then break end
    end
  end

  local tool_list = hierarchy.get_tool_execution_list(child_bufnr)
  local tool_count = #tool_list
  local tool_summary = ""

  if tool_count > 0 then
    local tool_lines = { "Tools executed:" }
    for _, tool in ipairs(tool_list) do
      local status_icon = tool.status == "completed" and ICONS.success or ICONS.error
      local title_part = tool.title and (": " .. tool.title) or ""
      table.insert(tool_lines, fmt("  %s %s%s", status_icon, tool.name, title_part))
    end
    tool_summary = table.concat(tool_lines, "\n")
  end

  local duration = hierarchy.get_elapsed_ms(child_bufnr)
  local duration_str = hierarchy.format_duration(duration)

  local result_parts = {}
  if final_text ~= "" then table.insert(result_parts, final_text) end
  if tool_summary ~= "" then table.insert(result_parts, tool_summary) end
  table.insert(result_parts, fmt("(Completed in %s, %d tools used)", duration_str, tool_count))

  return table.concat(result_parts, "\n\n"), tool_count
end

---Handle completion of a single task in the batch
---@param child_bufnr number
---@param task_index number
---@param status string "success" or "error"
---@param data string Result or error message
---@param tool_count? number Number of tools used (optional, will use child_state if not provided)
function TaskBatch:on_task_complete(child_bufnr, task_index, status, data, tool_count)
  local task_def = self.tasks[task_index]

  self:stop_child_timeout_timer(child_bufnr)

  local child_state = self.child_states[child_bufnr]
  local tools_used = tool_count or (child_state and child_state.tool_count) or 0

  self.results[task_index] = {
    status = status,
    data = data,
    agent = task_def.subagent_type,
    description = task_def.description,
    tool_count = tools_used,
  }

  self.pending = self.pending - 1

  log:debug("[Task] Task %d completed: %s (%d pending, %d tools)", task_index, status, self.pending, tools_used)

  if self.pending <= 0 then
    self:stop_timer()
    self:stop_all_child_timeout_timers()

    vim.defer_fn(function()
      self:clear_status()
    end, 500)

    local hierarchy = require("codecompanion-extra.agents.hierarchy")
    local total_elapsed = math.floor((vim.uv.hrtime() - self.start_time) / 1000000)
    local total_duration = hierarchy.format_duration(total_elapsed)

    local success_count = 0
    local error_count = 0
    local total_tools = 0
    local result_parts = {}

    for i, result in ipairs(self.results) do
      if result.status == "success" then
        success_count = success_count + 1
      else
        error_count = error_count + 1
      end
      total_tools = total_tools + (result.tool_count or 0)

      table.insert(
        result_parts,
        fmt(
          [[<subagent_result agent="%s" task="%s" status="%s" tools="%d">
%s
</subagent_result>]],
          result.agent,
          result.description,
          result.status,
          result.tool_count or 0,
          result.data
        )
      )
    end

    local consolidated_result = table.concat(result_parts, "\n\n")
    consolidated_result = consolidated_result
      .. fmt(
        "\n\n(Batch completed: %d succeeded, %d failed, %d total tools, total time: %s)",
        success_count,
        error_count,
        total_tools,
        total_duration
      )

    self:cleanup()

    self.callback({
      status = error_count > 0 and "error" or "success",
      data = consolidated_result,
    })
  end
end

-- ============================================================================
-- TaskBatch Methods - Child Listeners
-- ============================================================================

---Setup event listeners for a child in the batch
---@param child_bufnr number
---@param child_chat table
---@param task_index number
function TaskBatch:setup_child_listeners(child_bufnr, child_chat, task_index)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local task_def = self.tasks[task_index]

  local tool_call_counter = 0
  local completed = false
  local aug = api.nvim_create_augroup("codecompanion_task_child_" .. child_bufnr, { clear = true })

  self.child_states[child_bufnr] = {
    last_tool_activity = vim.uv.hrtime(),
    tool_count = 0,
    timeout_timer = nil,
  }

  self:reset_child_timeout_timer(child_bufnr, task_index)

  local batch = self

  local function cleanup_and_complete(status, data, tool_count)
    if completed then return end
    completed = true
    pcall(api.nvim_del_augroup_by_id, aug)
    batch:on_task_complete(child_bufnr, task_index, status, data, tool_count)
  end

  api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionToolStarted",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        tool_call_counter = tool_call_counter + 1
        local tool_id = fmt("tool_%d", tool_call_counter)
        local tool_name = event.data.tool or "unknown"
        hierarchy.tool_started(child_bufnr, tool_id, tool_name)

        local child_state = batch.child_states[child_bufnr]
        if child_state then child_state.tool_count = child_state.tool_count + 1 end
        batch:reset_child_timeout_timer(child_bufnr, task_index)
      end
    end,
  })

  api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionToolFinished",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        local tool_id = fmt("tool_%d", tool_call_counter)
        local tool_name = event.data.name or "unknown"
        hierarchy.tool_finished(child_bufnr, tool_id, true, tool_name)

        batch:reset_child_timeout_timer(child_bufnr, task_index)
      end
    end,
  })

  api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionChatDone",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        hierarchy.set_status(child_bufnr, "completed")

        local result, tool_count = batch:extract_child_result(child_chat, child_bufnr)
        hierarchy.set_status(child_bufnr, "completed", result)

        cleanup_and_complete("success", result, tool_count)
        return true
      end
    end,
  })

  api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionChatStopped",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        hierarchy.set_status(child_bufnr, "failed")

        local child_state = batch.child_states[child_bufnr]
        local tool_count = child_state and child_state.tool_count or 0

        cleanup_and_complete(
          "error",
          fmt("Subagent '%s' was stopped before completion", task_def.subagent_type),
          tool_count
        )
        return true
      end
    end,
  })

  api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionChatClosed",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        local current_session = hierarchy.get_session(child_bufnr)
        if current_session and current_session.status == "running" then
          hierarchy.set_status(child_bufnr, "cancelled")

          local child_state = batch.child_states[child_bufnr]
          local tool_count = child_state and child_state.tool_count or 0

          cleanup_and_complete(
            "error",
            fmt("Subagent '%s' was closed unexpectedly", task_def.subagent_type),
            tool_count
          )
        end
        return true
      end
    end,
  })
end

-- ============================================================================
-- TaskBatch Methods - Subagent Spawning
-- ============================================================================

---Spawn a single subagent for the batch
---@param task_def table Task definition
---@param task_index number
---@return number|nil child_bufnr
function TaskBatch:spawn_subagent(task_def, task_index)
  local agents = require("codecompanion-extra.agents")
  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local registry = require("codecompanion-extra.agents.registry")
  local extra_config = require("codecompanion-extra.config")

  local agent_name = task_def.subagent_type
  local agent = registry.get(agent_name)

  if not agent then
    log:error("[Task] Unknown subagent: %s", agent_name)
    self:on_task_complete(-1, task_index, "error", fmt("Unknown subagent: %s", agent_name), 0)
    return nil
  end

  if agent.type ~= "subagent" then
    log:error("[Task] %s is not a subagent", agent_name)
    self:on_task_complete(-1, task_index, "error", fmt("'%s' is not a subagent", agent_name), 0)
    return nil
  end

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then
    self:on_task_complete(-1, task_index, "error", "Failed to load codecompanion config", 0)
    return nil
  end

  local codecompanion = require("codecompanion")
  local parent_window_opts = self.parent_chat.ui and self.parent_chat.ui.window_opts

  local chat_opts = {
    auto_submit = false,
    window_opts = parent_window_opts,
  }

  local small_model = extra_config.get_small_model()
  if small_model then
    chat_opts.params = {
      adapter = small_model.adapter,
      model = small_model.model,
    }
    log:debug("[Task] Using small_model: adapter=%s, model=%s", small_model.adapter, small_model.model)
  else
    local parent_adapter = self.parent_chat.adapter
    if parent_adapter then
      local adapter_name = parent_adapter.name
      local model_name = parent_adapter.schema and parent_adapter.schema.model and parent_adapter.schema.model.default

      if type(model_name) == "function" then model_name = model_name(parent_adapter) end

      if adapter_name then
        chat_opts.params = {
          adapter = adapter_name,
          model = model_name,
        }
        log:debug("[Task] Inheriting from parent: adapter=%s, model=%s", adapter_name, model_name or "default")
      end
    end
  end

  local child_chat = codecompanion.chat(chat_opts)

  if not child_chat then
    self:on_task_complete(-1, task_index, "error", "Failed to create subagent chat", 0)
    return nil
  end

  local child_bufnr = child_chat.bufnr
  self.child_chats[child_bufnr] = child_chat

  local batch = self
  vim.schedule(function()
    safe_hide_child_ui(child_chat)

    if batch.parent_chat and batch.parent_chat.ui then
      batch.parent_chat.ui:open({ window_opts = parent_window_opts or { default = true } })
    end
  end)

  hierarchy.create_session({
    bufnr = child_bufnr,
    parent_bufnr = self.parent_chat.bufnr,
    agent_name = agent_name,
    agent_type = "subagent",
    description = task_def.description,
    hidden = true,
  })

  local activate_ok = agents.activate(agent_name, child_chat, { silent = true })
  if not activate_ok then
    self:on_task_complete(child_bufnr, task_index, "error", fmt("Failed to activate subagent '%s'", agent_name), 0)
    return nil
  end

  child_chat:add_message({
    role = cc_config.constants.USER_ROLE,
    content = task_def.prompt,
  }, { visible = true })

  self:setup_child_listeners(child_bufnr, child_chat, task_index)

  hierarchy.start_timer(child_bufnr)

  child_chat:submit()

  return child_bufnr
end

---Execute all tasks in the batch
function TaskBatch:execute()
  log:debug("[Task] Starting execution with %d task(s)", #self.tasks)

  self:start_timer()

  for i, task_def in ipairs(self.tasks) do
    local child_bufnr = self:spawn_subagent(task_def, i)
    if child_bufnr then
      self.child_bufnrs[i] = child_bufnr
    else
      self.child_bufnrs[i] = -1
    end
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

---Execute task(s) - supports single task or parallel batch
---@param args { tasks: table[] } Array of task definitions
---@param parent_chat table
---@param callback function Called when all tasks complete
local function execute_tasks(args, parent_chat, callback)
  local tasks = args.tasks

  if not tasks or #tasks == 0 then
    callback({
      status = "error",
      data = "No tasks provided to task tool",
    })
    return
  end

  local batch = TaskBatch.new({
    tasks = tasks,
    parent_chat = parent_chat,
    callback = callback,
  })

  batch:execute()
end

-- ============================================================================
-- Tool Definition
-- ============================================================================

---@class CodeCompanion.Tool.Task
return {
  name = "task",
  cmds = {
    ---Execute the task tool (async pattern - does not return immediately)
    ---@param tools table The tools coordinator object
    ---@param args table The arguments from the LLM's tool call
    ---@param input? any The output from the previous function call
    ---@param output_handler fun(result: {status: string, data: any}) Callback for async completion
    function(tools, args, input, output_handler)
      if not tools or not tools.chat then
        log:error("[Task] No chat context available")
        return {
          status = "error",
          data = "No chat context available",
        }
      end

      log:debug("[Task] cmds called with %d task(s)", args.tasks and #args.tasks or 0)

      execute_tasks(args, tools.chat, output_handler)

      return nil
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "task",
      description = [[Delegate one or more tasks to specialized subagents. Each subagent runs in its own context with focused tools and returns results when complete.

SINGLE TASK: Provide one task in the tasks array for sequential execution.
PARALLEL TASKS: Provide multiple tasks to run them ALL SIMULTANEOUSLY for faster results.

Use subagents for:
- Exploring/researching code (explorer): Fast codebase exploration with read-only tools
- Running analyses (analyzer): Code analysis, diagnostics, and finding issues
- General research tasks (general): Multi-step research that may need command execution

Available subagents:
- explorer: Fast codebase exploration (read-only). Use for finding files, searching code, understanding structure.
- general: General research and multi-step tasks. Can run commands for information gathering.
- analyzer: Code analysis and diagnostics. Use for finding issues, checking errors, analyzing patterns.

When to use subagents:
- Complex exploration that needs focused context
- PARALLEL research tasks - spawn multiple subagents at once for speed
- Isolated analysis that shouldn't clutter main conversation
- Tasks that benefit from specialized tool sets

Example parallel call:
{
  "tasks": [
    {"subagent_type": "explorer", "description": "Find auth files", "prompt": "Search for authentication..."},
    {"subagent_type": "analyzer", "description": "Check API errors", "prompt": "Analyze the API routes..."}
  ]
}

The parent waits for ALL subagents to complete and receives consolidated results.
The user can navigate to subagent chats with ]s to see detailed output.]],
      parameters = {
        type = "object",
        properties = {
          tasks = {
            type = "array",
            description = "Array of tasks to execute. Single task for sequential, multiple for parallel execution.",
            items = {
              type = "object",
              properties = {
                subagent_type = {
                  type = "string",
                  description = "Which subagent: 'explorer' for codebase exploration, 'general' for research, 'analyzer' for code analysis",
                  enum = { "explorer", "general", "analyzer" },
                },
                description = {
                  type = "string",
                  description = "Brief description of what this task should accomplish (shown to user)",
                },
                prompt = {
                  type = "string",
                  description = "Detailed instructions for the subagent. Be specific about what to search for, analyze, or research.",
                },
              },
              required = { "subagent_type", "description", "prompt" },
              additionalProperties = false,
            },
          },
        },
        required = { "tasks" },
        additionalProperties = false,
      },
    },
  },
  handlers = {
    on_exit = function(tools)
      log:trace("[Task Tool] on_exit handler executed")
    end,
  },
  output = {
    cmd_string = function(self, args)
      local tasks = self.args.tasks or {}
      if #tasks == 1 then
        return fmt("Spawn %s subagent: %s", capitalize_agent(tasks[1].subagent_type), tasks[1].description)
      end
      return fmt("Spawn %d subagents in parallel", #tasks)
    end,

    prompt = function(self, tools)
      local tasks = self.args.tasks or {}
      local count = #tasks
      if count == 0 then return "Run task tool?" end

      local descriptions = {}
      for i, task in ipairs(tasks) do
        if i <= 3 then
          local icon = get_agent_icon(task.subagent_type)
          table.insert(descriptions, fmt("- %s %s: %s", icon, capitalize_agent(task.subagent_type), task.description))
        end
      end
      if count > 3 then table.insert(descriptions, fmt("- ... and %d more", count - 3)) end
      if count == 1 then
        return fmt(
          "Spawn %s subagent: %s?",
          capitalize_agent(self.args.tasks[1].subagent_type),
          self.args.tasks[1].description
        )
      end
      return fmt("Run %d subagents in parallel?\n%s", count, table.concat(descriptions, "\n"))
    end,

    success = function(self, tools, cmd, stdout)
      local chat = tools.chat
      local output = vim.iter(stdout):flatten():join("\n")

      local task_count = self.args.tasks and #self.args.tasks or 0
      local success_match = output:match("(%d+) succeeded")
      local failed_match = output:match("(%d+) failed")
      local duration_match = output:match("total time: ([^)]+)")
      local tools_match = output:match("(%d+) tools used")
      local total_tools_match = output:match("(%d+) total tools")

      local llm_output
      if task_count == 1 then
        llm_output = fmt(
          [[<subagent_result agent="%s" task="%s">
%s
</subagent_result>

Use the subagent's findings above to continue with your task. Synthesize the information as needed.]],
          self.args.tasks[1].subagent_type,
          self.args.tasks[1].description,
          output
        )
      else
        llm_output = fmt(
          [[<subagents_results count="%d">
%s
</subagents_results>

Synthesize the results from all %d subagents above to continue with your task.]],
          task_count,
          output,
          task_count
        )
      end

      local user_lines
      if task_count == 1 then
        local task = self.args.tasks[1]
        local icon = get_agent_icon(task.subagent_type)
        local tool_info = tools_match and fmt("  %s Tools: %s", ICONS.tools, tools_match) or nil
        user_lines = {
          fmt("───── %s %s Complete ─────", icon, capitalize_agent(task.subagent_type)),
          fmt("  %s Task: %s", ICONS.task, task.description),
        }
        if tool_info then table.insert(user_lines, tool_info) end
        if duration_match then table.insert(user_lines, fmt("  %s Duration: %s", ICONS.timer, duration_match)) end
        table.insert(
          user_lines,
          "─────────────────────────────────"
        )
      else
        -- Parse per-subagent tool counts from the output
        local agent_tool_counts = {}
        for agent, task_desc, tools_count in
          output:gmatch('<subagent_result agent="([^"]+)" task="([^"]+)" status="[^"]*" tools="(%d+)"')
        do
          agent_tool_counts[task_desc] = { agent = agent, tools = tonumber(tools_count) }
        end

        user_lines = {
          fmt("═══════ SubAgents Complete (%d) ═══════", task_count),
        }
        for _, task in ipairs(self.args.tasks or {}) do
          local icon = get_agent_icon(task.subagent_type)
          local tool_info = ""
          local agent_data = agent_tool_counts[task.description]
          if agent_data then tool_info = fmt(" (%d tools)", agent_data.tools) end
          table.insert(
            user_lines,
            fmt("  %s %s: %s%s", icon, capitalize_agent(task.subagent_type), task.description, tool_info)
          )
        end
        if success_match then table.insert(user_lines, fmt("  %s Succeeded: %s", ICONS.success, success_match)) end
        if failed_match and failed_match ~= "0" then
          table.insert(user_lines, fmt("  %s Failed: %s", ICONS.error, failed_match))
        end
        if total_tools_match then
          table.insert(user_lines, fmt("  %s Total tools: %s", ICONS.tools, total_tools_match))
        end
        if duration_match then table.insert(user_lines, fmt("  %s Duration: %s", ICONS.timer, duration_match)) end
        table.insert(
          user_lines,
          "═══════════════════════════════════════"
        )
      end

      local user_output = table.concat(user_lines, "\n")

      chat:add_tool_output(self, llm_output, user_output)
    end,

    error = function(self, tools, cmd, stderr)
      local chat = tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      log:debug("[Task Tool] Error output: %s", stderr)

      local error_output = fmt(
        [[Task tool encountered an error:

```txt
%s
```]],
        errors
      )
      chat:add_tool_output(self, error_output)
    end,

    rejected = function(self, tools, cmd, opts)
      local helpers = require("codecompanion.interactions.chat.tools.builtin.helpers")
      local message = "The user rejected the task delegation"
      opts = vim.tbl_extend("force", { message = message }, opts or {})
      helpers.rejected(self, tools, cmd, opts)
    end,
  },
}
