-- Task tool for spawning subagents
-- Implements async pattern: parent waits for child completion
-- Provides real-time status updates via virtual line notifications with animated spinner

local log = require("codecompanion.utils.log")

local fmt = string.format

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local UPDATE_INTERVAL_MS = 100

---@class TaskStatusState
---@field timer userdata|nil
---@field spinner_index number
---@field parent_chat table
---@field child_bufnr number

---@type table<number, TaskStatusState>
local active_status_timers = {}

---Get or create namespace for subagent status notifications
---@param parent_bufnr number
---@return number
local function get_status_namespace(parent_bufnr)
  return vim.api.nvim_create_namespace("codecompanion_subagent_" .. tostring(parent_bufnr))
end

---Build animated status text with spinner
---@param bufnr number Child buffer number
---@param spinner_char string Current spinner frame
---@return string
local function build_animated_status(bufnr, spinner_char)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local session = hierarchy.get_session(bufnr)
  if not session then return "" end

  local icon = ({
    explorer = "🔍",
    general = "📋",
    analyzer = "📊",
  })[session.agent_name] or "🤖"

  local summary = hierarchy.get_tool_summary(bufnr)
  local elapsed = hierarchy.format_duration(hierarchy.get_elapsed_ms(bufnr))

  local parts = { fmt("%s **%s**: %s", icon, session.agent_name, session.description) }

  if session.status == "running" then
    if summary.current then
      table.insert(parts, fmt("  %s Running: `%s`", spinner_char, summary.current))
    else
      table.insert(parts, fmt("  %s Working...", spinner_char))
    end
    if summary.total > 0 then table.insert(parts, fmt("  Tools: %d completed", summary.completed)) end
    table.insert(parts, fmt("  ⏱ %s", elapsed))
  elseif session.status == "completed" then
    table.insert(parts, fmt("  ✓ Completed (%d tools, %s)", summary.total, elapsed))
  elseif session.status == "failed" then
    table.insert(parts, fmt("  ✗ Failed after %s", elapsed))
  elseif session.status == "cancelled" then
    table.insert(parts, "  ⊘ Cancelled")
  else
    table.insert(parts, fmt("  %s Pending...", spinner_char))
  end

  return table.concat(parts, "\n")
end

---Render status notification in parent chat buffer using virtual lines
---@param parent_chat table
---@param child_bufnr number
---@param status_text string
local function render_status_extmark(parent_chat, child_bufnr, status_text)
  if not parent_chat or not parent_chat.bufnr or not vim.api.nvim_buf_is_valid(parent_chat.bufnr) then return end

  local ns_id = get_status_namespace(parent_chat.bufnr)
  local lines = vim.split(status_text, "\n")

  local virt_lines = {}
  table.insert(virt_lines, { { "", "Normal" } })
  table.insert(
    virt_lines,
    { { "───────────────────────────────", "Comment" } }
  )

  for _, line in ipairs(lines) do
    local hl = "Comment"
    if line:match("Running") or line:match("Working") then
      hl = "WarningMsg"
    elseif line:match("Completed") then
      hl = "DiagnosticOk"
    elseif line:match("Failed") or line:match("Cancelled") then
      hl = "ErrorMsg"
    elseif line:match("^🔍") or line:match("^📋") or line:match("^📊") or line:match("^🤖") then
      hl = "Title"
    elseif line:match("⏱") then
      hl = "DiagnosticInfo"
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
    priority = 100,
  })
end

---Start animated status timer
---@param parent_chat table
---@param child_bufnr number
local function start_status_timer(parent_chat, child_bufnr)
  local state = {
    timer = vim.uv.new_timer(),
    spinner_index = 1,
    parent_chat = parent_chat,
    child_bufnr = child_bufnr,
  }

  active_status_timers[child_bufnr] = state

  state.timer:start(
    0,
    UPDATE_INTERVAL_MS,
    vim.schedule_wrap(function()
      local current_state = active_status_timers[child_bufnr]
      if not current_state or not current_state.timer then return end

      current_state.spinner_index = (current_state.spinner_index % #SPINNER_FRAMES) + 1
      local spinner_char = SPINNER_FRAMES[current_state.spinner_index]

      local status_text = build_animated_status(child_bufnr, spinner_char)
      render_status_extmark(parent_chat, child_bufnr, status_text)
    end)
  )
end

---Stop and cleanup status timer
---@param child_bufnr number
local function stop_status_timer(child_bufnr)
  local state = active_status_timers[child_bufnr]
  if not state then return end

  if state.timer and not state.timer:is_closing() then
    state.timer:stop()
    state.timer:close()
  end

  active_status_timers[child_bufnr] = nil
end

---Clear status notification from parent chat
---@param parent_chat table
local function clear_status_notification(parent_chat)
  if not parent_chat or not parent_chat.bufnr or not vim.api.nvim_buf_is_valid(parent_chat.bufnr) then return end

  local ns_id = get_status_namespace(parent_chat.bufnr)

  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(parent_chat.bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, parent_chat.bufnr, ns_id, 0, -1)
    end
  end)
end

---Extract final result from child chat
---@param child_chat table
---@param child_bufnr number
---@return string
local function extract_child_result(child_chat, child_bufnr)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")

  local final_text = ""
  local config = require("codecompanion.config")

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
  local tool_summary = ""
  if #tool_list > 0 then
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
  table.insert(result_parts, fmt("(Completed in %s)", duration_str))

  return table.concat(result_parts, "\n\n")
end

---Setup event listeners for child chat
---@param args { child_bufnr: number, child_chat: table, parent_chat: table, session: table, callback: function }
local function setup_child_listeners(args)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local child_bufnr = args.child_bufnr
  local parent_chat = args.parent_chat
  local session = args.session
  local callback = args.callback

  local tool_call_counter = 0

  local aug = vim.api.nvim_create_augroup("codecompanion_subagent_" .. child_bufnr, { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionToolStarted",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        tool_call_counter = tool_call_counter + 1
        local tool_id = fmt("tool_%d", tool_call_counter)
        local tool_name = event.data.tool or "unknown"

        log:debug("[Task Tool] Child tool started: %s (bufnr=%d)", tool_name, child_bufnr)
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

        log:debug("[Task Tool] Child tool finished: %s (bufnr=%d)", tool_name, child_bufnr)
        hierarchy.tool_finished(child_bufnr, tool_id, true, tool_name)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionChatDone",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        log:debug("[Task Tool] Child chat done: bufnr=%d", child_bufnr)

        hierarchy.set_status(child_bufnr, "completed")

        stop_status_timer(child_bufnr)

        vim.defer_fn(function()
          clear_status_notification(parent_chat)
        end, 500)

        local child_chat = require("codecompanion").buf_get_chat(child_bufnr)
        local result = extract_child_result(child_chat, child_bufnr)
        hierarchy.set_status(child_bufnr, "completed", result)

        pcall(vim.api.nvim_del_augroup_by_id, aug)

        if callback then callback({
          status = "success",
          data = result,
        }) end

        return true
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionChatStopped",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        log:debug("[Task Tool] Child chat stopped: bufnr=%d", child_bufnr)

        hierarchy.set_status(child_bufnr, "failed")

        stop_status_timer(child_bufnr)

        vim.defer_fn(function()
          clear_status_notification(parent_chat)
        end, 2000)

        pcall(vim.api.nvim_del_augroup_by_id, aug)

        if callback then
          callback({
            status = "error",
            data = fmt("Subagent '%s' was stopped before completion", session.agent_name),
          })
        end

        return true
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionChatClosed",
    callback = function(event)
      if event.data and event.data.bufnr == child_bufnr then
        log:debug("[Task Tool] Child chat closed: bufnr=%d", child_bufnr)

        local current_session = hierarchy.get_session(child_bufnr)
        if current_session and current_session.status == "running" then
          hierarchy.set_status(child_bufnr, "cancelled")

          stop_status_timer(child_bufnr)
          clear_status_notification(parent_chat)

          pcall(vim.api.nvim_del_augroup_by_id, aug)

          if callback then
            callback({
              status = "error",
              data = fmt("Subagent '%s' was closed by user", session.agent_name),
            })
          end
        end

        return true
      end
    end,
  })
end

---Spawn a subagent in a hidden chat buffer (async)
---Uses agents.activate() for proper tool registration
---@param args { subagent_type: string, description: string, prompt: string }
---@param parent_chat table
---@param callback function Called when child completes
local function spawn_subagent_async(args, parent_chat, callback)
  local agents = require("codecompanion-extra.agents")
  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local registry = require("codecompanion-extra.agents.registry")

  local agent_name = args.subagent_type
  local description = args.description
  local prompt = args.prompt

  log:debug("[Task Tool] Spawning subagent: %s - %s", agent_name, description)

  local agent = registry.get(agent_name)
  if not agent then
    log:debug("[Task Tool] Unknown subagent: %s", agent_name)
    callback({
      status = "error",
      data = fmt("Unknown subagent: %s. Available: explorer, general, analyzer", agent_name),
    })
    return
  end

  if agent.type ~= "subagent" then
    log:debug("[Task Tool] %s is not a subagent", agent_name)
    callback({
      status = "error",
      data = fmt("'%s' is not a subagent, it's a primary agent", agent_name),
    })
    return
  end

  local parent_agent_name = agents.active(parent_chat.bufnr)
  if parent_agent_name then
    local parent_agent = agents.get(parent_agent_name)
    if parent_agent and not parent_agent.permissions.can_spawn_subagents then
      log:debug("[Task Tool] Parent agent %s cannot spawn subagents", parent_agent_name)
      callback({
        status = "error",
        data = fmt("Agent '%s' does not have permission to spawn subagents", parent_agent_name),
      })
      return
    end
  end

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then
    log:error("[Task Tool] Failed to load codecompanion config")
    callback({
      status = "error",
      data = "Failed to load codecompanion config",
    })
    return
  end

  local codecompanion = require("codecompanion")
  local parent_window_opts = parent_chat.ui and parent_chat.ui.window_opts

  local child_chat = codecompanion.chat({
    adapter = parent_chat.adapter,
    auto_submit = false,
    window_opts = parent_window_opts,
  })

  if not child_chat then
    log:error("[Task Tool] Failed to create child chat")
    callback({
      status = "error",
      data = "Failed to create subagent chat",
    })
    return
  end

  local child_bufnr = child_chat.bufnr
  log:debug("[Task Tool] Child chat created: bufnr=%d", child_bufnr)

  vim.schedule(function()
    if child_chat.ui then child_chat.ui:hide() end

    if parent_chat and parent_chat.ui then
      parent_chat.ui:open({ window_opts = parent_window_opts or { default = true } })
    end
  end)

  local session = hierarchy.create_session({
    bufnr = child_bufnr,
    parent_bufnr = parent_chat.bufnr,
    agent_name = agent_name,
    agent_type = "subagent",
    description = description,
    hidden = true,
  })

  local activate_ok = agents.activate(agent_name, child_chat, { silent = true })
  if not activate_ok then
    log:error("[Task Tool] Failed to activate agent %s on child chat", agent_name)
    callback({
      status = "error",
      data = fmt("Failed to activate subagent '%s'", agent_name),
    })
    return
  end

  child_chat:add_message({
    role = cc_config.constants.USER_ROLE,
    content = prompt,
  }, { visible = true })

  setup_child_listeners({
    child_bufnr = child_bufnr,
    child_chat = child_chat,
    parent_chat = parent_chat,
    session = session,
    callback = callback,
  })

  hierarchy.set_pending_callback(child_bufnr, callback)
  hierarchy.start_timer(child_bufnr)

  start_status_timer(parent_chat, child_bufnr)

  local tools_in_use = vim.tbl_keys(child_chat.tool_registry.in_use)
  local schema_count = vim.tbl_count(child_chat.tool_registry.schemas)
  log:debug(
    "[Task Tool] Submitting child chat: bufnr=%d, tools=%s, schemas=%d",
    child_bufnr,
    vim.inspect(tools_in_use),
    schema_count
  )

  if vim.tbl_isempty(child_chat.tool_registry.schemas) then
    log:error("[Task Tool] No tool schemas registered - tools will not be available to subagent!")
  end

  child_chat:submit()
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
        log:error("[Task Tool] No chat context available")
        return {
          status = "error",
          data = "No chat context available",
        }
      end

      log:debug("[Task Tool] cmds called with args: %s", vim.inspect(args))

      spawn_subagent_async(args, tools.chat, output_handler)

      return nil
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "task",
      description = [[Delegate a task to a specialized subagent. The subagent runs in its own context with focused tools and returns results when complete.

Use subagents for:
- Exploring/researching code (explorer): Fast codebase exploration with read-only tools
- Running analyses (analyzer): Code analysis, diagnostics, and finding issues
- General research tasks (general): Multi-step research that may need command execution

The parent waits for the subagent to complete and receives the full results.
The user can navigate to the subagent's chat with ]s to see detailed output.]],
      parameters = {
        type = "object",
        properties = {
          subagent_type = {
            type = "string",
            description = "Which subagent to use: 'explorer' for codebase exploration, 'general' for research tasks, or 'analyzer' for code analysis",
            enum = { "explorer", "general", "analyzer" },
          },
          description = {
            type = "string",
            description = "Short (3-5 word) description of the task for display purposes",
          },
          prompt = {
            type = "string",
            description = "Detailed instructions for the subagent explaining what to do",
          },
        },
        required = { "subagent_type", "description", "prompt" },
        additionalProperties = false,
      },
    },
  },
  system_prompt = [[You have access to the task tool for delegating work to specialized subagents.

Available subagents:
- explorer: Fast codebase exploration (read-only). Use for finding files, searching code, understanding structure.
- general: General research and multi-step tasks. Can run commands for information gathering.
- analyzer: Code analysis and diagnostics. Use for finding issues, checking errors, analyzing patterns.

When to use subagents:
- Complex exploration that needs focused context
- Parallel research tasks (spawn multiple subagents)
- Isolated analysis that shouldn't clutter main conversation
- Tasks that benefit from specialized tool sets

The subagent runs to completion and returns its findings. You will receive:
- The subagent's final response with its analysis/findings
- A summary of tools it executed
- Duration of the task

After receiving subagent results, synthesize the information and continue with your task.
The user can press ]s to navigate to subagent output for details.]],

  opts = {
    require_approval_before = false,
  },

  handlers = {
    ---Setup handler called before execution
    ---@param self CodeCompanion.Tool.Task
    ---@param tools CodeCompanion.Tools
    setup = function(self, tools)
      log:debug("[Task Tool] Setup: subagent_type=%s, description=%s", self.args.subagent_type, self.args.description)
    end,

    ---On exit handler called after execution
    ---@param tools CodeCompanion.Tools
    on_exit = function(tools)
      log:trace("[Task Tool] on_exit handler executed")
    end,
  },

  output = {
    ---Returns the command string for display
    ---@param self CodeCompanion.Tool.Task
    ---@param args { tools: CodeCompanion.Tools }
    ---@return string
    cmd_string = function(self, args)
      return fmt("task %s: %s", self.args.subagent_type, self.args.description)
    end,

    ---Prompt the user to approve the execution
    ---@param self CodeCompanion.Tool.Task
    ---@param tools CodeCompanion.Tools
    ---@return string
    prompt = function(self, tools)
      return fmt("Spawn %s subagent: %s?", self.args.subagent_type, self.args.description)
    end,

    ---Handle successful execution
    ---@param self CodeCompanion.Tool.Task
    ---@param tools CodeCompanion.Tools
    ---@param cmd table The command that was executed
    ---@param stdout table The output from the command
    success = function(self, tools, cmd, stdout)
      local chat = tools.chat
      local output = vim.iter(stdout):flatten():join("\n")

      local tool_count, duration_str = 0, ""
      local duration_match = output:match("%(Completed in ([^)]+)%)")
      if duration_match then duration_str = duration_match end
      local tools_match = output:match("Tools executed:%s*\n(.-)\n\n")
      if tools_match then
        for _ in tools_match:gmatch("[✓✗]") do
          tool_count = tool_count + 1
        end
      end

      local llm_output = fmt(
        [[<subagent_result agent="%s" task="%s">
%s
</subagent_result>

Use the subagent's findings above to continue with your task. Synthesize the information as needed.]],
        self.args.subagent_type,
        self.args.description,
        output
      )

      local user_lines = {
        fmt("───── %s Subagent Complete ─────", self.args.subagent_type:upper()),
        fmt("  📋 Task: %s", self.args.description),
      }
      if tool_count > 0 then table.insert(user_lines, fmt("  🔧 Tools used: %d", tool_count)) end
      if duration_str ~= "" then table.insert(user_lines, fmt("  ⏱  Duration: %s", duration_str)) end
      table.insert(
        user_lines,
        "─────────────────────────────────"
      )

      local user_output = table.concat(user_lines, "\n")

      chat:add_tool_output(self, llm_output, user_output)
    end,

    ---Handle error execution
    ---@param self CodeCompanion.Tool.Task
    ---@param tools CodeCompanion.Tools
    ---@param cmd table
    ---@param stderr table The error output
    error = function(self, tools, cmd, stderr)
      local chat = tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      log:debug("[Task Tool] Error: %s", errors)

      local error_output = fmt(
        [[<subagent_error agent="%s" task="%s">
%s
</subagent_error>

The subagent encountered an error. You may need to try a different approach or ask the user for guidance.]],
        self.args.subagent_type,
        self.args.description,
        errors
      )

      local user_lines = {
        fmt("───── %s Subagent Failed ─────", self.args.subagent_type:upper()),
        fmt("  📋 Task: %s", self.args.description),
        fmt("  ✗ Error: %s", errors:sub(1, 100)),
        "─────────────────────────────────",
      }
      local user_output = table.concat(user_lines, "\n")

      chat:add_tool_output(self, error_output, user_output)
    end,

    ---Handle rejection
    ---@param self CodeCompanion.Tool.Task
    ---@param tools CodeCompanion.Tools
    rejected = function(self, tools)
      local chat = tools.chat
      chat:add_tool_output(self, fmt("User rejected spawning %s subagent", self.args.subagent_type))
    end,

    ---Handle cancellation
    ---@param self CodeCompanion.Tool.Task
    ---@param tools CodeCompanion.Tools
    cancelled = function(self, tools)
      local chat = tools.chat
      chat:add_tool_output(self, fmt("Subagent %s was cancelled", self.args.subagent_type))
    end,
  },
}
