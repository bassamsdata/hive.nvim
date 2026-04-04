-- SwarmAgent: Worker agent that executes tasks within a swarm
-- Uses shared subagent infrastructure for chat lifecycle, events, and hierarchy

local log = require("codecompanion.utils.log")
local subagent = require("codecompanion-extra.tools.subagent")

local fmt = string.format
local uv = vim.uv

-- ============================================================================
-- Constants
-- ============================================================================

local ICONS = {
  working = "",
  waiting = "",
  completed = "\u{2713}",
  failed = "\u{2717}",
  idle = "\u{25CB}",
}

local WORKER_TOOLS = {
  "claim_task",
  "complete_task",
  "release_task",
  "lock_file",
  "unlock_file",
  "send_update",
  "send_to_peer",
  "read_messages",
  "get_swarm_status",
}

local SUSPICIOUS_FAST_MS = 2000
local MAX_RESUBMIT_ATTEMPTS = 3
local SWARM_IDLE_TIMEOUT_MS = 300000 -- 5 minutes for swarm agents (they do sequential tasks)

-- ============================================================================
-- SwarmAgent Class
-- ============================================================================

---@class SwarmAgent
---@field name string Agent name
---@field category string Task category this agent handles
---@field session_id string Swarm session ID
---@field bufnr number|nil Chat buffer number
---@field chat table|nil Chat instance
---@field system_prompt string Custom system prompt
---@field tools string[] Available tools (user-defined + worker tools)
---@field status "idle"|"working"|"waiting"|"completed"|"failed"
---@field current_task_id string|nil Current task ID
---@field tasks_completed number Count of completed tasks
---@field tools_used number Count of tools executed
---@field created_at number Creation timestamp
---@field started_at number|nil When agent started working (hrtime nanoseconds)
---@field aug number|nil Autogroup for events
---@field timeout_timer uv.uv_timer_t|nil Idle timeout timer
local SwarmAgent = {}
SwarmAgent.__index = SwarmAgent

-- ============================================================================
-- Constructor
-- ============================================================================

---Create a new SwarmAgent
---@param args { name: string, category: string, session_id: string, system_prompt: string, tools: string[] }
---@return SwarmAgent
function SwarmAgent.new(args)
  local self = setmetatable({}, SwarmAgent)

  self.name = args.name
  self.category = args.category
  self.session_id = args.session_id
  self.system_prompt = args.system_prompt
  self.tools = args.tools or {}
  self.bufnr = nil
  self.chat = nil
  self.status = "idle"
  self.current_task_id = nil
  self.tasks_completed = 0
  self.tools_used = 0
  self.created_at = os.time()
  self.started_at = nil
  self.aug = nil
  self.timeout_timer = nil
  self.resubmit_count = 0

  return self
end

-- ============================================================================
-- System Prompt
-- ============================================================================

---Build the full system prompt including swarm instructions
---@return string
function SwarmAgent:build_system_prompt()
  local ok, registry = pcall(require, "codecompanion-extra.agents.registry")
  if ok then
    local agent_def = registry.get("swarm_worker")
    if agent_def and agent_def.system_prompt then
      local base_prompt = type(agent_def.system_prompt) == "function" and agent_def.system_prompt(self.chat)
        or agent_def.system_prompt
      return fmt(
        '<swarm-context>\nYour name is "%s". You are specialized in "%s" tasks.\n</swarm-context>\n\n%s\n\n%s',
        self.name,
        self.category,
        base_prompt,
        self.system_prompt
      )
    end
  end

  -- Fallback if registry not available
  return fmt(
    [[<swarm-agent>
You are a swarm worker agent named "%s" specialized in "%s" tasks.

MANDATORY WORKFLOW (execute in order, no deviations):
1. Call `read_messages` and process ALL messages
   - If STOP message received: finish current work, call `complete_task`, then STOP
   - Process urgent messages immediately before claiming new tasks
2. Call `claim_task` with your category
   - If no task available: you are COMPLETE — stop working
   - If claim succeeds: proceed to step 3
3. Before editing ANY file, call `lock_file(path)`
   - If lock fails: retry up to 2 more times, then call `release_task(reason="blocked")` and return to step 1
4. Execute the task using your available tools
   - If any tool fails after 2 retries: call `release_task(reason="cannot_complete")` and return to step 1
5. Call `unlock_file(path)` for ALL locked files immediately after editing
   - Release locks even if the task failed
6. Call `complete_task` with a brief result summary
7. Return to step 1

COMMUNICATION:
- Call `read_messages` BEFORE each new task claim (step 1)
- Use `send_update` for: completed milestones, blocking issues, unexpected errors
- Use `send_to_peer` to coordinate with other agents when tasks overlap

LOCKING RULES:
- NEVER edit a file without acquiring its lock first
- ALWAYS release locks before: completing a task, releasing a task, or claiming a new task
- If `lock_file` fails, another agent owns that file — do not retry indefinitely

ERROR HANDLING:
- Tool failures: retry once, then release task if still failing
- Lock failures: release task with reason "blocked", move to next task
- Never hang — if stuck, release task and move on
</swarm-agent>

%s]],
    self.name,
    self.category,
    self.system_prompt
  )
end

---Get the combined tools list (user tools + worker tools)
---@return string[]
function SwarmAgent:get_all_tools()
  local all_tools = vim.deepcopy(self.tools)

  for _, tool in ipairs(WORKER_TOOLS) do
    if not vim.tbl_contains(all_tools, tool) then table.insert(all_tools, tool) end
  end

  return all_tools
end

-- ============================================================================
-- Chat Creation via Shared Lifecycle
-- ============================================================================

---Create the chat instance using shared subagent lifecycle
---@param parent_chat table Parent (manager) chat for context
---@return boolean success
---@return string|nil error
function SwarmAgent:create_chat(parent_chat)
  local lifecycle = subagent.lifecycle

  local child_chat = lifecycle.create_child_chat({
    parent_chat = parent_chat,
    model_type = "small",
  })
  if not child_chat then return false, "Failed to create chat" end

  self.bufnr = child_chat.bufnr
  self.chat = child_chat

  if not child_chat.hidden then
    lifecycle.hide_child_restore_parent({
      child_chat = child_chat,
      parent_chat = parent_chat,
    })
  end

  -- Register in hierarchy
  lifecycle.create_hierarchy_session({
    child_bufnr = self.bufnr,
    parent_bufnr = parent_chat.bufnr,
    agent_name = fmt("swarm:%s", self.name),
    description = fmt("Swarm worker [%s] (%s)", self.name, self.category),
    hidden = true,
  })

  log:debug("[SwarmAgent] Created chat for agent '%s' (bufnr: %d)", self.name, self.bufnr)

  return true, nil
end

-- ============================================================================
-- Event Handling via Shared Lifecycle
-- ============================================================================

---Setup event listeners using shared subagent infrastructure
function SwarmAgent:setup_events()
  if not self.bufnr then return end

  local lifecycle = subagent.lifecycle
  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local tool_call_counter = 0

  self.aug = lifecycle.setup_listeners({
    child_bufnr = self.bufnr,
    group_name = "swarm_agent_" .. self.name .. "_" .. self.bufnr,
    callbacks = {
      on_tool_started = function(_event, tool_name)
        tool_call_counter = tool_call_counter + 1
        self.tools_used = tool_call_counter
        self.resubmit_count = 0

        local tool_id = fmt("tool_%d", tool_call_counter)
        hierarchy.tool_started(self.bufnr, tool_id, tool_name)
        self:_reset_timeout_timer()

        local session_mod = require("codecompanion-extra.swarm.session")
        local session = session_mod.get(self.session_id)
        if session then session:increment_agent_tools(self.name) end

        subagent.utils.fire("SubagentProgress", {
          parent_bufnr = hierarchy.get_parent(self.bufnr),
          child_bufnr = self.bufnr,
          agent_name = self.name,
          agent_type = "swarm",
          tool_name = tool_name,
          tool_count = tool_call_counter,
        })
      end,

      on_tool_finished = function(_event, tool_name)
        local tool_id = fmt("tool_%d", tool_call_counter)
        hierarchy.tool_finished(self.bufnr, tool_id, true, tool_name)
        self:_reset_timeout_timer()
      end,

      on_done = function()
        self:on_chat_done()
      end,

      on_stopped = function()
        self:on_stopped()
      end,

      on_closed = function()
        self:on_closed()
      end,
    },
  })
end

---Cleanup event listeners
function SwarmAgent:cleanup_events()
  subagent.lifecycle.cleanup_listeners(self.aug)
  self.aug = nil
  self:_stop_timeout_timer()
end

-- ============================================================================
-- Timeout Management
-- ============================================================================

---Reset the idle timeout timer
function SwarmAgent:_reset_timeout_timer()
  self:_stop_timeout_timer()

  self.timeout_timer = subagent.utils.create_timeout_timer({
    delay_ms = SWARM_IDLE_TIMEOUT_MS,
    on_timeout = function()
      if self.status ~= "working" and self.status ~= "idle" then return end

      local elapsed_sec = math.floor(SWARM_IDLE_TIMEOUT_MS / 1000)
      log:warn(
        "[SwarmAgent] Agent '%s' timed out after %ds of inactivity (tools used: %d)",
        self.name,
        elapsed_sec,
        self.tools_used
      )

      self:fail(fmt("Timed out after %d seconds of no tool activity", elapsed_sec), true)
    end,
  })
end

---Stop the idle timeout timer
function SwarmAgent:_stop_timeout_timer()
  subagent.utils.safe_close_timer(self.timeout_timer)
  self.timeout_timer = nil
end

-- ============================================================================
-- Lifecycle Events
-- ============================================================================

---Called when chat completes a response
function SwarmAgent:on_chat_done()
  local ok, err = pcall(function()
    local chat_errored = self.chat and self.chat.status == "error"

    if chat_errored then
      self:fail("Chat API error")
      return
    end

    local session_mod = require("codecompanion-extra.swarm.session")
    local session = session_mod.get(self.session_id)

    if not session then
      log:warn("[SwarmAgent] No session found for agent '%s'", self.name)
      return
    end

    if self.started_at then
      local models = require("codecompanion-extra.tools.subagent.models")
      local elapsed_ms = subagent.utils.get_elapsed_ms(self.started_at)
      local is_suspicious, suspicious_msg = models.detect_suspicious_fast_completion({
        elapsed_ms = elapsed_ms,
        tool_count = self.tools_used,
        threshold_ms = SUSPICIOUS_FAST_MS,
        subagent_type = self.name,
        context = "swarm",
      })
      if is_suspicious then
        self:fail(suspicious_msg)
        return
      end
    end

    if session:has_stop_signal(self.name) then
      self:complete("Received stop signal")
      return
    end

    if session.status ~= session_mod.SESSION_STATUS.ACTIVE then
      self:complete("Session no longer active")
      return
    end

    -- Check if there's any work this agent could still do (across all categories)
    if session:has_available_work(self.name) then
      -- LLM returned text instead of making tool calls — resubmit
      self:_resubmit("Tasks remain in your queue. Continue: read_messages, then claim_task.")
      return
    end

    self:complete("No more tasks available")
  end)

  if not ok then
    log:error("[SwarmAgent] on_chat_done error for '%s': %s", self.name, tostring(err))
    self:fail(fmt("Internal error in on_chat_done: %s", tostring(err)))
  end
end

---Called when chat is stopped
function SwarmAgent:on_stopped()
  local ok, err = pcall(function()
    self:fail("Chat was stopped")
  end)
  if not ok then log:error("[SwarmAgent] on_stopped error for '%s': %s", self.name, tostring(err)) end
end

---Called when chat is closed
function SwarmAgent:on_closed()
  local ok, err = pcall(function()
    if self.status ~= "completed" and self.status ~= "failed" then self:fail("Chat was closed unexpectedly") end
  end)
  if not ok then log:error("[SwarmAgent] on_closed error for '%s': %s", self.name, tostring(err)) end
end

---Resubmit the chat with a nudge message when the LLM returned text instead of tool calls
---@param message string
function SwarmAgent:_resubmit(message)
  self.resubmit_count = self.resubmit_count + 1

  if self.resubmit_count > MAX_RESUBMIT_ATTEMPTS then
    log:warn(
      "[SwarmAgent] Agent '%s' exceeded max resubmit attempts (%d), marking failed",
      self.name,
      MAX_RESUBMIT_ATTEMPTS
    )
    self:fail(fmt("Exceeded %d resubmit attempts without making progress", MAX_RESUBMIT_ATTEMPTS))
    return
  end

  if not self.chat then
    self:fail("Cannot resubmit: no chat instance")
    return
  end

  log:debug(
    "[SwarmAgent] Resubmitting agent '%s' (attempt %d/%d)",
    self.name,
    self.resubmit_count,
    MAX_RESUBMIT_ATTEMPTS
  )

  self:_reset_timeout_timer()

  local ok, cc_config = pcall(require, "codecompanion.config")
  if ok then
    self.chat:add_message({
      role = cc_config.constants.USER_ROLE,
      content = message,
    }, { visible = true })

    self.chat:submit({ auto_submit = true })
  end
end

-- ============================================================================
-- Agent Control
-- ============================================================================

---Start the agent working
---@param initial_message? string Optional initial message to send
---@return boolean success
function SwarmAgent:start(initial_message)
  if not self.chat then return false end

  self.started_at = uv.hrtime()
  self.status = "working"

  local session_mod = require("codecompanion-extra.swarm.session")
  local session = session_mod.get(self.session_id)
  if session then session:set_agent_status(self.name, "working") end

  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  hierarchy.start_timer(self.bufnr)

  -- Setup event listeners
  self:setup_events()
  self:_reset_timeout_timer()

  local message = initial_message
    or fmt(
      [[Start working on "%s" tasks.
First read your messages, then claim and complete tasks until none remain.]],
      self.category
    )

  local ok, cc_config = pcall(require, "codecompanion.config")
  if ok then
    self.chat:add_message({
      role = cc_config.constants.USER_ROLE,
      content = message,
    }, { visible = true })

    self.chat:submit({ auto_submit = true })
  end

  subagent.utils.fire("SubagentStarted", {
    parent_bufnr = hierarchy.get_parent(self.bufnr),
    child_bufnr = self.bufnr,
    agent_name = self.name,
    agent_type = "swarm",
    description = fmt("Swarm worker [%s] (%s)", self.name, self.category),
    total_tasks = 1,
  })

  log:info("[SwarmAgent] Agent '%s' started", self.name)

  return true
end

---Mark agent as completed
---@param result? string
function SwarmAgent:complete(result)
  if self.status == "completed" or self.status == "failed" then return end
  self.status = "completed"

  local session_mod = require("codecompanion-extra.swarm.session")
  local session = session_mod.get(self.session_id)
  if session then
    session:release_agent_locks(self.name)
    session:set_agent_status(self.name, "completed")

    session:send_message({
      from = self.name,
      to = "manager",
      type = "update",
      content = fmt("Agent completed: %d tasks, %d tools. %s", self.tasks_completed, self.tools_used, result or ""),
    })

    if session:all_agents_done() and session:all_tasks_done() then session:complete() end
  end

  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  hierarchy.set_status(self.bufnr, "completed", result)

  local elapsed_ms = self.started_at and subagent.utils.get_elapsed_ms(self.started_at) or 0
  subagent.utils.fire("SubagentCompleted", {
    parent_bufnr = hierarchy.get_parent(self.bufnr),
    child_bufnr = self.bufnr,
    agent_name = self.name,
    agent_type = "swarm",
    status = "success",
    duration_ms = elapsed_ms,
    tool_count = self.tools_used,
  })

  self:cleanup_events()

  log:info("[SwarmAgent] Agent '%s' completed (%d tasks)", self.name, self.tasks_completed)
end

---Mark agent as failed
---@param error_msg string
---@param silent? boolean If true, log at warn level instead of error (e.g. timeouts)
function SwarmAgent:fail(error_msg, silent)
  if self.status == "completed" or self.status == "failed" then return end
  self.status = "failed"

  local session_mod = require("codecompanion-extra.swarm.session")
  local session = session_mod.get(self.session_id)
  if session then
    session:release_agent_locks(self.name)
    session:release_task(self.name, "failed")
    session:set_agent_status(self.name, "failed")

    session:send_message({
      from = self.name,
      to = "manager",
      type = "update",
      content = fmt("Agent failed: %s", error_msg),
      priority = "urgent",
    })
  end

  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  hierarchy.set_status(self.bufnr, "failed", error_msg)

  local elapsed_ms = self.started_at and subagent.utils.get_elapsed_ms(self.started_at) or 0
  subagent.utils.fire("SubagentCompleted", {
    parent_bufnr = hierarchy.get_parent(self.bufnr),
    child_bufnr = self.bufnr,
    agent_name = self.name,
    agent_type = "swarm",
    status = "failed",
    duration_ms = elapsed_ms,
    tool_count = self.tools_used,
  })

  self:cleanup_events()

  if silent then
    log:warn("[SwarmAgent] Agent '%s' failed (silent): %s", self.name, error_msg)
  else
    log:error("[SwarmAgent] Agent '%s' failed: %s", self.name, error_msg)
  end
end

---Stop the agent
function SwarmAgent:stop()
  if self.status == "completed" or self.status == "failed" then return end

  if self.chat and self.chat.stop then pcall(self.chat.stop, self.chat) end

  self:complete("Stopped by request")
end

-- ============================================================================
-- Status & Info
-- ============================================================================

---Get agent status icon
---@return string
function SwarmAgent:get_icon()
  return ICONS[self.status] or ICONS.idle
end

---Get status summary
---@return table
function SwarmAgent:get_status()
  local duration = 0
  if self.started_at then duration = math.floor(subagent.utils.get_elapsed_ms(self.started_at) / 1000) end
  return {
    name = self.name,
    category = self.category,
    status = self.status,
    current_task = self.current_task_id,
    tasks_completed = self.tasks_completed,
    tools_used = self.tools_used,
    duration = duration,
  }
end

---Format status for display
---@return string
function SwarmAgent:format_status()
  local icon = self:get_icon()
  local task_info = self.current_task_id and fmt(" [%s]", self.current_task_id) or ""
  local duration = 0
  if self.started_at then duration = math.floor(subagent.utils.get_elapsed_ms(self.started_at) / 1000) end

  return fmt(
    "%s %s (%s)%s - %d tasks, %d tools, %ds",
    icon,
    self.name,
    self.status,
    task_info,
    self.tasks_completed,
    self.tools_used,
    duration
  )
end

-- ============================================================================
-- Task Operations (called by worker tools)
-- ============================================================================

---Set current task (called when task is claimed)
---@param task_id string
function SwarmAgent:set_current_task(task_id)
  self.current_task_id = task_id
  self.status = "working"
end

---Clear current task (called when task is completed/released)
function SwarmAgent:clear_current_task()
  self.current_task_id = nil
  self.status = "idle"
end

---Increment completed task count
function SwarmAgent:increment_completed()
  self.tasks_completed = self.tasks_completed + 1
end

-- ============================================================================
-- Module Exports
-- ============================================================================

return {
  SwarmAgent = SwarmAgent,
  ICONS = ICONS,
  WORKER_TOOLS = WORKER_TOOLS,
}
