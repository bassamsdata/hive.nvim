-- Todo tools for task tracking during complex operations
-- Only the build agent has write access, subagents can only read
--
-- The todo system allows agents to:
-- Track multi-step tasks with status (pending, in_progress, completed, cancelled)
-- Prioritize work (high, medium, low)
-- Maintain visibility into workflow progress

local log = require("codecompanion.utils.log")
local compat = require("codecompanion-extra.tools.compat")

local api = vim.api
local fmt = string.format

-- ============================================================================
-- Constants
-- ============================================================================

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

-- ============================================================================
-- Storage
-- ============================================================================

---@class CodeCompanionExtra.TodoItem
---@field id string Unique identifier for the todo
---@field content string Brief description of the task (5-7 words)
---@field status "pending" | "in_progress" | "completed" | "cancelled"
---@field priority "high" | "medium" | "low"

---@type table<number, CodeCompanionExtra.TodoItem[]>
local _todo_store = {}

---@type number
local _id_counter = 0

-- ============================================================================
-- Helper Functions
-- ============================================================================

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

  -- Show ALL tasks individually, grouped by status
  for _, todo in ipairs(todos) do
    if todo.status == "in_progress" then
      local priority_icon = get_priority_icon(todo.priority)
      table.insert(lines, fmt("  %s %s %s", ICONS.in_progress, priority_icon, todo.content))
    end
  end

  for _, todo in ipairs(todos) do
    if todo.status == "pending" then
      local priority_icon = get_priority_icon(todo.priority)
      table.insert(lines, fmt("  %s %s %s", ICONS.pending, priority_icon, todo.content))
    end
  end

  for _, todo in ipairs(todos) do
    if todo.status == "completed" then table.insert(lines, fmt("  %s %s", ICONS.completed, todo.content)) end
  end

  for _, todo in ipairs(todos) do
    if todo.status == "cancelled" then table.insert(lines, fmt("  %s %s", ICONS.cancelled, todo.content)) end
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

  -- Show ALL tasks individually, grouped by status
  for _, todo in ipairs(todos) do
    if todo.status == "in_progress" then
      local priority_icon = get_priority_icon(todo.priority)
      table.insert(lines, fmt("  %s **%s** %s", ICONS.in_progress, priority_icon, todo.content))
    end
  end

  for _, todo in ipairs(todos) do
    if todo.status == "pending" then
      local priority_icon = get_priority_icon(todo.priority)
      table.insert(lines, fmt("  %s **%s** %s", ICONS.pending, priority_icon, todo.content))
    end
  end

  for _, todo in ipairs(todos) do
    if todo.status == "completed" then table.insert(lines, fmt("  %s %s", ICONS.completed, todo.content)) end
  end

  for _, todo in ipairs(todos) do
    if todo.status == "cancelled" then table.insert(lines, fmt("  %s %s", ICONS.cancelled, todo.content)) end
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
    "═════════════════════════════════════════════════"
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

-- ============================================================================
-- TodoWrite Tool
-- ============================================================================

---@class CodeCompanion.Tool.TodoWrite: CodeCompanion.Tools.Tool
local todowrite = {
  name = "todowrite",
  cmds = {
    ---Execute the todowrite tool
    ---@param tools CodeCompanion.Tools
    ---@param args table
    ---@param opts table
    ---@return { status: string, data: any }
    compat.cmds(function(tools, args, opts)
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
    end),
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
    on_exit = compat.handler_on_exit(function(_self, _meta)
      log:trace("[TodoWrite Tool] on_exit handler executed")
    end),
  },
  output = {
    ---@param self CodeCompanion.Tool.TodoWrite
    ---@return string
    cmd_string = compat.output_cmd_string(function(self, _meta)
      local count = self.args.todos and #self.args.todos or 0
      return fmt("Update task list (%d items)", count)
    end),

    ---@param self CodeCompanion.Tool.TodoWrite
    ---@return string
    prompt = compat.output_prompt(function(self, _meta)
      local count = self.args.todos and #self.args.todos or 0
      return fmt("Update task list with %d item%s?", count, count == 1 and "" or "s")
    end),

    ---@param self CodeCompanion.Tool.TodoWrite
    ---@param stdout table
    ---@param meta table
    success = compat.output_success(function(self, stdout, meta)
      local chat = meta.tools.chat
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

      local user_output = build_user_output_write(todos, action)

      chat:add_tool_output(self, llm_output, user_output)
    end),

    ---@param self CodeCompanion.Tool.TodoWrite
    ---@param stderr table
    ---@param meta table
    error = compat.output_error(function(self, stderr, meta)
      local chat = meta.tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      log:debug("[TodoWrite Tool] Error: %s", errors)

      local error_output = fmt("%s Failed to update task list: %s", ICONS.cancelled, errors)
      chat:add_tool_output(self, error_output, error_output)
    end),

    ---@param self CodeCompanion.Tool.TodoWrite
    ---@param meta table
    rejected = compat.output_rejected(function(self, meta)
      local chat = meta.tools.chat
      chat:add_tool_output(self, "User rejected task list update", "Task list update cancelled")
    end),
  },
}

-- ============================================================================
-- TodoRead Tool
-- ============================================================================

---@class CodeCompanion.Tool.TodoRead: CodeCompanion.Tools.Tool
local todoread = {
  name = "todoread",
  cmds = {
    ---Execute the todoread tool
    ---@param tools CodeCompanion.Tools
    ---@param args table
    ---@param opts table
    ---@return { status: string, data: any }
    compat.cmds(function(tools, args, opts)
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
    end),
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
    on_exit = compat.handler_on_exit(function(_self, _meta)
      log:trace("[TodoRead Tool] on_exit handler executed")
    end),
  },
  output = {
    ---@param self CodeCompanion.Tool.TodoRead
    ---@return string
    cmd_string = compat.output_cmd_string(function(self, _meta)
      return "Read task list"
    end),

    ---@param self CodeCompanion.Tool.TodoRead
    ---@return string
    prompt = compat.output_prompt(function(self, _meta)
      return "Read current task list?"
    end),

    ---@param self CodeCompanion.Tool.TodoRead
    ---@param stdout table
    ---@param meta table
    success = compat.output_success(function(self, stdout, meta)
      local chat = meta.tools.chat
      local result = stdout[1]

      if type(result) ~= "table" or not result.todos then
        -- Fallback for unexpected format
        local output = vim.iter(stdout):flatten():join("\n")
        chat:add_tool_output(self, output, output)
        return
      end

      local todos = result.todos

      local llm_output = fmt(
        [[<todoList count="%d">
%s
</todoList>

Review the task list above and continue with your work.]],
        #todos,
        format_todos_for_llm(todos)
      )

      local user_output = build_user_output_read(todos)

      chat:add_tool_output(self, llm_output, user_output)
    end),

    ---@param self CodeCompanion.Tool.TodoRead
    ---@param stderr table
    ---@param meta table
    error = compat.output_error(function(self, stderr, meta)
      local chat = meta.tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      log:debug("[TodoRead Tool] Error: %s", errors)

      local error_output = fmt("%s Failed to read task list: %s", ICONS.cancelled, errors)
      chat:add_tool_output(self, error_output, error_output)
    end),

    ---@param self CodeCompanion.Tool.TodoRead
    ---@param meta table
    rejected = compat.output_rejected(function(self, meta)
      local chat = meta.tools.chat
      chat:add_tool_output(self, "User rejected reading task list", "Task list read cancelled")
    end),
  },
}

-- ============================================================================
-- Todo Viewer Window
-- ============================================================================

---@class TodoViewer
---@field bufnr number|nil
---@field winnr number|nil
---@field ns_id number
---@field chat_bufnr number
local TodoViewer = {}
TodoViewer.__index = TodoViewer

---@type TodoViewer|nil
local _active_viewer = nil

---Create a new TodoViewer
---@param chat_bufnr number
---@return TodoViewer
function TodoViewer.new(chat_bufnr)
  local self = setmetatable({}, TodoViewer)
  self.chat_bufnr = chat_bufnr
  self.ns_id = api.nvim_create_namespace("codecompanion_todo_viewer")
  return self
end

---Calculate window dimensions and position
---@return { width: number, height: number, row: number, col: number }
function TodoViewer:_calculate_dimensions()
  local todos = get_todos(self.chat_bufnr)
  local width = math.min(70, math.floor(vim.o.columns * 0.6))
  local height = math.max(math.min(5 + #todos, math.floor(vim.o.lines * 0.6)), 8)

  local status = vim.o.laststatus > 0 and 1 or 0
  local cmd = vim.o.cmdheight
  local tab = vim.o.showtabline > 0 and 1 or 0

  local avail = vim.o.lines - status - cmd - tab
  local row = math.max(tab, tab + math.floor((avail - height) / 2) - 1)
  local col = math.floor((vim.o.columns - width) / 2)

  return { width = width, height = height, row = row, col = col }
end

---Build content lines for the viewer
---@return string[] lines
---@return table[] highlights
function TodoViewer:_build_content()
  local todos = get_todos(self.chat_bufnr)
  local lines = {}
  local highlights = {}

  api.nvim_set_hl(0, "CodeCompanionTodoHigh", { link = HIGHLIGHTS.high, bold = true })
  api.nvim_set_hl(0, "CodeCompanionTodoMedium", { link = HIGHLIGHTS.medium, bold = true })
  api.nvim_set_hl(0, "CodeCompanionTodoLow", { link = HIGHLIGHTS.low, bold = true })

  local dim = self:_calculate_dimensions()
  local inner_width = dim.width - 3

  -- Helper to add a line with optional highlight
  local function add_line(text, hl_group)
    table.insert(lines, text)
    if hl_group then table.insert(highlights, { #lines - 1, 0, -1, hl_group }) end
  end

  ---Helper to add a todo line with priority highlight
  ---@param todo CodeCompanionExtra.TodoItem
  ---@param icon string
  ---@param hl string
  local function add_todo_line(todo, icon, hl)
    local priority_icon = get_priority_icon(todo.priority)
    local line = fmt("  %s %s %s", icon, priority_icon, todo.content)
    if #line > inner_width then line = line:sub(1, inner_width - 1) .. "…" end
    add_line(line, hl)

    local priority_hl = "CodeCompanionTodo" .. todo.priority:gsub("^%l", string.upper)
    local pos = line:find(priority_icon, 1, true)
    if pos then table.insert(highlights, { #lines - 1, pos - 1, pos - 1 + #priority_icon, priority_hl }) end
  end

  -- Header
  add_line("", nil)
  local counts = count_todos(todos)
  local progress_text = fmt("  %s %d/%d completed", ICONS.progress, counts.completed, counts.total)
  add_line(progress_text, HIGHLIGHTS.header)
  add_line("", nil)

  if #todos == 0 then
    add_line("  No tasks yet", HIGHLIGHTS.pending)
    add_line("", nil)
    add_line("  The agent will create tasks", HIGHLIGHTS.pending)
    add_line("  when working on complex operations.", HIGHLIGHTS.pending)
  else
    -- Show ALL tasks individually, grouped by status
    for _, todo in ipairs(todos) do
      if todo.status == "in_progress" then add_todo_line(todo, ICONS.in_progress, HIGHLIGHTS.in_progress) end
    end

    for _, todo in ipairs(todos) do
      if todo.status == "pending" then add_todo_line(todo, ICONS.pending, HIGHLIGHTS.pending) end
    end

    if counts.completed > 0 or counts.cancelled > 0 then add_line("", nil) end

    for _, todo in ipairs(todos) do
      if todo.status == "completed" then add_todo_line(todo, ICONS.completed, HIGHLIGHTS.completed) end
    end

    for _, todo in ipairs(todos) do
      if todo.status == "cancelled" then add_todo_line(todo, ICONS.cancelled, HIGHLIGHTS.cancelled) end
    end
  end

  add_line("", nil)

  return lines, highlights
end

---Show the todo viewer window
function TodoViewer:show()
  if _active_viewer then _active_viewer:close() end

  local dim = self:_calculate_dimensions()

  self.bufnr = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("buftype", "nofile", { buf = self.bufnr })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = self.bufnr })
  api.nvim_set_option_value("swapfile", false, { buf = self.bufnr })
  api.nvim_buf_set_name(self.bufnr, "CodeCompanion_Todos")
  vim.b[self.bufnr].miniindentscope_disable = true

  self.winnr = api.nvim_open_win(self.bufnr, true, {
    relative = "editor",
    width = dim.width,
    height = dim.height,
    row = dim.row,
    col = dim.col,
    style = "minimal",
    border = "rounded",
    title = fmt(" %s Task List ", ICONS.todo),
    title_pos = "center",
    footer = " q:close ",
    footer_pos = "center",
  })

  api.nvim_set_option_value("wrap", true, { win = self.winnr })
  api.nvim_set_option_value("cursorline", false, { win = self.winnr })

  _active_viewer = self

  self:render()

  local close_keys = { "q", "<Esc>", "<CR>" }
  for _, key in ipairs(close_keys) do
    vim.keymap.set("n", key, function()
      self:close()
    end, { buffer = self.bufnr, nowait = true })
  end

  api.nvim_create_autocmd("WinLeave", {
    buffer = self.bufnr,
    once = true,
    callback = function()
      vim.schedule(function()
        self:close()
      end)
    end,
  })
end

---Render content into the buffer
function TodoViewer:render()
  if not self.bufnr or not api.nvim_buf_is_valid(self.bufnr) then return end

  local lines, highlights = self:_build_content()

  api.nvim_set_option_value("modifiable", true, { buf = self.bufnr })
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = self.bufnr })

  api.nvim_buf_clear_namespace(self.bufnr, self.ns_id, 0, -1)
  for _, hl in ipairs(highlights) do
    local line, col_start, col_end, hl_group = hl[1], hl[2], hl[3], hl[4]
    if col_end == -1 then col_end = #lines[line + 1] end
    pcall(api.nvim_buf_set_extmark, self.bufnr, self.ns_id, line, col_start, {
      end_col = col_end,
      hl_group = hl_group,
    })
  end
end

---Close the viewer
function TodoViewer:close()
  if self.winnr and api.nvim_win_is_valid(self.winnr) then api.nvim_win_close(self.winnr, true) end
  self.winnr = nil
  self.bufnr = nil
  if _active_viewer == self then _active_viewer = nil end
end

-- ============================================================================
-- Module Exports
-- ============================================================================

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

---Show todo viewer for a chat buffer
---@param chat_bufnr number
function M.show_viewer(chat_bufnr)
  local viewer = TodoViewer.new(chat_bufnr)
  viewer:show()
end

---Close active viewer if any
function M.close_viewer()
  if _active_viewer then _active_viewer:close() end
end

---Setup keymap for todo viewer
---@param keymap? string Default "gT"
function M.setup_keymap(keymap)
  keymap = keymap or "gT"

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local chat_keymaps = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.keymaps
  if not chat_keymaps then return end

  chat_keymaps["todo_viewer"] = {
    modes = { n = keymap },
    index = 51,
    description = "[Todo] View task list",
    callback = function(chat)
      if chat and chat.bufnr then M.show_viewer(chat.bufnr) end
    end,
  }
end

return M
