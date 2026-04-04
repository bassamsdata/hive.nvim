local log = require("codecompanion.utils.log")
local compat = require("hive.tools.compat")
local notify = require("hive.utils.notify")

local api = vim.api
local fmt = string.format

---@class AskUserQuestion
---@field id string Unique identifier for the question
---@field question string
---@field type "text"|"choice"|"multi_choice"
---@field required? boolean Whether an answer is required
---@field choices? string[]
---@field default? string|string[]

---@class AskUserForm
---@field bufnr number
---@field winnr number
---@field context_bufnr? number
---@field context_winnr? number
---@field ns_id number
---@field width number
---@field height number
---@field context? string
---@field line_map table<number, {type: string, question_idx?: number, choice_idx?: number}>
---@field questions AskUserQuestion[]
---@field answers table<string, string|string[]>
---@field current_index number Currently focused question (1-based)
---@field current_choice_index number Currently focused choice within a question (1-based)
---@field hidden boolean Whether the form is currently hidden (windows closed but state preserved)
---@field callback function
local AskUserForm = {}
AskUserForm.__index = AskUserForm

local HL = {
  QUESTION = "Question",
  CHOICE = "Comment",
  SELECTED = "DiagnosticOk",
  REQUIRED = "DiagnosticError",
  INPUT = "Normal",
  HEADER = "Title",
  CONTEXT = "Normal",
  SEPARATOR = "Comment",
  CURRENT = "CursorLine",
  WINBAR_KEY = "Comment",
}

---@type AskUserForm|nil
local active_form = nil

---Toggle visibility of the active ask_user form
---@return boolean acted Whether a toggle action was performed
local function toggle_form()
  if not active_form then return false end

  if active_form.hidden then
    active_form:restore()
  else
    active_form:hide()
  end
  return true
end

---Create a new AskUserForm instance
---@param args { questions: AskUserQuestion[], context?: string, callback: function }
---@return AskUserForm
function AskUserForm.new(args)
  local self = setmetatable({}, AskUserForm)

  self.questions = args.questions
  self.context = args.context
  self.callback = args.callback
  self.current_index = 1
  self.current_choice_index = 1
  self.answers = {}
  self.line_map = {}
  self.hidden = false
  self.ns_id = api.nvim_create_namespace("codecompanion_ask_user")

  for _, q in ipairs(self.questions) do
    if q.default then
      self.answers[q.id] = q.default
    elseif q.type == "multi_choice" then
      self.answers[q.id] = {}
    end
  end

  return self
end

---Create a buffer and window with standard options
---@param config table
---@return { bufnr: number, winnr: number }
function AskUserForm:_create_window(config)
  local bufnr = api.nvim_create_buf(false, true)
  local set_option = api.nvim_set_option_value
  set_option("buftype", "nofile", { buf = bufnr })
  set_option("bufhidden", "wipe", { buf = bufnr })
  set_option("swapfile", false, { buf = bufnr })
  api.nvim_buf_set_name(bufnr, config.name)
  vim.b[bufnr].miniindentscope_disable = true

  if config.filetype then set_option("filetype", config.filetype, { buf = bufnr }) end
  local winnr = api.nvim_open_win(bufnr, config.focusable, {
    relative = "editor",
    width = config.width,
    height = config.height,
    row = config.row,
    col = config.col,
    style = "minimal",
    border = config.border or "none",
    title = config.title,
    title_pos = config.title_pos,
    focusable = config.focusable,
  })

  if config.winhighlight then set_option("winhighlight", config.winhighlight, { win = winnr }) end
  set_option("wrap", true, { win = winnr })
  set_option("cursorline", false, { win = winnr })

  return { bufnr = bufnr, winnr = winnr }
end

---Build a horizontal line with box characters
---@param width number
---@param left_char string
---@param right_char string
---@param fill_char string
---@param title? string
---@return string
function AskUserForm:_build_line(width, left_char, right_char, fill_char, title)
  local inner_width = width - 2

  if title then
    local title_with_spaces = " " .. title .. " "
    local title_len = vim.fn.strdisplaywidth(title_with_spaces)
    local remaining = inner_width - title_len
    local left_fill = math.floor(remaining / 2)
    local right_fill = remaining - left_fill
    return left_char
      .. string.rep(fill_char, left_fill)
      .. title_with_spaces
      .. string.rep(fill_char, right_fill)
      .. right_char
  else
    return left_char .. string.rep(fill_char, inner_width) .. right_char
  end
end

---Pad or truncate text to fit width
---@param text string
---@param width number
---@param prefix? string
---@return string
function AskUserForm:_fit_text(text, width, prefix)
  prefix = prefix or "│ "
  local suffix = " │"
  local available = width - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(suffix)
  local text_width = vim.fn.strdisplaywidth(text)

  if text_width > available then
    text = vim.fn.strcharpart(text, 0, available - 1) .. "…"
  elseif text_width < available then
    text = text .. string.rep(" ", available - text_width)
  end

  return prefix .. text .. suffix
end

---Calculate context window height based on content
---@return number
function AskUserForm:_get_context_height()
  if not self.context then return 0 end
  local width = self.width - 2 -- account for padding/border
  local lines = vim.split(self.context, "\n")
  local height = 0
  for _, line in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  return math.min(height, 5)
end

---Build context buffer content
---@return string[] lines
---@return table[] highlights
function AskUserForm:_build_context_content()
  if not self.context then return {}, {} end

  local lines = vim.split(self.context, "\n")
  local highlights = {}

  for i = 0, #lines - 1 do
    table.insert(highlights, { i, 0, -1, HL.CONTEXT })
  end

  return lines, highlights
end

---Build the form content for display (questions only, context is in extmark)
---@return string[] lines
---@return {line: number, col_start: number, col_end: number, hl_group: string}[] highlights
function AskUserForm:_build_content()
  local lines = {}
  local highlights = {}
  local width = self.width

  self.line_map = {}

  local function add_line(line, hl_group, line_info)
    table.insert(lines, line)
    local line_idx = #lines - 1
    self.line_map[line_idx] = line_info or { type = "other" }
    if hl_group then table.insert(highlights, { line_idx, 0, -1, hl_group }) end
  end

  for i, q in ipairs(self.questions) do
    local is_current = i == self.current_index
    local prefix = is_current and "▶ " or "  "
    local required_mark = q.required and " *" or ""

    local question_line = fmt("%s%d. %s%s", prefix, i, q.question, required_mark)
    table.insert(lines, question_line)

    local line_idx = #lines - 1
    self.line_map[line_idx] = { type = "question", question_idx = i }

    if is_current then table.insert(highlights, { line_idx, 0, 2, HL.SELECTED }) end
    table.insert(highlights, { line_idx, #prefix, #prefix + 2 + #tostring(i), HL.QUESTION })
    if q.required then table.insert(highlights, { line_idx, #question_line - 2, #question_line, HL.REQUIRED }) end

    local answer = self.answers[q.id]

    if q.type == "text" then
      local display_answer = answer or "(press Enter to input)"
      local input_line = fmt("   Answer: %s", display_answer)
      table.insert(lines, input_line)
      local input_line_idx = #lines - 1
      self.line_map[input_line_idx] = { type = "text_input", question_idx = i }

      if is_current then
        table.insert(highlights, { input_line_idx, 0, -1, HL.CURRENT })
      else
        table.insert(highlights, { input_line_idx, 11, -1, HL.INPUT })
      end
    elseif q.type == "choice" then
      for j, choice in ipairs(q.choices or {}) do
        local selected = answer == choice
        local is_choice_current = is_current and j == self.current_choice_index
        local choice_prefix = selected and "   ● " or "   ○ "
        local choice_line = fmt("%s%s", choice_prefix, choice)
        table.insert(lines, choice_line)

        local choice_line_idx = #lines - 1
        self.line_map[choice_line_idx] = { type = "choice", question_idx = i, choice_idx = j }

        if is_choice_current then
          table.insert(highlights, { choice_line_idx, 0, -1, HL.CURRENT })
        elseif selected then
          table.insert(highlights, { choice_line_idx, 0, -1, HL.SELECTED })
        else
          table.insert(highlights, { choice_line_idx, 0, -1, HL.CHOICE })
        end
      end
    elseif q.type == "multi_choice" then
      local selected_set = {}
      if type(answer) == "table" then
        for _, v in ipairs(answer) do
          selected_set[v] = true
        end
      end

      for j, choice in ipairs(q.choices or {}) do
        local selected = selected_set[choice]
        local is_choice_current = is_current and j == self.current_choice_index
        local choice_prefix = selected and "   ☑ " or "   ☐ "
        local choice_line = fmt("%s%s", choice_prefix, choice)
        table.insert(lines, choice_line)

        local choice_line_idx = #lines - 1
        self.line_map[choice_line_idx] = { type = "multi_choice", question_idx = i, choice_idx = j }

        if is_choice_current then
          table.insert(highlights, { choice_line_idx, 0, -1, HL.CURRENT })
        elseif selected then
          table.insert(highlights, { choice_line_idx, 0, -1, HL.SELECTED })
        else
          table.insert(highlights, { choice_line_idx, 0, -1, HL.CHOICE })
        end
      end
    end

    add_line("", nil, { type = "spacer" })
  end

  add_line(self:_build_line(width, "─", "─", "─"), HL.SEPARATOR, { type = "separator" })

  return lines, highlights
end

---Get the line number for the current question/choice
---@return number 1-based line number
function AskUserForm:_get_cursor_line()
  local q = self.questions[self.current_index]
  if not q then return 1 end

  for line_idx, info in pairs(self.line_map) do
    if info.question_idx == self.current_index then
      if q.type == "text" and info.type == "text_input" then
        return line_idx + 1
      elseif (q.type == "choice" or q.type == "multi_choice") and info.choice_idx == self.current_choice_index then
        return line_idx + 1
      elseif info.type == "question" and q.type == "text" then
        -- For text, position on the question line initially
        return line_idx + 1
      end
    end
  end

  return 1
end

---Render the form in the buffer
---@param self AskUserForm
function AskUserForm:render()
  if not self.bufnr or not api.nvim_buf_is_valid(self.bufnr) then return end

  ---@type string[]
  ---@type table[] highlights: {line, col_start, col_end, hl_group}
  local lines, highlights = self:_build_content()

  -- Filter newlines from lines to prevent nvim_buf_set_lines errors
  -- Some LLM outputs may contain embedded newlines in individual lines
  for i, line in ipairs(lines) do
    lines[i] = line:gsub("\n", " ")
  end

  api.nvim_set_option_value("modifiable", true, { buf = self.bufnr })
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = self.bufnr })
  api.nvim_buf_clear_namespace(self.bufnr, self.ns_id, 0, -1)

  for _, hl in ipairs(highlights) do
    ---@type integer, integer, integer, string
    local line, col_start, col_end, hl_group = hl[1], hl[2], hl[3], hl[4]
    if col_end == -1 then col_end = #lines[line + 1] end
    pcall(api.nvim_buf_set_extmark, self.bufnr, self.ns_id, line, col_start, { end_col = col_end, hl_group = hl_group })
  end

  -- Render context in separate buffer if it exists
  if self.context and self.context_bufnr and api.nvim_buf_is_valid(self.context_bufnr) then
    local ctx_lines, ctx_highlights = self:_build_context_content()

    -- Filter newlines from context lines too
    for i, line in ipairs(ctx_lines) do
      ctx_lines[i] = line:gsub("\n", " ")
    end

    api.nvim_set_option_value("modifiable", true, { buf = self.context_bufnr })
    api.nvim_buf_set_lines(self.context_bufnr, 0, -1, false, ctx_lines)
    api.nvim_set_option_value("modifiable", false, { buf = self.context_bufnr })

    local ctx_ns_id = api.nvim_create_namespace("codecompanion_ask_user_ctx")
    api.nvim_buf_clear_namespace(self.context_bufnr, ctx_ns_id, 0, -1)

    for _, hl in ipairs(ctx_highlights) do
      local line, col_start, col_end, hl_group = hl[1], hl[2], hl[3], hl[4]
      if col_end == -1 then col_end = #ctx_lines[line + 1] end
      pcall(
        api.nvim_buf_set_extmark,
        self.context_bufnr,
        ctx_ns_id,
        line,
        col_start,
        { end_col = col_end, hl_group = hl_group }
      )
    end
  end

  if self.winnr and api.nvim_win_is_valid(self.winnr) then
    ---@type integer
    local cursor_line = self:_get_cursor_line()
    pcall(api.nvim_win_set_cursor, self.winnr, { cursor_line, 0 })
  end
end

---Set window bar with formatted hint items
---@param items {keys: string, desc: string}[] array of key-description pairs
function AskUserForm:_set_winbar(items)
  if not self.winnr or not api.nvim_win_is_valid(self.winnr) then return end

  local parts = {}
  for _, item in ipairs(items) do
    table.insert(parts, "%#" .. HL.WINBAR_KEY .. "#" .. item.keys .. ":%* " .. item.desc)
  end

  local bar = table.concat(parts, "  │  ")
  vim.wo[self.winnr].winbar = "%=" .. bar .. "%="
end

---Set up the winbar with keymaps
---@return nil
function AskUserForm:_setup_winbar()
  self:_set_winbar({
    { keys = "j/k", desc = "Navigate" },
    { keys = "Enter/Space", desc = "Select" },
    { keys = "S", desc = "Submit" },
    { keys = "H", desc = "Hide" },
    { keys = "R", desc = "Reject" },
    { keys = "q", desc = "Cancel" },
  })
end

---Move to next question
---@return nil
function AskUserForm:next_question()
  self.current_index = (self.current_index % #self.questions) + 1
  self.current_choice_index = 1
  self:render()
end

---Move to previous question
---@return nil
function AskUserForm:prev_question()
  self.current_index = self.current_index - 1
  if self.current_index < 1 then self.current_index = #self.questions end
  self.current_choice_index = 1
  self:render()
end

---Move to next choice within current question
---@return nil
function AskUserForm:next_choice()
  local q = self.questions[self.current_index]
  if not q or not q.choices or #q.choices == 0 then return self:next_question() end

  self.current_choice_index = self.current_choice_index + 1
  if self.current_choice_index > #q.choices then return self:next_question() end
  self:render()
end

---Move to previous choice within current question
---@return nil
function AskUserForm:prev_choice()
  local q = self.questions[self.current_index]
  if not q or not q.choices or #q.choices == 0 then return self:prev_question() end

  self.current_choice_index = self.current_choice_index - 1
  if self.current_choice_index < 1 then
    self:prev_question()
    local new_q = self.questions[self.current_index]
    if new_q and new_q.choices and #new_q.choices > 0 then self.current_choice_index = #new_q.choices end
    self:render()
    return
  end
  self:render()
end

---Handle text input for current question
---@return nil
function AskUserForm:handle_text_input()
  local q = self.questions[self.current_index]
  local current_answer = self.answers[q.id] or ""

  local form = self

  vim.ui.input({
    prompt = q.question .. ": ",
    default = current_answer,
  }, function(input)
    if input ~= nil then
      form.answers[q.id] = input
      vim.schedule(function()
        form:render()
      end)
    end
  end)
end

---Handle choice selection (single choice)
---@return nil
function AskUserForm:handle_choice_select()
  local q = self.questions[self.current_index]
  if not q.choices or #q.choices == 0 then return end

  local choice = q.choices[self.current_choice_index]
  if choice then
    self.answers[q.id] = choice
    self:render()
  end
end

---Handle multi-choice toggle
---@return nil
function AskUserForm:handle_multi_choice_toggle()
  local q = self.questions[self.current_index]
  if not q.choices or #q.choices == 0 then return end

  local choice = q.choices[self.current_choice_index]
  if not choice then return end

  local current = self.answers[q.id]
  if type(current) ~= "table" then current = {} end

  -- Build set for quick lookup
  local selected_set = {}
  for _, v in ipairs(current) do
    selected_set[v] = true
  end

  if selected_set[choice] then
    selected_set[choice] = nil
  else
    selected_set[choice] = true
  end

  -- Rebuild answer array preserving order from choices
  local new_answer = {}
  for _, c in ipairs(q.choices) do
    if selected_set[c] then table.insert(new_answer, c) end
  end

  self.answers[q.id] = new_answer
  self:render()
end

---Handle enter/space key based on question type
---@return nil
function AskUserForm:handle_select()
  local q = self.questions[self.current_index]

  if q.type == "text" then
    self:handle_text_input()
  elseif q.type == "choice" then
    self:handle_choice_select()
  elseif q.type == "multi_choice" then
    self:handle_multi_choice_toggle()
  end
end

---Validate all required questions are answered
---@return boolean valid
---@return string[] missing List of missing question texts
function AskUserForm:validate()
  local missing = {}

  for _, q in ipairs(self.questions) do
    if q.required then
      local answer = self.answers[q.id]
      if answer == nil or answer == "" then
        table.insert(missing, q.question)
      elseif type(answer) == "table" and #answer == 0 then
        table.insert(missing, q.question)
      end
    end
  end

  return #missing == 0, missing
end

---Submit the form to the LLM
---@return nil
function AskUserForm:submit()
  local valid, missing = self:validate()

  if not valid then
    notify("Please answer required questions:\n- " .. table.concat(missing, "\n- "), vim.log.levels.WARN)
    return
  end

  local callback = self.callback
  local answers = vim.deepcopy(self.answers)

  self:close()

  if callback then callback({
    status = "success",
    data = answers,
  }) end
end

---Close the form window and buffer
---@return nil
function AskUserForm:close()
  local winnr = self.winnr
  local bufnr = self.bufnr
  local context_winnr = self.context_winnr
  local context_bufnr = self.context_bufnr

  self.winnr = nil
  self.bufnr = nil
  self.context_winnr = nil
  self.context_bufnr = nil
  active_form = nil

  -- Close context window first (it's on top)
  if context_winnr and api.nvim_win_is_valid(context_winnr) then api.nvim_win_close(context_winnr, true) end

  if context_bufnr and api.nvim_buf_is_valid(context_bufnr) then
    api.nvim_buf_delete(context_bufnr, { force = true })
  end

  if winnr and api.nvim_win_is_valid(winnr) then api.nvim_win_close(winnr, true) end

  if bufnr and api.nvim_buf_is_valid(bufnr) then api.nvim_buf_delete(bufnr, { force = true }) end
end

---Hide the form windows without destroying state
---Windows are closed but buffers, answers, and navigation state are preserved
---@return nil
function AskUserForm:hide()
  if self.hidden then return end
  self.hidden = true

  if self.context_winnr and api.nvim_win_is_valid(self.context_winnr) then
    api.nvim_win_close(self.context_winnr, true)
  end
  self.context_winnr = nil

  if self.winnr and api.nvim_win_is_valid(self.winnr) then api.nvim_win_close(self.winnr, true) end
  self.winnr = nil

  if self.context_bufnr and api.nvim_buf_is_valid(self.context_bufnr) then
    api.nvim_buf_delete(self.context_bufnr, { force = true })
  end
  self.context_bufnr = nil

  if self.bufnr and api.nvim_buf_is_valid(self.bufnr) then api.nvim_buf_delete(self.bufnr, { force = true }) end
  self.bufnr = nil
end

---Restore a hidden form by re-creating windows and re-rendering
---@return nil
function AskUserForm:restore()
  if not self.hidden then return end
  self.hidden = false
  self:_open()
end

---Open the form windows and setup UI
---@return nil
function AskUserForm:_open()
  local cols, lines = vim.o.columns, vim.o.lines
  self.width = math.min(90, math.floor(cols * 0.85))

  local ctx_h = self:_get_context_height()
  local total_h = math.min(30, math.floor(lines * 0.7))
  self.height = ctx_h > 0 and math.max(10, total_h - ctx_h) or total_h

  local tabline_h = vim.o.showtabline > 0 and 1 or 0
  local ui_h = lines - (vim.o.cmdheight + (vim.o.laststatus > 0 and 1 or 0) + tabline_h)
  local start_row = tabline_h + math.floor((ui_h - (ctx_h + self.height + (ctx_h > 0 and 2 or 0))) / 2) - 1
  local col = math.floor((cols - self.width) / 2)

  if self.context and ctx_h > 0 then
    local ctx = self:_create_window({
      name = "CodeCompanion_Context",
      width = self.width,
      height = ctx_h,
      row = start_row,
      col = col,
      focusable = false,
      border = "rounded",
      title = " Context ",
      title_pos = "center",
      filetype = "markdown",
      winhighlight = "FloatBorder:" .. HL.HEADER .. ",NormalFloat:Normal",
    })
    self.context_bufnr, self.context_winnr = ctx.bufnr, ctx.winnr
  end

  local q = self:_create_window({
    name = "CodeCompanion_Questions",
    width = self.width,
    height = self.height,
    row = ctx_h > 0 and (start_row + ctx_h + 2) or start_row,
    col = col,
    focusable = true,
    border = "rounded",
    title = " Questions ",
    title_pos = "center",
  })
  self.bufnr, self.winnr = q.bufnr, q.winnr

  self:_setup_keymaps()
  self:_setup_winbar()
  self:render()

  api.nvim_create_autocmd("WinClosed", {
    buffer = self.bufnr,
    once = true,
    callback = function()
      vim.schedule(function()
        if active_form == self and not self.hidden then self:cancel() end
      end)
    end,
  })
end

---Cancel the form and notify callback
---@return nil
function AskUserForm:cancel()
  local callback = self.callback

  self:close()

  if callback then callback({
    status = "cancelled",
    data = "User cancelled the questions form",
  }) end
end

---Reject the form with optional feedback
---@param reason? string Optional reason for rejection
---@return nil
function AskUserForm:reject(reason)
  local callback = self.callback

  self:close()

  if callback then callback({
    status = "rejected",
    data = reason or "User rejected the questions",
  }) end
end

---Setup keymaps for the form buffer
---@return nil
function AskUserForm:_setup_keymaps()
  local opts = { buffer = self.bufnr, nowait = true, silent = true }

  -- stylua: ignore start
  local key = vim.keymap.set
  key("n", "<Tab>",   function() self:next_question() end, opts)
  key("n", "<S-Tab>", function() self:prev_question() end, opts)
  key("n", "j",       function() self:next_choice() end,   opts)
  key("n", "<Down>",  function() self:next_choice() end,   opts)
  key("n", "k",       function() self:prev_choice() end,   opts)
  key("n", "<Up>",    function() self:prev_choice() end,   opts)
  key("n", "<CR>",    function() self:handle_select() end, opts)
  key("n", "<Space>", function() self:handle_select() end, opts)
  key("n", "q",       function() self:cancel() end,        opts)
  key("n", "S",       function() self:submit() end,        opts)
  key("n", "<C-s>",   function() self:submit() end,        opts)
  key("n", "H",       function() self:hide() end,          opts)
  -- stylua: ignore end

  key("n", "R", function()
    local form = self
    vim.ui.input({
      prompt = "Rejection reason (optional): ",
    }, function(input)
      if input == nil then return end
      form:reject(input ~= "" and input or nil)
    end)
  end, opts)
end

---Show the form in a floating window
---@return nil
function AskUserForm:show()
  if active_form then active_form:close() end
  active_form = self

  local ok, notify_ctrl = pcall(require, "hive.notify_controller")
  if ok then
    local instance = notify_ctrl.instance()
    if instance then
      local preview = self.context or (self.questions[1] and self.questions[1].question) or "Agent is asking a question"
      instance:notify("question", preview)
    end
  end

  self:_open()
end

---Format answers for LLM consumption
---@param questions AskUserQuestion[]
---@param answers table<string, string|string[]>
---@return string
local function format_answers_for_llm(questions, answers)
  local parts = {}

  for _, q in ipairs(questions) do
    local answer = answers[q.id]
    local answer_str

    if type(answer) == "table" then
      if #answer == 0 then
        answer_str = "(no selection)"
      else
        answer_str = table.concat(answer, ", ")
      end
    else
      answer_str = answer or "(not answered)"
    end

    table.insert(parts, fmt("Q: %s\nA: %s", q.question, answer_str))
  end

  return table.concat(parts, "\n\n")
end

---Setup chat buffer keymap for toggling the ask_user form
---Called from agents/init.lua during setup
---@return nil
local function setup_chat_keymap()
  local hive_config = require("hive.config")

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local keymaps = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.keymaps
  if not keymaps then return end

  local modes = hive_config.keymap_modes("toggle_ask_user")
  if not modes then return end

  keymaps["toggle_ask_user"] = {
    modes = modes,
    index = 55,
    description = "[Ask] Toggle ask_user form",
    callback = function()
      if not toggle_form() then notify("No active ask_user form", vim.log.levels.INFO) end
    end,
  }
end

setup_chat_keymap()

---@class CodeCompanion.Tool.AskUser: CodeCompanion.Tools.Tool
return {
  name = "ask_user",
  cmds = {
    ---Execute the ask_user tool
    ---@param tools CodeCompanion.Tools
    ---@param args table
    ---@param opts table
    compat.cmds(function(tools, args, opts)
      local output_handler = opts.output_cb
      if not tools or not tools.chat then
        log:error("[AskUser] No chat context available")
        return {
          status = "error",
          data = "No chat context available",
        }
      end

      local questions = args.questions
      if not questions or #questions == 0 then
        return {
          status = "error",
          data = "No questions provided",
        }
      end

      log:debug("[AskUser] Showing %d questions to user", #questions)

      vim.schedule(function()
        local form = AskUserForm.new({
          questions = questions,
          context = args.context,
          callback = function(result)
            if not output_handler then return end
            if result.status == "success" then
              local formatted = format_answers_for_llm(questions, result.data)
              output_handler({
                status = "success",
                data = formatted,
              })
            elseif result.status == "rejected" then
              -- Route rejection as error through output_cb (matching insert_edit_into_file pattern).
              -- The runner only recognizes "error" and "success" statuses — "rejected" falls
              -- through to orchestrator:success() which incorrectly shows "Questions answered".
              local reason = result.data or "User rejected the questions"
              output_handler({
                status = "error",
                data = fmt("rejected: %s", reason),
              })
            else
              -- Cancelled or error
              output_handler({
                status = "error",
                data = result.data or "User cancelled",
              })
            end
          end,
        })
        form:show()
      end)

      return nil
    end),
  },
  env = {
    ---Check if the result is a rejection
    ---@param result { status: string, data: any }
    ---@return boolean
    is_rejected = function(result)
      return result and result.status == "rejected"
    end,

    ---Get rejection reason if rejected
    ---@param result { status: string, data: any }
    ---@return string|nil
    get_rejection_reason = function(result)
      if result and result.status == "rejected" then return result.data end
      return nil
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "ask_user",
      description = [[
Use this `ask_user` tool when clarification is required to continue execution or planning.

If a small clarification would unblock progress → CALL THIS TOOL.  
DO NOT end the agent loop.

Use ONLY when:
- Scope is ambiguous
- Multiple valid approaches exist
- Critical context is missing
- Significant changes require confirmation

Keep questions minimal (1–5).  
Each question MUST affect execution.
Text type MUST use empty choices: []
Mark only essential questions as required
Keep wording minimal

If using only `choice` or `multi_choice`, INCLUDE at least ONE `text` question so the user can provide additional input.


## Example
{
  "context": "I need clarification before proceeding with the refactor.",
  "questions": [
    {
      "id": "scope",
      "question": "Which parts should be refactored?",
      "type": "multi_choice",
      "choices": ["Login flow", "Session management", "OAuth"],
      "required": true
    },
    {
      "id": "priority",
      "question": "What is the main goal?",
      "type": "choice",
      "choices": ["Security", "Performance", "Maintainability"],
      "required": true
    },
    {
      "id": "notes",
      "question": "Any additional constraints or preferences?",
      "type": "text",
      "choices": [],
      "required": false
    }
  ]
}
]],
      parameters = {
        type = "object",
        properties = {
          context = {
            type = "string",
            description = "Optional context explaining why you're asking these questions",
          },
          questions = {
            type = "array",
            description = "Array of questions to ask the user",
            items = {
              type = "object",
              properties = {
                id = {
                  type = "string",
                  description = "Unique identifier for this question (used to match answers)",
                },
                question = {
                  type = "string",
                  description = "The question text to display to the user",
                },
                type = {
                  type = "string",
                  enum = { "text", "choice", "multi_choice" },
                  description = "Question type: 'text' for free-form input, 'choice' for single selection, 'multi_choice' for multiple selections",
                },
                choices = {
                  type = "array",
                  items = { type = "string" },
                  description = "Available choices (required for 'choice' and 'multi_choice' types)",
                },
                required = {
                  type = "boolean",
                  description = "Whether the user must answer this question (default: false)",
                },
              },
              required = { "id", "question", "type", "choices", "required" },
              additionalProperties = false,
            },
          },
        },
        required = { "context", "questions" },
        additionalProperties = false,
      },
    },
  },
  system_prompt = [[
You have access to the questions tool named `ask_user` tool to ask the user clarifying questions.

WHEN TO USE:
- Before large refactors: Ask about scope, priorities, constraints
- Ambiguous requests: Clarify what exactly the user wants
- Multiple valid approaches: Let user choose their preference
- Missing context: Ask for information you need

If clarification is required, you MUST use the `ask_user` tool.  
NEVER ask questions in chat and stop.  
A minor clarification is NOT a reason to end the loop — use the tool and continue.
]],
  handlers = {
    ---Setup handler called before tool execution
    ---@param self CodeCompanion.Tools.Tool
    ---@param meta table
    setup = compat.handler_setup(function(self, meta)
      log:debug("[AskUser] Setup called")
    end),

    ---Called when tool execution completes
    ---@param self CodeCompanion.Tools.Tool
    ---@param meta table
    on_exit = compat.handler_on_exit(function(self, meta)
      log:debug("[AskUser] on_exit called")
      -- Cleanup if form is still active
      if active_form then active_form:close() end
    end),
  },
  output = {
    ---Format the success message
    ---@param self CodeCompanion.Tools.Tool
    ---@param stdout table
    ---@param meta table
    success = compat.output_success(function(self, stdout, meta)
      local chat = meta.tools.chat
      -- stdout is self.tool_output which contains the data we passed to output_handler
      local output = vim.iter(stdout):flatten():join("\n")

      local llm_output = fmt(
        [[<user_responses>
%s
</user_responses>

The user has answered your questions. Use their responses to proceed with the task appropriately.]],
        output
      )

      local user_output = "✓ Questions answered"

      chat:add_tool_output(self, llm_output, user_output)
    end),

    ---Format the error message
    ---@param self CodeCompanion.Tools.Tool
    ---@param stderr table
    ---@param meta table
    error = compat.output_error(function(self, stderr, meta)
      local chat = meta.tools.chat
      local error_msg = vim.iter(stderr):flatten():join("\n")

      if error_msg:match("^rejected:") then
        local reason = error_msg:gsub("^rejected:%s*", "")
        local llm_output = fmt(
          'The user rejected the questions, with the reason: "%s". '
            .. "Consider rephrasing, simplifying, or proceeding with reasonable defaults.",
          reason
        )
        local user_output = "✗ Questions rejected"
        chat:add_tool_output(self, llm_output, user_output)
      elseif error_msg:match("[Cc]ancelled") then
        local llm_output =
          "The user cancelled the questions form. They may not want to answer right now. Consider proceeding with reasonable defaults or rephrasing your questions."
        local user_output = "✗ Questions cancelled"
        chat:add_tool_output(self, llm_output, user_output)
      else
        chat:add_tool_output(self, fmt("Error asking user questions: %s", error_msg))
      end
    end),
  },
  opts = {
    requires_approval = false,
  },
}
