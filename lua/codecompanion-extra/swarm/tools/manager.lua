-- Manager tool for swarm orchestration
-- Allows the orchestrating agent to create swarms, define agents/tasks, and control execution

local log = require("codecompanion.utils.log")
local compat = require("codecompanion-extra.tools.compat")

local fmt = string.format
local api = vim.api

-- ============================================================================
-- Constants
-- ============================================================================

local MAX_AGENTS = 10
local MAX_TASKS = 100

-- ============================================================================
-- Helper Functions
-- ============================================================================

---Validate agent definition
---@param agent table
---@return boolean valid
---@return string|nil error
local function validate_agent(agent)
  if not agent.name or type(agent.name) ~= "string" or agent.name == "" then
    return false, "Agent must have a non-empty name"
  end

  if not agent.category or type(agent.category) ~= "string" or agent.category == "" then
    return false, fmt("Agent '%s' must have a category", agent.name)
  end

  if not agent.system_prompt or type(agent.system_prompt) ~= "string" then
    return false, fmt("Agent '%s' must have a system_prompt", agent.name)
  end

  if agent.tools and type(agent.tools) ~= "table" then
    return false, fmt("Agent '%s' tools must be an array", agent.name)
  end

  return true, nil
end

---Validate task definition
---@param task table
---@return boolean valid
---@return string|nil error
local function validate_task(task)
  if not task.content or type(task.content) ~= "string" or task.content == "" then
    return false, "Task must have non-empty content"
  end

  if not task.category or type(task.category) ~= "string" or task.category == "" then
    return false, "Task must have a category"
  end

  local valid_priorities = { critical = true, high = true, medium = true, low = true }
  if task.priority and not valid_priorities[task.priority] then
    return false, fmt("Invalid priority '%s'", task.priority)
  end

  return true, nil
end

---Detect cycles in task dependency graph (DFS)
---@param tasks table[]
---@return boolean has_cycle
---@return string|nil description
local function validate_task_dag(tasks)
  local adj = {}
  local id_set = {}
  for i, task in ipairs(tasks) do
    local id = task.id or fmt("task_%d", i)
    id_set[id] = true
    adj[id] = task.dependencies or {}
  end

  for id, deps in pairs(adj) do
    for _, dep in ipairs(deps) do
      if not id_set[dep] then return true, fmt("Task '%s' depends on non-existent task '%s'", id, dep) end
    end
  end

  local visited = {}
  local rec_stack = {}

  local function visit(node)
    if rec_stack[node] then return true end
    if visited[node] then return false end
    visited[node] = true
    rec_stack[node] = true
    for _, dep in ipairs(adj[node] or {}) do
      if visit(dep) then return true end
    end
    rec_stack[node] = nil
    return false
  end

  for id in pairs(id_set) do
    if visit(id) then return true, "Dependency cycle detected in tasks" end
  end

  return false, nil
end

-- ============================================================================
-- Active Orchestrators Registry
-- ============================================================================

---@type table<number, table> bufnr -> SwarmOrchestrator
local _active_orchestrators = {}

---Build a compact list of available tool names + descriptions from CodeCompanion config.
---Excludes swarm worker tools (auto-added) and the swarm manager itself.
---@return string
local function _build_available_tools_list()
  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return "" end

  local chat_tools = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.tools
  if not chat_tools then return "" end

  local skip = {
    swarm = true,
    claim_task = true,
    complete_task = true,
    release_task = true,
    lock_file = true,
    unlock_file = true,
    send_update = true,
    send_to_peer = true,
    read_messages = true,
    get_swarm_status = true,
  }

  local entries = {}
  for name, config in pairs(chat_tools) do
    if type(config) == "table" and not skip[name] and name ~= "groups" and name ~= "opts" then
      local desc = ""
      if config.description and type(config.description) == "string" then
        desc = config.description:match("^([^\n%.]+)") or config.description
        if #desc > 72 then desc = desc:sub(1, 69) .. "..." end
      end
      table.insert(entries, { name = name, desc = desc })
    end
  end

  table.sort(entries, function(a, b)
    return a.name < b.name
  end)

  local lines = {}
  for _, e in ipairs(entries) do
    if e.desc ~= "" then
      table.insert(lines, fmt("  - %s: %s", e.name, e.desc))
    else
      table.insert(lines, fmt("  - %s", e.name))
    end
  end

  if #lines == 0 then return "" end
  return "\nAVAILABLE TOOLS FOR AGENTS (use these names in the tools array):\n" .. table.concat(lines, "\n")
end

local _cached_tool_list = nil

-- ============================================================================
-- Command Handlers
-- ============================================================================

---Handle "start" command
---Handle "start" command
---@param chat table
---@param args table
---@param output_handler function
---@return table|nil
local function handle_start(chat, args, output_handler)
  local agents = args.agents
  local tasks = args.tasks

  if not agents or #agents == 0 then
    return { status = "error", data = "No agents defined. Provide at least one agent." }
  end

  if #agents > MAX_AGENTS then
    return { status = "error", data = fmt("Maximum %d agents allowed, got %d", MAX_AGENTS, #agents) }
  end

  if not tasks or #tasks == 0 then
    return { status = "error", data = "No tasks defined. Provide at least one task." }
  end

  if #tasks > MAX_TASKS then
    return { status = "error", data = fmt("Maximum %d tasks allowed, got %d", MAX_TASKS, #tasks) }
  end

  local agent_names = {}
  for i, agent in ipairs(agents) do
    local valid, err = validate_agent(agent)
    if not valid then return { status = "error", data = fmt("Invalid agent[%d]: %s", i, err) } end

    if agent_names[agent.name] then
      return { status = "error", data = fmt("Duplicate agent name: '%s'", agent.name) }
    end
    agent_names[agent.name] = true
  end

  local agent_categories = {}
  for _, agent in ipairs(agents) do
    agent_categories[agent.category] = true
  end

  for i, task in ipairs(tasks) do
    local valid, err = validate_task(task)
    if not valid then return { status = "error", data = fmt("Invalid task[%d]: %s", i, err) } end

    if not agent_categories[task.category] then
      return {
        status = "error",
        data = fmt("Task[%d] category '%s' has no matching agent", i, task.category),
      }
    end
  end

  local has_deps = false
  for _, task in ipairs(tasks) do
    if task.dependencies and #task.dependencies > 0 then
      has_deps = true
      break
    end
  end
  if has_deps then
    local has_cycle, cycle_err = validate_task_dag(tasks)
    if has_cycle then return { status = "error", data = cycle_err } end
  end

  if not api.nvim_buf_is_valid(chat.bufnr) then
    return { status = "error", data = "Manager chat closed before spawn" }
  end

  if _active_orchestrators[chat.bufnr] then
    return { status = "error", data = "A swarm is already running. Stop it first or wait for completion." }
  end

  _active_orchestrators[chat.bufnr] = { status = "initializing" }

  local orchestrator_mod = require("codecompanion-extra.swarm.orchestrator")

  local orchestrator = orchestrator_mod.SwarmOrchestrator.new({
    manager_chat = chat,
    output_handler = function(result)
      _active_orchestrators[chat.bufnr] = nil
      output_handler(result)
    end,
  })

  for _, agent_def in ipairs(agents) do
    local _, err = orchestrator:define_agent(agent_def)
    if err then
      _active_orchestrators[chat.bufnr] = nil
      return { status = "error", data = fmt("Failed to define agent: %s", err) }
    end
  end

  orchestrator:define_tasks(tasks)

  local success, start_err = orchestrator:start()
  if not success then
    _active_orchestrators[chat.bufnr] = nil
    return { status = "error", data = fmt("Failed to start swarm: %s", start_err or "unknown error") }
  end

  _active_orchestrators[chat.bufnr] = orchestrator

  log:info("[Swarm Manager] Started swarm with %d agents, %d tasks", #agents, #tasks)

  return nil
end

---Handle "add_tasks" command
---@param bufnr number
---@param args table
---@return table
local function handle_add_tasks(bufnr, args)
  local orchestrator = _active_orchestrators[bufnr]
  if not orchestrator then return { status = "error", data = "No active swarm. Start one first." } end

  local tasks = args.tasks
  if not tasks or #tasks == 0 then return { status = "error", data = "No tasks provided" } end

  for i, task in ipairs(tasks) do
    local valid, err = validate_task(task)
    if not valid then return { status = "error", data = fmt("Invalid task[%d]: %s", i, err) } end
  end

  orchestrator:add_tasks(tasks)

  return {
    status = "success",
    data = fmt("Added %d tasks to swarm", #tasks),
  }
end

---Handle "send_message" command
---@param bufnr number
---@param args table
---@return table
local function handle_send_message(bufnr, args)
  local orchestrator = _active_orchestrators[bufnr]
  if not orchestrator then return { status = "error", data = "No active swarm. Start one first." } end

  local to = args.to
  local content = args.content

  if not to or not content then return { status = "error", data = "Missing required: to, content" } end

  orchestrator:send_message({
    to = to,
    content = content,
    priority = args.priority,
  })

  local recipient = to == "*" and "all agents" or fmt("'%s'", to)
  return {
    status = "success",
    data = fmt("Message sent to %s", recipient),
  }
end

---Handle "status" command
---@param bufnr number
---@return table
local function handle_status(bufnr)
  local orchestrator = _active_orchestrators[bufnr]
  if not orchestrator then return { status = "success", data = "No active swarm" } end

  return {
    status = "success",
    data = orchestrator:format_status(),
  }
end

---Handle "stop" command
---@param bufnr number
---@param args table
---@return table
local function handle_stop(bufnr, args)
  local orchestrator = _active_orchestrators[bufnr]
  if not orchestrator then return { status = "error", data = "No active swarm to stop" } end

  local reason = args.reason or "Stopped by manager"
  orchestrator:stop(reason)

  _active_orchestrators[bufnr] = nil

  return {
    status = "success",
    data = fmt("Swarm stopped: %s", reason),
  }
end

-- ============================================================================
-- Tool Definition
-- ============================================================================

local ICON = "󰾡"

---@class CodeCompanion.Tool.Swarm: CodeCompanion.Tools.Tool
local swarm = {
  name = "swarm",
  cmds = {
    compat.cmds(function(tools, args, opts)
      local output_handler = opts.output_cb
      if not tools or not tools.chat then return { status = "error", data = "No chat context available" } end

      local command = args.command
      if not command then return { status = "error", data = "Missing required parameter: command" } end

      local chat = tools.chat
      local bufnr = chat.bufnr

      if command == "start" then
        return handle_start(chat, args, output_handler)
      elseif command == "add_tasks" then
        return handle_add_tasks(bufnr, args)
      elseif command == "send_message" then
        return handle_send_message(bufnr, args)
      elseif command == "status" then
        return handle_status(bufnr)
      elseif command == "stop" then
        return handle_stop(bufnr, args)
      else
        return { status = "error", data = fmt("Unknown command: %s", command) }
      end
    end),
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "swarm",
      description = [[Orchestrate a swarm of specialized agents working in parallel.

COMMANDS:
- "start": Initialize and start a new swarm with agents and tasks
- "add_tasks": Add more tasks to a running swarm
- "send_message": Send instructions to agents
- "status": Get current swarm status
- "stop": Stop the swarm

WORKFLOW:
1. Use "start" with agents and tasks definitions
2. Swarm runs autonomously - agents claim and complete tasks
3. Monitor with "status", adjust with "add_tasks" or "send_message"
4. Results returned when all tasks complete (or use "stop")

AGENT DEFINITION:
Each agent needs: name, category, system_prompt, tools (array of tool names)
Agents automatically get swarm coordination tools (claim_task, lock_file, etc.)

TASK DEFINITION:
Each task needs: content (description), category (matches agent category)
Optional: priority (critical/high/medium/low), dependencies (array of task IDs)]],
      parameters = {
        type = "object",
        properties = {
          command = {
            type = "string",
            enum = { "start", "add_tasks", "send_message", "status", "stop" },
            description = "Swarm command to execute",
          },
          agents = {
            type = "array",
            description = "[start] Agent definitions to spawn",
            items = {
              type = "object",
              properties = {
                name = {
                  type = "string",
                  description = "Unique agent name (e.g., 'frontend_dev', 'api_specialist')",
                },
                category = {
                  type = "string",
                  description = "Task category this agent handles (e.g., 'frontend', 'backend')",
                },
                system_prompt = {
                  type = "string",
                  description = "Custom system prompt defining agent's expertise and behavior",
                },
                tools = {
                  type = "array",
                  items = { type = "string" },
                  description = "Tool names available to this agent (e.g., 'read_file', 'insert_edit_into_file')",
                },
              },
              required = { "name", "category", "system_prompt" },
            },
          },
          tasks = {
            type = "array",
            description = "[start, add_tasks] Task definitions",
            items = {
              type = "object",
              properties = {
                content = {
                  type = "string",
                  description = "Task description - what needs to be done",
                },
                category = {
                  type = "string",
                  description = "Category (must match an agent's category)",
                },
                priority = {
                  type = "string",
                  enum = { "critical", "high", "medium", "low" },
                  description = "Task priority (default: medium)",
                },
                dependencies = {
                  type = "array",
                  items = { type = "string" },
                  description = "Task IDs that must complete before this task",
                },
              },
              required = { "content", "category" },
            },
          },
          to = {
            type = "string",
            description = "[send_message] Recipient: agent name or '*' for broadcast",
          },
          content = {
            type = "string",
            description = "[send_message] Message content",
          },
          priority = {
            type = "string",
            enum = { "normal", "urgent" },
            description = "[send_message] Message priority",
          },
          reason = {
            type = "string",
            description = "[stop] Reason for stopping the swarm",
          },
        },
        required = { "command" },
      },
    },
  },
  handlers = {
    on_exit = compat.handler_on_exit(function(_self, _meta)
      log:trace("[Swarm Tool] on_exit handler executed")
    end),
  },
  output = {
    ---@param self CodeCompanion.Tool.Swarm
    ---@return string
    cmd_string = compat.output_cmd_string(function(self, _meta)
      local command = self.args and self.args.command or "unknown"
      return fmt("%s Swarm: %s", ICON, command)
    end),

    ---@param self CodeCompanion.Tool.Swarm
    ---@return string
    prompt = compat.output_prompt(function(self, _meta)
      local command = self.args and self.args.command or "unknown"
      if command == "start" then
        local agent_count = self.args.agents and #self.args.agents or 0
        local task_count = self.args.tasks and #self.args.tasks or 0
        return fmt("%s Start swarm with %d agents and %d tasks?", ICON, agent_count, task_count)
      elseif command == "stop" then
        return fmt("%s Stop the running swarm?", ICON)
      end
      return fmt("%s Execute swarm command: %s?", ICON, command)
    end),

    ---@param self CodeCompanion.Tool.Swarm
    ---@param stdout table
    ---@param meta table
    success = compat.output_success(function(self, stdout, meta)
      local chat = meta.tools.chat
      local output = vim.iter(stdout):flatten():join("\n")
      local command = self.args and self.args.command or "unknown"

      local user_output = fmt(
        "───── %s Swarm (%s) ─────\n%s\n─────────────────────────",
        ICON,
        command,
        output
      )
      chat:add_tool_output(self, output, user_output)
    end),

    ---@param self CodeCompanion.Tool.Swarm
    ---@param stderr table
    ---@param meta table
    error = compat.output_error(function(self, stderr, meta)
      local chat = meta.tools.chat
      local output = vim.iter(stderr):flatten():join("\n")
      local command = self.args and self.args.command or "unknown"

      local error_output = fmt("Swarm %s failed:\n%s", command, output)
      chat:add_tool_output(self, error_output, error_output)
    end),
  },
}

-- ============================================================================
-- Module Exports
-- ============================================================================

local M = {}

---Get the swarm manager tool
---Lazily injects available tool names into the description on first call
---@return table
function M.get_tool()
  if not _cached_tool_list then
    _cached_tool_list = _build_available_tools_list()
    if _cached_tool_list ~= "" then
      swarm.schema["function"].description = swarm.schema["function"].description .. _cached_tool_list
    end
  end
  return swarm
end

---Get active orchestrator for a buffer
---@param bufnr number
---@return table|nil
function M.get_orchestrator(bufnr)
  return _active_orchestrators[bufnr]
end

---Check if a swarm is active
---@param bufnr number
---@return boolean
function M.is_active(bufnr)
  return _active_orchestrators[bufnr] ~= nil
end

---Clear all orchestrators (for testing)
function M.clear_all()
  for bufnr, orchestrator in pairs(_active_orchestrators) do
    pcall(function()
      orchestrator:stop("Cleared")
    end)
  end
  _active_orchestrators = {}
end

return M
