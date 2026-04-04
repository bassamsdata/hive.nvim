-- Task tool for spawning subagents (supports single or parallel execution)
-- Implements async pattern: parent waits for child completion
-- Provides real-time status updates via virtual line notifications with animated spinner

local log = require("codecompanion.utils.log")
local compat = require("hive.tools.compat")
local subagent = require("hive.tools.subagent")

local api = vim.api
local fmt = string.format

-- ============================================================================
-- Task-Specific Icons
-- ============================================================================

local ICONS = {
  explorer = "",
  general = "",
  analyzer = "",
  default = "",
  task = "󰤖",
}

local AGENT_ICONS = { ICONS.explorer, ICONS.general, ICONS.analyzer, ICONS.default }

local SUSPICIOUS_FAST_MS = 2000

-- ============================================================================
-- TaskBatch Class
-- ============================================================================

---@class TaskBatch
---@field tasks table[] Task definitions
---@field results table<number, TaskResult>
---@field pending number Count of pending tasks
---@field timer uv.uv_timer_t|nil Animation timer
---@field parent_chat table Parent chat reference
---@field child_bufnrs number[] All child buffer numbers
---@field child_chats table<number, table> Child chat references by bufnr
---@field child_states table<number, TaskChildState> Per-child state tracking for timeouts
---@field child_augs table<number, number> Autocommand group IDs by child bufnr
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
---@field completed boolean Whether this child has completed

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
  self.child_bufnrs = {}
  self.child_chats = {}
  self.child_states = {}
  self.child_augs = {}
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
-- TaskBatch Methods - Utility
-- ============================================================================

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
  local hierarchy = require("hive.agents.hierarchy")
  local utils = subagent.utils

  local elapsed_ms = utils.get_elapsed_ms(self.start_time)
  local elapsed_str = utils.format_duration(elapsed_ms)

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
      local display_name = utils.capitalize(session.agent_name)
      local summary = hierarchy.get_tool_summary(child_bufnr)
      local status_icon
      local status_text

      if session.status == "running" then
        local tool_info = summary.completed > 0 and fmt(" | ToolCalls: %d", summary.completed) or ""
        if summary.current then
          status_icon = spinner_char
          status_text = fmt("Running: `%s`%s", summary.current, tool_info)
        else
          status_icon = spinner_char
          status_text = summary.completed > 0 and fmt("Working... | ToolCalls: %d", summary.completed) or "Working..."
        end
      elseif session.status == "completed" then
        local duration = utils.format_duration(session.duration_ms)
        status_icon = utils.STATUS_ICONS.completed
        status_text = fmt("Done (%d tools, %s)", summary.total, duration)
      elseif session.status == "failed" then
        status_icon = utils.STATUS_ICONS.failed
        status_text = "Failed"
      elseif session.status == "cancelled" then
        status_icon = utils.STATUS_ICONS.cancelled
        status_text = "Cancelled"
      else
        status_icon = utils.STATUS_ICONS.pending
        status_text = "Pending"
      end

      table.insert(lines, fmt("  %s %s: %s", icon, display_name, task_def.description))
      table.insert(lines, fmt("    %s %s", status_icon, status_text))
    elseif task_def then
      local icon = get_agent_icon(task_def.subagent_type)
      table.insert(lines, fmt("  %s %s: %s", icon, utils.capitalize(task_def.subagent_type), task_def.description))
      table.insert(lines, fmt("    %s Starting...", spinner_char))
    end
  end

  table.insert(lines, fmt("  %s Total: %s", utils.STATUS_ICONS.timer, elapsed_str))
  table.insert(lines, "  " .. utils.KEYMAP_HINTS)

  return table.concat(lines, "\n")
end

---Render status notification in parent chat buffer
function TaskBatch:render_status()
  if not self.parent_chat or not self.parent_chat.bufnr or not api.nvim_buf_is_valid(self.parent_chat.bufnr) then
    return
  end

  -- Get current spinner frame
  local spinner_idx = math.floor((vim.uv.hrtime() - self.start_time) / 100000000) % #subagent.utils.SPINNER_FRAMES + 1
  local spinner_char = subagent.utils.SPINNER_FRAMES[spinner_idx]

  local status_text = self:build_status_text(spinner_char)
  subagent.status.render({
    bufnr = self.parent_chat.bufnr,
    ns_id = self.ns_id,
    text = status_text,
    icons = subagent.utils.STATUS_ICONS,
    agent_icons = AGENT_ICONS,
  })
end

---Clear status notification from parent chat
function TaskBatch:clear_status()
  subagent.status.clear(self.parent_chat.bufnr, self.ns_id)
end

-- ============================================================================
-- TaskBatch Methods - Timer Management
-- ============================================================================

---Start animation timer for batch status
function TaskBatch:start_timer()
  if self.timer then return end

  local batch = self
  self.timer = subagent.utils.create_spinner_timer({
    on_tick = function()
      if not batch.parent_chat or not batch.parent_chat.bufnr then
        batch:stop_timer()
        return
      end
      batch:render_status()
    end,
  })
end

---Stop and cleanup batch timer
function TaskBatch:stop_timer()
  subagent.utils.safe_close_timer(self.timer)
  self.timer = nil
end

---Stop timeout timer for a specific child
---@param child_bufnr number
function TaskBatch:stop_child_timeout_timer(child_bufnr)
  local child_state = self.child_states and self.child_states[child_bufnr]
  if child_state then
    subagent.utils.safe_close_timer(child_state.timeout_timer)
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

  local batch = self
  local task_def = self.tasks[task_index]

  child_state.timeout_timer = subagent.utils.create_timeout_timer({
    on_timeout = function()
      if not _active_batches[batch.parent_chat.bufnr] then return end

      local hierarchy = require("hive.agents.hierarchy")
      local session = hierarchy.get_session(child_bufnr)
      if not session or session.status ~= "running" then return end

      local elapsed_sec = math.floor(subagent.utils.IDLE_TIMEOUT_MS / 1000)

      log:warn(
        "[Task] Subagent '%s' timed out after %ds of inactivity (tools used: %d)",
        task_def.subagent_type,
        elapsed_sec,
        child_state.tool_count
      )

      hierarchy.set_status(child_bufnr, "failed")

      local child_chat = batch.child_chats[child_bufnr]
      if child_chat and child_chat.stop then pcall(child_chat.stop, child_chat) end

      local timeout_msg = fmt(
        "Subagent '%s' timed out after %d seconds of no tool activity. Tools executed before timeout: %d",
        task_def.subagent_type,
        elapsed_sec,
        child_state.tool_count
      )

      vim.defer_fn(function()
        if batch.results[task_index] then return end
        batch:on_task_complete(child_bufnr, task_index, "error", timeout_msg, child_state.tool_count)
      end, 500)
    end,
  })
end

-- ============================================================================
-- TaskBatch Methods - Task Completion
-- ============================================================================

---Handle completion of a single task in the batch
---@param child_bufnr number
---@param task_index number
---@param status string "success" or "error"
---@param data string Result or error message
---@param tool_count? number Number of tools used
function TaskBatch:on_task_complete(child_bufnr, task_index, status, data, tool_count)
  local task_def = self.tasks[task_index]

  self:stop_child_timeout_timer(child_bufnr)

  local child_state = self.child_states[child_bufnr]
  if child_state then child_state.completed = true end
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

  -- Cleanup listeners for this child
  subagent.lifecycle.cleanup_listeners(self.child_augs[child_bufnr])

  if self.pending <= 0 then
    self:stop_timer()
    self:stop_all_child_timeout_timers()

    subagent.status.clear_after_delay({
      bufnr = self.parent_chat.bufnr,
      ns_id = self.ns_id,
    })

    local hierarchy = require("hive.agents.hierarchy")
    local total_elapsed = subagent.utils.get_elapsed_ms(self.start_time)
    local total_duration = subagent.utils.format_duration(total_elapsed)

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
  local hierarchy = require("hive.agents.hierarchy")
  local task_def = self.tasks[task_index]

  local tool_call_counter = 0
  local batch = self

  self.child_states[child_bufnr] = {
    last_tool_activity = vim.uv.hrtime(),
    tool_count = 0,
    timeout_timer = nil,
    completed = false,
  }

  self:reset_child_timeout_timer(child_bufnr, task_index)

  local aug = subagent.lifecycle.setup_listeners({
    child_bufnr = child_bufnr,
    group_name = "codecompanion_task_child_" .. child_bufnr,
    callbacks = {
      on_tool_started = function(event, tool_name)
        tool_call_counter = tool_call_counter + 1
        local tool_id = fmt("tool_%d", tool_call_counter)
        hierarchy.tool_started(child_bufnr, tool_id, tool_name)

        local child_state = batch.child_states[child_bufnr]
        if child_state then child_state.tool_count = child_state.tool_count + 1 end
        batch:reset_child_timeout_timer(child_bufnr, task_index)

        subagent.utils.fire("SubagentProgress", {
          parent_bufnr = batch.parent_chat.bufnr,
          child_bufnr = child_bufnr,
          agent_name = task_def.subagent_type,
          agent_type = "task",
          tool_name = tool_name,
          tool_count = child_state and child_state.tool_count or tool_call_counter,
        })
      end,

      on_tool_finished = function(event, tool_name)
        local tool_id = fmt("tool_%d", tool_call_counter)
        hierarchy.tool_finished(child_bufnr, tool_id, true, tool_name)
        batch:reset_child_timeout_timer(child_bufnr, task_index)
      end,

      on_done = function()
        local child_state = batch.child_states[child_bufnr]
        if child_state and child_state.completed then return end

        local ok, err = pcall(function()
          -- chat.status == "error" is set by on_error before ChatDone fires
          local chat_errored = child_chat.status == "error"

          if chat_errored then
            hierarchy.set_status(child_bufnr, "failed")
          else
            hierarchy.set_status(child_bufnr, "completed")
          end

          local extract_ok, result, tool_count = pcall(function()
            return subagent.messages.extract_result_with_tools({
              child_chat = child_chat,
              child_bufnr = child_bufnr,
            })
          end)

          if not extract_ok then
            log:debug("[Task] on_done extraction failed: %s", result)
            result = chat_errored and "Subagent failed (API error) and result extraction also failed"
              or "Subagent completed but result extraction failed"
            tool_count = child_state and child_state.tool_count or 0
          end

          local final_status = chat_errored and "error" or "success"

          -- Detect suspiciously fast completion: likely a misconfigured provider/model
          local child_elapsed_ms = subagent.utils.get_elapsed_ms(child_state.last_tool_activity)
          local tools_used = tool_count or (child_state and child_state.tool_count) or 0
          local models = require("hive.tools.subagent.models")
          local is_suspicious, suspicious_msg = models.detect_suspicious_fast_completion({
            elapsed_ms = child_elapsed_ms,
            tool_count = tools_used,
            threshold_ms = SUSPICIOUS_FAST_MS,
            subagent_type = task_def.subagent_type,
            context = "task",
          })

          if final_status == "success" and is_suspicious then
            final_status = "error"
            result = suspicious_msg
          end

          hierarchy.set_status(child_bufnr, chat_errored and "failed" or "completed", result)

          local elapsed_ms = subagent.utils.get_elapsed_ms(batch.start_time)
          subagent.utils.fire("SubagentCompleted", {
            parent_bufnr = batch.parent_chat.bufnr,
            child_bufnr = child_bufnr,
            agent_name = task_def.subagent_type,
            agent_type = "task",
            status = final_status,
            duration_ms = elapsed_ms,
            tool_count = tool_count,
          })

          batch:on_task_complete(child_bufnr, task_index, final_status, result, tool_count)
        end)

        if not ok then
          log:debug("[Task] on_done failed: %s", err)
          pcall(hierarchy.set_status, child_bufnr, "failed")
          batch:on_task_complete(
            child_bufnr,
            task_index,
            "error",
            fmt("Subagent '%s' completed but internal error occurred: %s", task_def.subagent_type, tostring(err)),
            child_state and child_state.tool_count or 0
          )
        end
      end,

      on_stopped = function()
        local child_state = batch.child_states[child_bufnr]
        if child_state and child_state.completed then return end

        local ok, err = pcall(function()
          hierarchy.set_status(child_bufnr, "failed")

          local tool_count = child_state and child_state.tool_count or 0
          local elapsed_ms = subagent.utils.get_elapsed_ms(batch.start_time)
          subagent.utils.fire("SubagentCompleted", {
            parent_bufnr = batch.parent_chat.bufnr,
            child_bufnr = child_bufnr,
            agent_name = task_def.subagent_type,
            agent_type = "task",
            status = "stopped",
            duration_ms = elapsed_ms,
            tool_count = tool_count,
          })

          batch:on_task_complete(
            child_bufnr,
            task_index,
            "error",
            fmt("Subagent '%s' was stopped before completion", task_def.subagent_type),
            tool_count
          )
        end)

        if not ok then
          log:debug("[Task] on_stopped failed: %s", err)
          pcall(hierarchy.set_status, child_bufnr, "failed")
          batch:on_task_complete(
            child_bufnr,
            task_index,
            "error",
            fmt("Subagent '%s' stopped with internal error: %s", task_def.subagent_type, tostring(err)),
            child_state and child_state.tool_count or 0
          )
        end
      end,

      on_closed = function()
        local child_state = batch.child_states[child_bufnr]
        if child_state and child_state.completed then return end

        local ok, err = pcall(function()
          local current_session = hierarchy.get_session(child_bufnr)
          if current_session and current_session.status == "running" then
            hierarchy.set_status(child_bufnr, "cancelled")

            local tool_count = child_state and child_state.tool_count or 0
            local elapsed_ms = subagent.utils.get_elapsed_ms(batch.start_time)
            subagent.utils.fire("SubagentCompleted", {
              parent_bufnr = batch.parent_chat.bufnr,
              child_bufnr = child_bufnr,
              agent_name = task_def.subagent_type,
              agent_type = "task",
              status = "cancelled",
              duration_ms = elapsed_ms,
              tool_count = tool_count,
            })

            batch:on_task_complete(
              child_bufnr,
              task_index,
              "error",
              fmt("Subagent '%s' was closed unexpectedly", task_def.subagent_type),
              tool_count
            )
          else
            batch:on_task_complete(
              child_bufnr,
              task_index,
              "error",
              fmt(
                "Subagent '%s' was closed (status: %s)",
                task_def.subagent_type,
                current_session and current_session.status or "unknown"
              ),
              child_state and child_state.tool_count or 0
            )
          end
        end)

        if not ok then
          log:debug("[Task] on_closed failed: %s", err)
          pcall(hierarchy.set_status, child_bufnr, "cancelled")
          batch:on_task_complete(
            child_bufnr,
            task_index,
            "error",
            fmt("Subagent '%s' closed with internal error: %s", task_def.subagent_type, tostring(err)),
            child_state and child_state.tool_count or 0
          )
        end
      end,
    },
  })

  self.child_augs[child_bufnr] = aug
end

-- ============================================================================
-- TaskBatch Methods - Subagent Spawning
-- ============================================================================

---Spawn a single subagent for the batch
---@param task_def table Task definition
---@param task_index number
---@return number|nil child_bufnr
function TaskBatch:spawn_subagent(task_def, task_index)
  local registry = require("hive.agents.registry")

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

  local child_chat, child_bufnr = subagent.lifecycle.spawn_child({
    parent_chat = self.parent_chat,
    agent_name = agent_name,
    prompt = task_def.prompt,
    description = task_def.description,
    hidden = true,
    silent = true,
    model_type = "small",
  })

  if not child_chat or not child_bufnr then
    self:on_task_complete(-1, task_index, "error", fmt("Failed to spawn subagent '%s'", agent_name), 0)
    return nil
  end

  self.child_chats[child_bufnr] = child_chat
  self:setup_child_listeners(child_bufnr, child_chat, task_index)

  subagent.utils.fire("SubagentStarted", {
    parent_bufnr = self.parent_chat.bufnr,
    child_bufnr = child_bufnr,
    agent_name = agent_name,
    agent_type = "task",
    description = task_def.description,
    task_index = task_index,
    total_tasks = #self.tasks,
  })

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
    ---@param tools table
    ---@param args table
    ---@param opts table
    compat.cmds(function(tools, args, opts)
      local output_handler = opts.output_cb
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
    end),
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
The user can navigate to subagent chats with keymap to see detailed output.]],
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
                  -- TODO: need mechanism to add new subagents dynamically
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
    on_exit = compat.handler_on_exit(function(_self, _meta)
      log:trace("[Task Tool] on_exit handler executed")
    end),
  },
  output = {
    cmd_string = compat.output_cmd_string(function(self, _meta)
      local tasks = self.args.tasks or {}
      if #tasks == 1 then
        return fmt("Spawn %s subagent: %s", subagent.utils.capitalize(tasks[1].subagent_type), tasks[1].description)
      end
      return fmt("Spawn %d subagents in parallel", #tasks)
    end),

    prompt = compat.output_prompt(function(self, _meta)
      local tasks = self.args.tasks or {}
      local count = #tasks
      if count == 0 then return "Run task tool?" end

      local descriptions = {}
      for i, task in ipairs(tasks) do
        if i <= 3 then
          local icon = get_agent_icon(task.subagent_type)
          table.insert(
            descriptions,
            fmt("%s %s: %s", icon, subagent.utils.capitalize(task.subagent_type), task.description)
          )
        end
      end

      if count > 3 then table.insert(descriptions, fmt("... and %d more", count - 3)) end

      local header = count == 1 and "Spawn subagent?" or fmt("Spawn %d subagents in parallel?", count)
      return header .. "\n\n" .. table.concat(descriptions, "\n")
    end),

    success = compat.output_success(function(self, stdout, meta)
      local chat = meta.tools.chat
      local output = vim.iter(stdout):flatten():join("\n")

      local tasks = self.args.tasks or {}
      local task_count = #tasks

      local success_match = output:match("(%d+) succeeded")
      local failed_match = output:match("(%d+) failed")
      local duration_match = output:match("total time: ([^)]+)")
      local total_tools_match = output:match("(%d+) total tools")

      local user_lines = {}

      if task_count == 1 then
        local task = tasks[1]
        local icon = get_agent_icon(task.subagent_type)
        local tools_match = output:match('tools="(%d+)"')

        table.insert(
          user_lines,
          fmt("───── **%s %s Complete** ─────", icon, subagent.utils.capitalize(task.subagent_type))
        )
        table.insert(user_lines, fmt("  **%s Task:** %s", ICONS.task, task.description))
        if tools_match then
          table.insert(user_lines, fmt("  **%s ToolCalls:** %s", subagent.utils.STATUS_ICONS.tools, tools_match))
        end
        if duration_match then
          table.insert(user_lines, fmt("  **%s Duration:** %s", subagent.utils.STATUS_ICONS.timer, duration_match))
        end
        table.insert(
          user_lines,
          "─────────────────────────────────────"
        )
      else
        local agent_tool_counts = {}
        for agent, task_desc, tools_count in
          output:gmatch('<subagent_result agent="([^"]+)" task="([^"]+)" status="[^"]*" tools="(%d+)"')
        do
          agent_tool_counts[task_desc] = { agent = agent, tools = tonumber(tools_count) }
        end

        table.insert(
          user_lines,
          fmt("═══════ **SubAgents Complete (%d)** ═══════", task_count)
        )
        for _, task in ipairs(tasks) do
          local icon = get_agent_icon(task.subagent_type)
          local tool_info = ""
          local agent_data = agent_tool_counts[task.description]
          if agent_data then tool_info = fmt(" (%d ToolCalls)", agent_data.tools) end
          table.insert(
            user_lines,
            fmt("  **%s %s:** %s%s", icon, subagent.utils.capitalize(task.subagent_type), task.description, tool_info)
          )
        end
        if success_match then
          table.insert(user_lines, fmt("  **%s Succeeded:** %s", subagent.utils.STATUS_ICONS.completed, success_match))
        end
        if failed_match and failed_match ~= "0" then
          table.insert(user_lines, fmt("  **%s Failed:** %s", subagent.utils.STATUS_ICONS.failed, failed_match))
        end
        if total_tools_match then
          table.insert(
            user_lines,
            fmt("  **%s Total toolCalls:** %s", subagent.utils.STATUS_ICONS.tools, total_tools_match)
          )
        end
        if duration_match then
          table.insert(user_lines, fmt("  **%s Duration:** %s", subagent.utils.STATUS_ICONS.timer, duration_match))
        end
        table.insert(
          user_lines,
          "══════════════════════════════════════════"
        )
      end

      local user_output = table.concat(user_lines, "\n")

      chat:add_tool_output(self, output, user_output)
    end),

    error = compat.output_error(function(self, stderr, meta)
      local chat = meta.tools.chat
      local output = vim.iter(stderr):flatten():join("\n")

      local tasks = self.args.tasks or {}
      local task_count = #tasks

      local failed_match = output:match("(%d+) failed")
      local duration_match = output:match("total time: ([^)]+)")
      local total_tools_match = output:match("(%d+) total tools")

      local user_lines = {}

      if task_count == 1 then
        local task = tasks[1]
        local icon = get_agent_icon(task.subagent_type)
        local tools_match = output:match('tools="(%d+)"')

        table.insert(
          user_lines,
          fmt("───── **%s %s** Failed ─────", icon, subagent.utils.capitalize(task.subagent_type))
        )
        table.insert(user_lines, fmt("  **%s Task:** %s", ICONS.task, task.description))
        if tools_match then
          table.insert(user_lines, fmt("  **%s ToolCalls:** %s", subagent.utils.STATUS_ICONS.tools, tools_match))
        end
        if duration_match then
          table.insert(user_lines, fmt("  **%s Duration:** %s", subagent.utils.STATUS_ICONS.timer, duration_match))
        end
        table.insert(user_lines, fmt("  **%s Status:** Failed", subagent.utils.STATUS_ICONS.failed))
        table.insert(
          user_lines,
          "─────────────────────────────────────"
        )
      else
        table.insert(
          user_lines,
          fmt("═══════ **SubAgents Failed (%d)** ═══════", task_count)
        )
        for _, task in ipairs(tasks) do
          local icon = get_agent_icon(task.subagent_type)
          table.insert(
            user_lines,
            fmt("  **%s %s:** %s", icon, subagent.utils.capitalize(task.subagent_type), task.description)
          )
        end
        if failed_match then
          table.insert(user_lines, fmt("  **%s Failed:** %s", subagent.utils.STATUS_ICONS.failed, failed_match))
        end
        if total_tools_match then
          table.insert(
            user_lines,
            fmt("  **%s Total ToolCalls:** %s", subagent.utils.STATUS_ICONS.tools, total_tools_match)
          )
        end
        if duration_match then
          table.insert(user_lines, fmt("  **%s Duration:** %s", subagent.utils.STATUS_ICONS.timer, duration_match))
        end
        table.insert(
          user_lines,
          "══════════════════════════════════════════"
        )
      end

      local user_output = table.concat(user_lines, "\n")

      chat:add_tool_output(self, output, user_output)
    end),
  },
}
