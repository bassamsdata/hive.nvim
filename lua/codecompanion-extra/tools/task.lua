-- Task tool for spawning subagents (supports single or parallel execution)
-- Implements async pattern: parent waits for child completion
-- Provides real-time status updates via virtual line notifications with animated spinner

local log = require("codecompanion.utils.log")

local fmt = string.format

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local UPDATE_INTERVAL_MS = 100

---@class TaskBatchState
---@field tasks table[] Task definitions
---@field results table<number, { status: string, data: string, agent: string, description: string }>
---@field pending number Count of pending tasks
---@field timer userdata|nil Animation timer
---@field spinner_index number Current spinner frame
---@field parent_chat table Parent chat reference
---@field child_bufnrs number[] All child buffer numbers
---@field child_chats table<number, table> Child chat references by bufnr
---@field callback function Final callback when all complete
---@field start_time number Start time in hrtime nanoseconds

---@type table<number, TaskBatchState>
local active_batches = {}

---Get or create namespace for task status notifications
---@param parent_bufnr number
---@return number
local function get_status_namespace(parent_bufnr)
  return vim.api.nvim_create_namespace("codecompanion_task_" .. tostring(parent_bufnr))
end

---Check if a window is valid and visible
---@param winnr number|nil
---@return boolean
local function is_window_valid(winnr)
  if not winnr then return false end
  local ok, valid = pcall(vim.api.nvim_win_is_valid, winnr)
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

  if is_window_valid(ui.winnr) then pcall(vim.api.nvim_win_hide, ui.winnr) end
end

---Capitalize agent name for display
---@param name string
---@return string
local function capitalize_agent(name)
  if not name then return "Unknown" end
  return name:sub(1, 1):upper() .. name:sub(2)
end

---Build status text for all tasks
---@param batch TaskBatchState
---@param spinner_char string
---@return string
local function build_batch_status(batch, spinner_char)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")

  local elapsed_ns = vim.uv.hrtime() - batch.start_time
  local elapsed_ms = math.floor(elapsed_ns / 1000000)
  local elapsed_str = hierarchy.format_duration(elapsed_ms)

  local task_count = #batch.tasks
  local completed_count = task_count - batch.pending
  local header = task_count > 1
      and fmt("─────── SubAgents (%d/%d) ───────", completed_count, task_count)
    or "─────── SubAgent ───────"

  local lines = { header }

  for i, child_bufnr in ipairs(batch.child_bufnrs) do
    local session = hierarchy.get_session(child_bufnr)
    local task_def = batch.tasks[i]

    if session then
      local icon = ({
        explorer = "🔍",
        general = "📋",
        analyzer = "📊",
      })[session.agent_name] or "🤖"

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
        status_icon = "✓"
        status_text = fmt("Done (%d tools, %s)", summary.total, duration)
      elseif session.status == "failed" then
        status_icon = "✗"
        status_text = "Failed"
      elseif session.status == "cancelled" then
        status_icon = "⊘"
        status_text = "Cancelled"
      else
        status_icon = "○"
        status_text = "Pending"
      end

      table.insert(lines, fmt("  %s %s: %s", icon, display_name, task_def.description))
      table.insert(lines, fmt("    %s %s", status_icon, status_text))
    elseif task_def then
      table.insert(lines, fmt("  🤖 %s: %s", capitalize_agent(task_def.subagent_type), task_def.description))
      table.insert(lines, fmt("    %s Starting...", spinner_char))
    end
  end

  table.insert(lines, fmt("  ⏱ Total: %s", elapsed_str))

  return table.concat(lines, "\n")
end

---Render status notification in parent chat buffer using virtual lines
---@param batch TaskBatchState
---@param status_text string
local function render_batch_status(batch, status_text)
  local parent_chat = batch.parent_chat
  if not parent_chat or not parent_chat.bufnr or not vim.api.nvim_buf_is_valid(parent_chat.bufnr) then return end

  local ns_id = get_status_namespace(parent_chat.bufnr)
  local lines = vim.split(status_text, "\n")

  local virt_lines = {}
  table.insert(virt_lines, { { "", "Normal" } })

  for _, line in ipairs(lines) do
    local hl = "Comment"
    if line:match("^───") then
      hl = "Title"
    elseif line:match("Running") or line:match("Working") or line:match("Starting") then
      hl = "WarningMsg"
    elseif line:match("Done") or line:match("✓") then
      hl = "DiagnosticOk"
    elseif line:match("Failed") or line:match("Cancelled") or line:match("✗") or line:match("⊘") then
      hl = "ErrorMsg"
    elseif line:match("⏱") then
      hl = "DiagnosticInfo"
    elseif line:match("^  🔍") or line:match("^  📋") or line:match("^  📊") or line:match("^  🤖") then
      hl = "Function"
    end
    table.insert(virt_lines, { { line, hl } })
  end

  table.insert(virt_lines, { { "", "Normal" } })

  if not vim.api.nvim_buf_is_valid(parent_chat.bufnr) then return end

  pcall(vim.api.nvim_buf_clear_namespace, parent_chat.bufnr, ns_id, 0, -1)

  local buf_lines = vim.api.nvim_buf_line_count(parent_chat.bufnr)
  local target_line = math.max(0, buf_lines - 1)

  pcall(vim.api.nvim_buf_set_extmark, parent_chat.bufnr, ns_id, target_line, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
    virt_lines_leftcol = true,
    priority = 100,
    right_gravity = false,
    end_right_gravity = false,
  })
end

---Start animation timer for batch status
---@param batch TaskBatchState
local function start_batch_timer(batch)
  batch.timer = vim.uv.new_timer()
  batch.spinner_index = 1

  batch.timer:start(
    0,
    UPDATE_INTERVAL_MS,
    vim.schedule_wrap(function()
      if not batch.timer then return end

      batch.spinner_index = (batch.spinner_index % #SPINNER_FRAMES) + 1
      local spinner_char = SPINNER_FRAMES[batch.spinner_index]

      local status_text = build_batch_status(batch, spinner_char)
      render_batch_status(batch, status_text)
    end)
  )
end

---Stop and cleanup batch timer
---@param batch TaskBatchState
local function stop_batch_timer(batch)
  if batch.timer and not batch.timer:is_closing() then
    batch.timer:stop()
    batch.timer:close()
  end
  batch.timer = nil
end

---Clear status notification from parent chat
---@param parent_chat table
local function clear_batch_status(parent_chat)
  if not parent_chat or not parent_chat.bufnr or not vim.api.nvim_buf_is_valid(parent_chat.bufnr) then return end

  local ns_id = get_status_namespace(parent_chat.bufnr)

  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(parent_chat.bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, parent_chat.bufnr, ns_id, 0, -1)
    end
  end)
end

---Extract result from completed child chat
---@param child_chat table
---@param child_bufnr number
---@return string
local function extract_child_result(child_chat, child_bufnr)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local config = require("codecompanion.config")

  local final_text = ""
  if child_chat and child_chat.messages then
    for i = #child_chat.messages, 1, -1 do
      local msg = child_chat.messages[i]
      if msg.role == config.constants.LLM_ROLE and msg.content and msg.content ~= "" then
        final_text = msg.content
        break
      end
    end
  end

  local tool_list = hierarchy.get_tool_execution_list(child_bufnr)
  local tool_count = #tool_list
  local tool_summary = ""
  if tool_count > 0 then
    local tool_lines = { "Tools executed:" }
    for _, tool in ipairs(tool_list) do
      local status_icon = tool.status == "completed" and "✓" or "✗"
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

  return table.concat(result_parts, "\n\n")
end

---Handle completion of a single task in the batch
---@param batch TaskBatchState
---@param child_bufnr number
---@param task_index number
---@param status string "success" or "error"
---@param data string Result or error message
local function on_task_complete(batch, child_bufnr, task_index, status, data)
  local task_def = batch.tasks[task_index]

  batch.results[task_index] = {
    status = status,
    data = data,
    agent = task_def.subagent_type,
    description = task_def.description,
  }

  batch.pending = batch.pending - 1

  log:debug("[Task] Task %d completed: %s (%d pending)", task_index, status, batch.pending)

  if batch.pending <= 0 then
    stop_batch_timer(batch)

    vim.defer_fn(function()
      clear_batch_status(batch.parent_chat)
    end, 500)

    local hierarchy = require("codecompanion-extra.agents.hierarchy")
    local total_elapsed = math.floor((vim.uv.hrtime() - batch.start_time) / 1000000)
    local total_duration = hierarchy.format_duration(total_elapsed)

    local success_count = 0
    local error_count = 0
    local result_parts = {}

    for i, result in ipairs(batch.results) do
      if result.status == "success" then
        success_count = success_count + 1
      else
        error_count = error_count + 1
      end

      table.insert(
        result_parts,
        fmt(
          [[<subagent_result agent="%s" task="%s" status="%s">
%s
</subagent_result>]],
          result.agent,
          result.description,
          result.status,
          result.data
        )
      )
    end

    local consolidated_result = table.concat(result_parts, "\n\n")
    consolidated_result = consolidated_result
      .. fmt(
        "\n\n(Batch completed: %d succeeded, %d failed, total time: %s)",
        success_count,
        error_count,
        total_duration
      )

    active_batches[batch.parent_chat.bufnr] = nil

    batch.callback({
      status = error_count > 0 and "error" or "success",
      data = consolidated_result,
    })
  end
end

---Setup event listeners for a child in the batch
---@param batch TaskBatchState
---@param child_bufnr number
---@param child_chat table
---@param task_index number
local function setup_child_listeners(batch, child_bufnr, child_chat, task_index)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local task_def = batch.tasks[task_index]

  local tool_call_counter = 0
  local completed = false
  local aug = vim.api.nvim_create_augroup("codecompanion_task_child_" .. child_bufnr, { clear = true })

  local function cleanup_and_complete(status, data)
    if completed then return end
    completed = true
    pcall(vim.api.nvim_del_augroup_by_id, aug)
    on_task_complete(batch, child_bufnr, task_index, status, data)
  end

  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionToolStarted",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        tool_call_counter = tool_call_counter + 1
        local tool_id = fmt("tool_%d", tool_call_counter)
        local tool_name = event.data.tool or "unknown"
        hierarchy.tool_started(child_bufnr, tool_id, tool_name)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionToolFinished",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        local tool_id = fmt("tool_%d", tool_call_counter)
        local tool_name = event.data.name or "unknown"
        hierarchy.tool_finished(child_bufnr, tool_id, true, tool_name)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionChatDone",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        hierarchy.set_status(child_bufnr, "completed")

        local result = extract_child_result(child_chat, child_bufnr)
        hierarchy.set_status(child_bufnr, "completed", result)

        cleanup_and_complete("success", result)
        return true
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionChatStopped",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        hierarchy.set_status(child_bufnr, "failed")

        cleanup_and_complete("error", fmt("Subagent '%s' was stopped before completion", task_def.subagent_type))
        return true
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionChatClosed",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        local current_session = hierarchy.get_session(child_bufnr)
        if current_session and current_session.status == "running" then
          hierarchy.set_status(child_bufnr, "cancelled")

          cleanup_and_complete("error", fmt("Subagent '%s' was closed unexpectedly", task_def.subagent_type))
        end
        return true
      end
    end,
  })
end

---Spawn a single subagent for the batch
---@param batch TaskBatchState
---@param task_def table Task definition
---@param task_index number
---@return number|nil child_bufnr
local function spawn_single_subagent(batch, task_def, task_index)
  local agents = require("codecompanion-extra.agents")
  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local registry = require("codecompanion-extra.agents.registry")
  local extra_config = require("codecompanion-extra.config")

  local agent_name = task_def.subagent_type
  local agent = registry.get(agent_name)

  if not agent then
    log:error("[Task] Unknown subagent: %s", agent_name)
    on_task_complete(batch, -1, task_index, "error", fmt("Unknown subagent: %s", agent_name))
    return nil
  end

  if agent.type ~= "subagent" then
    log:error("[Task] %s is not a subagent", agent_name)
    on_task_complete(batch, -1, task_index, "error", fmt("'%s' is not a subagent", agent_name))
    return nil
  end

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then
    on_task_complete(batch, -1, task_index, "error", "Failed to load codecompanion config")
    return nil
  end

  local codecompanion = require("codecompanion")
  local parent_window_opts = batch.parent_chat.ui and batch.parent_chat.ui.window_opts

  -- Determine adapter and model for subagent
  -- Priority: vim.g.codecompanion_small_model > config.agents.small_model > parent chat inheritance
  local chat_opts = {
    auto_submit = false,
    window_opts = parent_window_opts,
  }

  local small_model = extra_config.get_small_model()
  if small_model then
    -- Use configured small_model (from vim.g or config)
    chat_opts.params = {
      adapter = small_model.adapter,
      model = small_model.model,
    }
    log:debug("[Task] Using small_model: adapter=%s, model=%s", small_model.adapter, small_model.model)
  else
    -- Inherit from parent chat
    -- NOTE: CodeCompanion.chat() ignores args.adapter - it only looks at args.params
    -- So we must extract adapter name and model from parent and pass via params
    local parent_adapter = batch.parent_chat.adapter
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
    on_task_complete(batch, -1, task_index, "error", "Failed to create subagent chat")
    return nil
  end

  local child_bufnr = child_chat.bufnr
  batch.child_chats[child_bufnr] = child_chat

  vim.schedule(function()
    safe_hide_child_ui(child_chat)

    if batch.parent_chat and batch.parent_chat.ui then
      batch.parent_chat.ui:open({ window_opts = parent_window_opts or { default = true } })
    end
  end)

  hierarchy.create_session({
    bufnr = child_bufnr,
    parent_bufnr = batch.parent_chat.bufnr,
    agent_name = agent_name,
    agent_type = "subagent",
    description = task_def.description,
    hidden = true,
  })

  local activate_ok = agents.activate(agent_name, child_chat, { silent = true })
  if not activate_ok then
    on_task_complete(batch, child_bufnr, task_index, "error", fmt("Failed to activate subagent '%s'", agent_name))
    return nil
  end

  child_chat:add_message({
    role = cc_config.constants.USER_ROLE,
    content = task_def.prompt,
  }, { visible = true })

  setup_child_listeners(batch, child_bufnr, child_chat, task_index)

  hierarchy.start_timer(child_bufnr)

  child_chat:submit()

  return child_bufnr
end

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

  log:debug("[Task] Starting execution with %d task(s)", #tasks)

  ---@type TaskBatchState
  local batch = {
    tasks = tasks,
    results = {},
    pending = #tasks,
    timer = nil,
    spinner_index = 1,
    parent_chat = parent_chat,
    child_bufnrs = {},
    child_chats = {},
    callback = callback,
    start_time = vim.uv.hrtime(),
  }

  active_batches[parent_chat.bufnr] = batch

  start_batch_timer(batch)

  for i, task_def in ipairs(tasks) do
    local child_bufnr = spawn_single_subagent(batch, task_def, i)
    if child_bufnr then
      batch.child_bufnrs[i] = child_bufnr
    else
      batch.child_bufnrs[i] = -1
    end
  end
end

---@class CodeCompanion.Tool.Task: CodeCompanion.Tools.Tool
return {
  name = "task",
  cmds = {
    ---Execute the task tool (async pattern - does not return immediately)
    ---@param tools CodeCompanion.Tools The tools coordinator object
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
                  description = "Short (3-5 word) task description for display",
                },
                prompt = {
                  type = "string",
                  description = "Detailed instructions for the subagent",
                },
              },
              required = { "subagent_type", "description", "prompt" },
            },
          },
        },
        required = { "tasks" },
        additionalProperties = false,
      },
    },
  },
  system_prompt = [[You have access to the task tool for delegating work to specialized subagents.

USAGE:
- Single task: { "tasks": [{ one task }] }
- Parallel tasks: { "tasks": [{ task1 }, { task2 }, ...] } - all run simultaneously

PREFER PARALLEL EXECUTION: When you have 2+ independent tasks, include them all in one task call to run simultaneously. This is much faster than sequential calls.

After receiving subagent results, synthesize the information and continue with your task.
The user can press ]s to navigate to subagent output for details.]],

  opts = {
    require_approval_before = false,
  },

  handlers = {
    setup = function(self, tools)
      log:debug("[Task] Setup: %d task(s)", self.args.tasks and #self.args.tasks or 0)
    end,

    on_exit = function(tools)
      log:trace("[Task] on_exit handler executed")
    end,
  },

  output = {
    cmd_string = function(self, args)
      local count = self.args.tasks and #self.args.tasks or 0
      if count == 1 then
        local task = self.args.tasks[1]
        return fmt("%s: %s", capitalize_agent(task.subagent_type), task.description)
      end
      return fmt("SubAgents: %d parallel", count)
    end,

    prompt = function(self, tools)
      local count = self.args.tasks and #self.args.tasks or 0
      local descriptions = {}
      for i, task in ipairs(self.args.tasks or {}) do
        if i <= 3 then
          table.insert(descriptions, fmt("- %s: %s", capitalize_agent(task.subagent_type), task.description))
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
        local tool_info = tools_match and fmt("  🔧 Tools: %s", tools_match) or nil
        user_lines = {
          fmt("───── %s Complete ─────", capitalize_agent(task.subagent_type)),
          fmt("  📋 Task: %s", task.description),
        }
        if tool_info then table.insert(user_lines, tool_info) end
        if duration_match then table.insert(user_lines, fmt("  ⏱  Duration: %s", duration_match)) end
        table.insert(
          user_lines,
          "─────────────────────────────────"
        )
      else
        user_lines = {
          fmt("═══════ SubAgents Complete (%d) ═══════", task_count),
        }
        for _, task in ipairs(self.args.tasks or {}) do
          local icon = ({
            explorer = "🔍",
            general = "📋",
            analyzer = "📊",
          })[task.subagent_type] or "🤖"
          table.insert(user_lines, fmt("  %s %s: %s", icon, capitalize_agent(task.subagent_type), task.description))
        end
        if success_match then table.insert(user_lines, fmt("  ✓ Succeeded: %s", success_match)) end
        if failed_match and failed_match ~= "0" then table.insert(user_lines, fmt("  ✗ Failed: %s", failed_match)) end
        if duration_match then table.insert(user_lines, fmt("  ⏱ Duration: %s", duration_match)) end
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

      local task_count = self.args.tasks and #self.args.tasks or 0

      local error_output
      if task_count == 1 then
        error_output = fmt(
          [[<subagent_error agent="%s" task="%s">
%s
</subagent_error>

The subagent encountered an error. You may need to try a different approach or ask the user for guidance.]],
          self.args.tasks[1].subagent_type,
          self.args.tasks[1].description,
          errors
        )
      else
        error_output = fmt(
          [[<subagents_error count="%d">
%s
</subagents_error>

Some or all subagents failed. Review the errors and adjust your approach.]],
          task_count,
          errors
        )
      end

      local user_lines
      if task_count == 1 then
        user_lines = {
          fmt("───── %s Failed ─────", capitalize_agent(self.args.tasks[1].subagent_type)),
          fmt("  📋 Task: %s", self.args.tasks[1].description),
          fmt("  ✗ Error: %s", errors:sub(1, 100)),
          "─────────────────────────────────",
        }
      else
        user_lines = {
          fmt("═══════ SubAgents Failed (%d) ═══════", task_count),
          "  ✗ Error occurred during execution",
          "═══════════════════════════════════════",
        }
      end

      local user_output = table.concat(user_lines, "\n")

      chat:add_tool_output(self, error_output, user_output)
    end,

    rejected = function(self, tools)
      local chat = tools.chat
      local count = self.args.tasks and #self.args.tasks or 0
      if count == 1 then
        chat:add_tool_output(
          self,
          fmt("User rejected spawning %s subagent", capitalize_agent(self.args.tasks[1].subagent_type))
        )
      else
        chat:add_tool_output(self, fmt("User rejected running %d subagents", count))
      end
    end,

    cancelled = function(self, tools)
      local chat = tools.chat
      local count = self.args.tasks and #self.args.tasks or 0

      local parent_bufnr = chat.bufnr
      local batch = active_batches[parent_bufnr]
      if batch then
        stop_batch_timer(batch)
        clear_batch_status(chat)
        active_batches[parent_bufnr] = nil
      end

      if count == 1 then
        chat:add_tool_output(self, fmt("%s subagent was cancelled", capitalize_agent(self.args.tasks[1].subagent_type)))
      else
        chat:add_tool_output(self, fmt("%d subagents were cancelled", count))
      end
    end,
  },
}
