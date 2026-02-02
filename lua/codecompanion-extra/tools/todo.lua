local log = require("codecompanion.utils.log")

local api = vim.api
local fmt = string.format
-- stylua: ignore start 
local ICONS = {
  pending         = "",
  in_progress     = "",
  completed       = "",
  cancelled       = "󰅖",
  high_priority   = "Ⓗ",
  medium_priority = "Ⓜ",
  low_priority    = "Ⓛ",
  todo            = "",
  progress        = "󰦖",
  timer           = "󰁫",
}

local HIGHLIGHTS = {
  header      = "Title",
  pending     = "Comment",
  in_progress = "WarningMsg",
  completed   = "DiagnosticOk",
  cancelled   = "DiagnosticHint",
  high        = "DiagnosticError",
  medium      = "DiagnosticWarn",
  low         = "DiagnosticInfo",
  separator   = "Comment",
}
-- stylua: ignore end

---@class CodeCompanionExtra.TodoItem
---@field id string Unique identifier for the todo
---@field content string Brief description of the task (5-7 words)
---@field status "pending" | "in_progress" | "completed" | "cancelled"
---@field priority "high" | "medium" | "low"

---@type table<number, CodeCompanionExtra.TodoItem[]>
local _todo_store = {}

---@type number
local _id_counter = 0
---Generate a unique todo ID
---@return string
local function generate_id()
  _id_counter = _id_counter + 1
  return fmt("todo_%d_%d", os.time(), _id_counter)
end

---Get todos for a chat buffer
---@param bufnr number
---@return CodeCompanionExtra.TodoItem[]
local function get_todos(bufnr)
  return _todo_store[bufnr] or {}
end

---Set todos for a chat buffer
---@param bufnr number
---@param todos CodeCompanionExtra.TodoItem[]
local function set_todos(bufnr, todos)
  _todo_store[bufnr] = todos
end

---Check if the current agent is allowed to write todos
---@param chat table
---@return boolean
local function can_write_todos(chat)
  if not chat or not chat.bufnr then return false end

  local ok, agents = pcall(require, "codecompanion-extra.agents")
  if not ok then return false end

  local active_agent = agents.active(chat.bufnr)
  if not active_agent then return true end

  -- TODO:make it configurable but for now, I'm gonna leave it like this
  return active_agent == "build"
end

---Get status icon
---@param status string
---@return string
local function get_status_icon(status)
  return ICONS[status] or "?"
end

---Get priority icon
---@param priority string
---@return string
local function get_priority_icon(priority)
  local icons = {
    high = ICONS.high_priority,
    medium = ICONS.medium_priority,
    low = ICONS.low_priority,
  }
  return icons[priority] or ""
end

---Format todos for LLM output
---@param todos CodeCompanionExtra.TodoItem[]
---@return string
local function format_todos_for_llm(todos)
  if #todos == 0 then return "No todos found." end

  local lines = {}
  for _, todo in ipairs(todos) do
    local status_icon = get_status_icon(todo.status)
    local priority_mark = todo.priority == "high" and "!" or ""
    table.insert(lines, fmt("%s [%s] %s%s", status_icon, todo.id, priority_mark, todo.content))
  end

  return table.concat(lines, "\n")
end

---Build title from todos state
---@param todos CodeCompanionExtra.TodoItem[]
---@return string
local function build_title(todos)
  local remaining = 0
  for _, todo in ipairs(todos) do
    if todo.status ~= "completed" and todo.status ~= "cancelled" then remaining = remaining + 1 end
  end
  return fmt("%d todo%s", remaining, remaining == 1 and "" or "s")
end

---Count todos by status
---@param todos CodeCompanionExtra.TodoItem[]
---@return { pending: number, in_progress: number, completed: number, cancelled: number, total: number }
local function count_todos(todos)
  local counts = { pending = 0, in_progress = 0, completed = 0, cancelled = 0, total = #todos }
  for _, todo in ipairs(todos) do
    counts[todo.status] = (counts[todo.status] or 0) + 1
  end
  return counts
end

---Build user-facing output for todo read
---@param todos CodeCompanionExtra.TodoItem[]
---@return string
local function build_user_output_read(todos)
  if #todos == 0 then return fmt("%s No tasks in the list", ICONS.todo) end

  local counts = count_todos(todos)
  local lines = {}

  table.insert(lines, fmt("───── %s Task List ─────", ICONS.todo))

  local progress_parts = {}
  if counts.completed > 0 then table.insert(progress_parts, fmt("%s %d done", ICONS.completed, counts.completed)) end
  if counts.in_progress > 0 then
    table.insert(progress_parts, fmt("%s %d active", ICONS.in_progress, counts.in_progress))
  end
  if counts.pending > 0 then table.insert(progress_parts, fmt("%s %d pending", ICONS.pending, counts.pending)) end
  if counts.cancelled > 0 then
    table.insert(progress_parts, fmt("%s %d cancelled", ICONS.cancelled, counts.cancelled))
  end

  table.insert(lines, fmt("  %s Progress: %s", ICONS.progress, table.concat(progress_parts, " │ ")))
  table.insert(lines, "")

  -- Current task (in_progress)
  for _, todo in ipairs(todos) do
    if todo.status == "in_progress" then
      local priority_icon = get_priority_icon(todo.priority)
      table.insert(lines, fmt("  ▶ NOW: %s %s", priority_icon, todo.content))
      break
    end
  end

  local pending = {}
  for _, todo in ipairs(todos) do
    if todo.status == "pending" then table.insert(pending, todo) end
  end
  if #pending > 0 then
    table.insert(lines, fmt("  ○ Next: %d task%s queued", #pending, #pending == 1 and "" or "s"))
  end

  table.insert(lines, "─────────────────────────────")

  return table.concat(lines, "\n")
end

---Build user-facing output for todo write
---@param todos CodeCompanionExtra.TodoItem[]
---@param action string "created" | "updated"
---@return string
local function build_user_output_write(todos, action)
  if #todos == 0 then return fmt("%s Task list cleared", ICONS.todo) end

  local counts = count_todos(todos)
  local lines = {}

  local header_text = action == "created" and "Task List Created" or "Task List Updated"
  table.insert(
    lines,
    fmt("════════════ %s %s ═════════════", ICONS.todo, header_text)
  )

  local in_progress = {}
  local pending = {}
  local completed = {}

  for _, todo in ipairs(todos) do
    if todo.status == "in_progress" then
      table.insert(in_progress, todo)
    elseif todo.status == "pending" then
      table.insert(pending, todo)
    elseif todo.status == "completed" then
      table.insert(completed, todo)
    end
  end

  if #in_progress > 0 then
    for _, todo in ipairs(in_progress) do
      local priority_icon = get_priority_icon(todo.priority)
      table.insert(lines, fmt("  %s %s %s", ICONS.in_progress, priority_icon, todo.content))
    end
  end

  if #pending > 0 then
    for _, todo in ipairs(pending) do
      local priority_icon = get_priority_icon(todo.priority)
      table.insert(lines, fmt("  %s %s %s", ICONS.pending, priority_icon, todo.content))
    end
  end

  if #completed > 0 then
    if #completed <= 2 then
      for _, todo in ipairs(completed) do
        table.insert(lines, fmt("  %s %s", ICONS.completed, todo.content))
      end
    else
      table.insert(lines, fmt("  %s %d tasks completed", ICONS.completed, #completed))
    end
  end

  table.insert(lines, "")
  local remaining = counts.pending + counts.in_progress
  if remaining > 0 then
    table.insert(lines, fmt("  %s %d of %d remaining", ICONS.progress, remaining, counts.total))
  else
    table.insert(lines, fmt("  %s All tasks complete!", ICONS.completed))
  end

  table.insert(
    lines,
    "═══════════════════════════════════"
  )

  return table.concat(lines, "\n")
end

---Validate todos array
---@param todos table[]
---@return boolean valid
---@return string? error_msg
local function validate_todos(todos)
  if type(todos) ~= "table" then return false, "todos must be an array" end

  local valid_statuses = { pending = true, in_progress = true, completed = true, cancelled = true }
  local valid_priorities = { high = true, medium = true, low = true }
  local in_progress_count = 0

  for i, todo in ipairs(todos) do
    if type(todo) ~= "table" then return false, fmt("todo[%d] must be an object", i) end

    if type(todo.content) ~= "string" or todo.content == "" then
      return false, fmt("todo[%d].content must be a non-empty string", i)
    end

    if not valid_statuses[todo.status] then
      return false, fmt("todo[%d].status must be one of: pending, in_progress, completed, cancelled", i)
    end

    if not valid_priorities[todo.priority] then
      return false, fmt("todo[%d].priority must be one of: high, medium, low", i)
    end

    if todo.status == "in_progress" then in_progress_count = in_progress_count + 1 end
  end

  -- TODO: I might reveist this when i introduce swarm
  if in_progress_count > 1 then
    log:warn("[Todo] Multiple todos marked as in_progress (%d). Best practice is one at a time.", in_progress_count)
  end

  return true, nil
end
---@class CodeCompanion.Tool.TodoWrite: CodeCompanion.Tools.Tool
local todowrite = {
  name = "todowrite",
  cmds = {
    ---Execute the todowrite tool
    ---@param tools CodeCompanion.Tools
    ---@param args table
    ---@return { status: string, data: any }
    function(tools, args)
      if not tools or not tools.chat then
        return {
          status = "error",
          data = "No chat context available",
        }
      end

      local chat = tools.chat

      if not can_write_todos(chat) then
        return {
          status = "error",
          data = "Permission denied: Only the build agent can write todos. Subagents cannot manage the task list.",
        }
      end

      local todos = args.todos
      if not todos then
        return {
          status = "error",
          data = "Missing required parameter: todos",
        }
      end

      local valid, err = validate_todos(todos)
      if not valid then return {
        status = "error",
        data = fmt("Invalid todos: %s", err),
      } end

      local existing = get_todos(chat.bufnr)
      local is_new = #existing == 0

      for _, todo in ipairs(todos) do
        if not todo.id or todo.id == "" then todo.id = generate_id() end
      end

      set_todos(chat.bufnr, todos)

      log:debug("[Todo] Updated todos for bufnr %d: %d items", chat.bufnr, #todos)

      return {
        status = "success",
        data = {
          message = fmt("Updated task list (%s):\n\n%s", build_title(todos), format_todos_for_llm(todos)),
          todos = todos,
          is_new = is_new,
        },
      }
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "todowrite",
      description = [[Create or update your task list to track progress on complex operations.

Use a task list when:
- The task requires multiple steps over time
- There are logical phases or dependencies
- You need to track what's done and what remains

Guidelines:
- Keep tasks SHORT: 5-7 words each, one sentence max
- Always have exactly ONE task "in_progress" at a time
- Mark tasks "completed" IMMEDIATELY after finishing (don't batch completions)
- Use priority to indicate importance (high for blockers, medium for normal, low for nice-to-have)
- You can add, remove, or reorder tasks dynamically as you learn more

Status values:
- "pending": Not yet started
- "in_progress": Currently working on this (only one at a time!)
- "completed": Finished
- "cancelled": No longer needed

Example workflow:
1. Create initial task list with all tasks "pending"
2. Mark first task "in_progress" and start working
3. When done, mark it "completed" and mark next task "in_progress"
4. Repeat until all tasks are done]],
      parameters = {
        type = "object",
        properties = {
          todos = {
            type = "array",
            description = "Complete task list (replaces previous list). Include all tasks, not just changes.",
            items = {
              type = "object",
              properties = {
                id = {
                  type = "string",
                  description = "Unique identifier. Reuse existing IDs when updating tasks, omit for new tasks.",
                },
                content = {
                  type = "string",
                  description = "Brief task description (5-7 words). Example: 'Add user authentication endpoint'",
                },
                status = {
                  type = "string",
                  enum = { "pending", "in_progress", "completed", "cancelled" },
                  description = "Current status. Only ONE task should be 'in_progress' at a time.",
                },
                priority = {
                  type = "string",
                  enum = { "high", "medium", "low" },
                  description = "Task priority. Use 'high' for blockers, 'medium' for normal work.",
                },
              },
              required = { "content", "status", "priority" },
              additionalProperties = false,
            },
          },
        },
        required = { "todos" },
        additionalProperties = false,
      },
    },
  },
  opts = {
    requires_approval = false,
    hide_from_agent = function(chat)
      -- TODO: again revisit this
      if not chat or not chat.bufnr then return true end
      local ok, agents = pcall(require, "codecompanion-extra.agents")
      if not ok then return false end
      local active = agents.active(chat.bufnr)
      return active ~= nil and active ~= "build"
    end,
  },
  handlers = {
    on_exit = function(tools)
      log:trace("[TodoWrite Tool] on_exit handler executed")
    end,
  },
  output = {
    ---@param self CodeCompanion.Tool.TodoWrite
    ---@return string
    cmd_string = function(self)
      local count = self.args.todos and #self.args.todos or 0
      return fmt("Update task list (%d items)", count)
    end,

    ---@param self CodeCompanion.Tool.TodoWrite
    ---@return string
    prompt = function(self)
      local count = self.args.todos and #self.args.todos or 0
      return fmt("Update task list with %d item%s?", count, count == 1 and "" or "s")
    end,

    ---@param self CodeCompanion.Tool.TodoWrite
    ---@param tools CodeCompanion.Tools
    ---@param cmd table
    ---@param stdout table
    success = function(self, tools, cmd, stdout)
      local chat = tools.chat
      local result = stdout[1]

      if type(result) ~= "table" or not result.todos then
        -- Fallback for unexpected format
        local output = vim.iter(stdout):flatten():join("\n")
        chat:add_tool_output(self, output, output)
        return
      end

      local todos = result.todos
      local is_new = result.is_new
      local action = is_new and "created" or "updated"

      -- LLM sees structured output
      local llm_output = fmt(
        [[<todoUpdate action="%s" count="%d">
%s
</todoUpdate>

Task list %s. Continue with your work.]],
        action,
        #todos,
        format_todos_for_llm(todos),
        action
      )

      -- User sees formatted output
      local user_output = build_user_output_write(todos, action)

      chat:add_tool_output(self, llm_output, user_output)
    end,

    ---@param self CodeCompanion.Tool.TodoWrite
    ---@param tools CodeCompanion.Tools
    ---@param cmd table
    ---@param stderr table
    error = function(self, tools, cmd, stderr)
      local chat = tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      log:debug("[TodoWrite Tool] Error: %s", errors)

      local error_output = fmt("%s Failed to update task list: %s", ICONS.cancelled, errors)
      chat:add_tool_output(self, error_output, error_output)
    end,

    ---@param self CodeCompanion.Tool.TodoWrite
    ---@param tools CodeCompanion.Tools
    rejected = function(self, tools)
      local chat = tools.chat
      chat:add_tool_output(self, "User rejected task list update", "Task list update cancelled")
    end,
  },
}

---@class CodeCompanion.Tool.TodoRead: CodeCompanion.Tools.Tool
local todoread = {
  name = "todoread",
  cmds = {
    ---Execute the todoread tool
    ---@param tools CodeCompanion.Tools
    ---@return { status: string, data: any }
    function(tools)
      if not tools or not tools.chat then
        return {
          status = "error",
          data = "No chat context available",
        }
      end

      local chat = tools.chat
      local todos = get_todos(chat.bufnr)

      return {
        status = "success",
        data = {
          message = fmt("Current task list (%s):\n\n%s", build_title(todos), format_todos_for_llm(todos)),
          todos = todos,
        },
      }
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "todoread",
      description = [[Read the current task list to check progress and see what work remains.

Use this to:
- Check what tasks are pending
- See which task is currently in progress
- Review completed work
- Plan next steps based on remaining tasks]],
      parameters = {
        type = "object",
        properties = vim.empty_dict(),
      },
    },
  },
  opts = {
    requires_approval = false,
    hide_from_agent = function(chat)
      if not chat or not chat.bufnr then return true end
      local ok, agents = pcall(require, "codecompanion-extra.agents")
      if not ok then return false end
      local active = agents.active(chat.bufnr)
      return active ~= nil and active ~= "build"
    end,
  },
  handlers = {
    on_exit = function(tools)
      log:trace("[TodoRead Tool] on_exit handler executed")
    end,
  },
  output = {
    ---@param self CodeCompanion.Tool.TodoRead
    ---@return string
    cmd_string = function(self)
      return "Read task list"
    end,

    ---@param self CodeCompanion.Tool.TodoRead
    ---@return string
    prompt = function(self)
      return "Read current task list?"
    end,

    ---@param self CodeCompanion.Tool.TodoRead
    ---@param tools CodeCompanion.Tools
    ---@param cmd table
    ---@param stdout table
    success = function(self, tools, cmd, stdout)
      local chat = tools.chat
      local result = stdout[1]

      if type(result) ~= "table" or not result.todos then
        -- Fallback for unexpected format
        local output = vim.iter(stdout):flatten():join("\n")
        chat:add_tool_output(self, output, output)
        return
      end

      local todos = result.todos

      -- LLM sees structured output
      local llm_output = fmt(
        [[<todoList count="%d">
%s
</todoList>

Review the task list above and continue with your work.]],
        #todos,
        format_todos_for_llm(todos)
      )

      -- User sees formatted output
      local user_output = build_user_output_read(todos)

      chat:add_tool_output(self, llm_output, user_output)
    end,

    ---@param self CodeCompanion.Tool.TodoRead
    ---@param tools CodeCompanion.Tools
    ---@param cmd table
    ---@param stderr table
    error = function(self, tools, cmd, stderr)
      local chat = tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      log:debug("[TodoRead Tool] Error: %s", errors)

      local error_output = fmt("%s Failed to read task list: %s", ICONS.cancelled, errors)
      chat:add_tool_output(self, error_output, error_output)
    end,

    ---@param self CodeCompanion.Tool.TodoRead
    ---@param tools CodeCompanion.Tools
    rejected = function(self, tools)
      local chat = tools.chat
      chat:add_tool_output(self, "User rejected reading task list", "Task list read cancelled")
    end,
  },
}

local M = {}

---Get the todowrite tool definition
---@return table
function M.get_todowrite()
  return todowrite
end

---Get the todoread tool definition
---@return table
function M.get_todoread()
  return todoread
end

---Get todos for a buffer
---@param bufnr number
---@return CodeCompanionExtra.TodoItem[]
function M.get_todos(bufnr)
  return get_todos(bufnr)
end

---Clear todos for a buffer
---@param bufnr number
function M.clear_todos(bufnr)
  _todo_store[bufnr] = nil
end

---Clear all todos
function M.clear_all()
  _todo_store = {}
  _id_counter = 0
end

return M
