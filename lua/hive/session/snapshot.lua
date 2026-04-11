local api = vim.api
local config = require("codecompanion.config")

local M = {}

M.VERSION = 2

---@param value any
---@return any
local function _copy(value)
  local value_type = type(value)

  if value_type == "function" or value_type == "userdata" or value_type == "thread" then return nil end

  if value_type ~= "table" then return value end

  local copy = {}
  for key, item in pairs(value) do
    local key_type = type(key)
    if key_type == "string" or key_type == "number" or key_type == "boolean" then
      local copied_item = _copy(item)
      if copied_item ~= nil then copy[key] = copied_item end
    end
  end

  return copy
end

---@param title string|nil
---@param messages table[]
---@return string
local function _summary(title, messages)
  if type(title) == "string" and vim.trim(title) ~= "" then return vim.trim(title) end

  for _, message in ipairs(messages or {}) do
    if message.role == config.constants.USER_ROLE and type(message.content) == "string" then
      local summary = vim.trim((message.content:gsub("%s+", " ")))
      if summary ~= "" then
        if #summary > 80 then return summary:sub(1, 77) .. "..." end
        return summary
      end
    end
  end

  return "Untitled chat"
end

---@param chat CodeCompanion.Chat
---@return string|nil
local function _model(chat)
  if not chat.adapter or chat.adapter.type ~= "http" then return nil end

  if chat.settings and chat.settings.model then return chat.settings.model end

  local model = chat.adapter.schema and chat.adapter.schema.model
  if type(model) == "table" then return model.default or model.name or model.id or model.model end

  return model
end

---@param chat CodeCompanion.Chat
---@return table[]
local function _capture_folds(chat)
  local fold_summaries = chat.ui and chat.ui.folds and chat.ui.folds.fold_summaries[chat.bufnr]
  if type(fold_summaries) ~= "table" then return {} end

  local starts = vim.tbl_keys(fold_summaries)
  table.sort(starts)

  local folds = {}
  local line_count = vim.api.nvim_buf_line_count(chat.bufnr)

  for index, start_row in ipairs(starts) do
    local summary = fold_summaries[start_row]
    local next_start = starts[index + 1]
    local end_row = nil

    local ok_end, value = pcall(api.nvim_buf_call, chat.bufnr, function()
      local fold_end = vim.fn.foldclosedend(start_row + 1)
      if type(fold_end) == "number" and fold_end > 0 then return fold_end - 1 end
      return nil
    end)
    if ok_end then end_row = value end

    if end_row == nil and next_start then end_row = next_start - 1 end
    if end_row == nil then end_row = start_row end
    if end_row >= line_count then end_row = math.max(line_count - 1, start_row) end

    table.insert(folds, {
      start_row = start_row,
      end_row = end_row,
      content = summary.content,
      type = summary.type,
    })
  end

  return folds
end

---@param chat CodeCompanion.Chat
---@param session table|nil
---@param draft string|nil
---@return table
local function _capture_node(chat, session, draft)
  local messages = _copy(chat.messages or {})
  local title = chat.title
  local buffer_lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)
  local builder_state = _copy(chat.builder and chat.builder.state or {})

  local agent_name
  local ok_agents, agents = pcall(require, "hive.agents")
  if ok_agents then agent_name = agents.active(chat.bufnr) end

  return {
    adapter = {
      type = chat.adapter and chat.adapter.type or nil,
      name = chat.adapter and chat.adapter.name or nil,
      model = _model(chat),
    },
    chat = {
      title = title,
      cycle = chat.cycle or 1,
      intro_message = chat.intro_message,
      last_role = chat._last_role,
      header_line = chat.header_line,
      builder_state = builder_state,
      buffer_lines = buffer_lines,
      agent = agent_name and {
        name = agent_name,
      } or nil,
    },
    draft = draft,
    messages = messages,
    settings = _copy(chat.settings),
    context_items = _copy(chat.context_items or {}),
    tool_registry = {
      flags = _copy(chat.tool_registry and chat.tool_registry.flags or {}),
      groups = _copy(chat.tool_registry and chat.tool_registry.groups or {}),
      in_use = _copy(chat.tool_registry and chat.tool_registry.in_use or {}),
      schemas = _copy(chat.tool_registry and chat.tool_registry.schemas or {}),
    },
    ui = {
      tokens = chat.ui and chat.ui.tokens or 0,
      window_opts = _copy(chat.ui and chat.ui.window_opts or nil),
      folds = _capture_folds(chat),
    },
    metadata = {
      cwd = vim.fn.getcwd(),
      source_bufnr = chat.buffer_context and chat.buffer_context.bufnr or nil,
      source_path = chat.buffer_context and chat.buffer_context.path or nil,
    },
    hierarchy = session and {
      id = session.id,
      agent_name = session.agent_name,
      agent_type = session.agent_type,
      description = session.description,
      status = session.status,
      hidden = session.hidden,
      created_at = session.created_at,
      started_at = session.started_at,
      completed_at = session.completed_at,
      duration_ms = session.duration_ms,
      result = session.result,
      tool_progress = _copy(session.tool_progress),
      tool_count = session.tool_count,
      current_tool = session.current_tool,
    } or nil,
  }
end

---@param root_chat CodeCompanion.Chat
---@param current_chat CodeCompanion.Chat
---@param draft string|nil
---@return table|nil
local function _capture_tree(root_chat, current_chat, draft)
  local ok_hierarchy, hierarchy = pcall(require, "hive.agents.hierarchy")
  local ok_codecompanion, codecompanion = pcall(require, "codecompanion")
  if not ok_hierarchy or not ok_codecompanion then return nil end

  if type(hierarchy.get_root) ~= "function" or type(hierarchy.get_tree) ~= "function" then return nil end

  local root_bufnr = hierarchy.get_root(current_chat.bufnr)
  local tree_bufnrs = hierarchy.get_tree(root_bufnr)
  if #tree_bufnrs <= 1 then return nil end

  local nodes = {}
  local order = {}

  for _, bufnr in ipairs(tree_bufnrs) do
    local chat = codecompanion.buf_get_chat(bufnr)
    if chat then
      local session = hierarchy.get_session(bufnr)
      local node_key = tostring(bufnr)
      local node_draft = bufnr == current_chat.bufnr and draft or nil
      local node = _capture_node(chat, session, node_draft)

      if node.hierarchy and session then
        node.hierarchy.parent_key = session.parent_bufnr and tostring(session.parent_bufnr) or nil
        node.hierarchy.children_keys = vim.tbl_map(function(child_bufnr)
          return tostring(child_bufnr)
        end, session.children or {})
      end

      nodes[node_key] = node
      table.insert(order, node_key)
    end
  end

  if vim.tbl_isempty(nodes) then return nil end

  return {
    root_key = tostring(root_chat.bufnr),
    current_key = tostring(current_chat.bufnr),
    order = order,
    nodes = nodes,
  }
end

---@param chat CodeCompanion.Chat
---@param opts? { draft?: string, saved_at?: integer, session_id?: string }
---@return table
function M.capture(chat, opts)
  opts = opts or {}

  local ok_hierarchy, hierarchy = pcall(require, "hive.agents.hierarchy")
  local session = ok_hierarchy and type(hierarchy.get_session) == "function" and hierarchy.get_session(chat.bufnr)
    or nil
  local root_bufnr = ok_hierarchy and type(hierarchy.get_root) == "function" and hierarchy.get_root(chat.bufnr)
    or chat.bufnr

  local root_chat = chat
  if root_bufnr ~= chat.bufnr then
    local ok_codecompanion, codecompanion = pcall(require, "codecompanion")
    if ok_codecompanion then root_chat = codecompanion.buf_get_chat(root_bufnr) or chat end
  end

  local current_node = _capture_node(chat, session, opts.draft)
  local tree = _capture_tree(root_chat, chat, opts.draft)

  return {
    version = M.VERSION,
    session = {
      id = opts.session_id,
      saved_at = opts.saved_at or os.time(),
      summary = _summary(current_node.chat.title, current_node.messages),
    },
    adapter = current_node.adapter,
    chat = current_node.chat,
    draft = current_node.draft,
    messages = current_node.messages,
    settings = current_node.settings,
    context_items = current_node.context_items,
    tool_registry = current_node.tool_registry,
    ui = current_node.ui,
    metadata = current_node.metadata,
    hierarchy = current_node.hierarchy,
    tree = tree,
  }
end

return M
