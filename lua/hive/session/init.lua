local api = vim.api

local notify = require("hive.utils.notify")
local snapshot = require("hive.session.snapshot")
local store = require("hive.session.store")

local M = {}

local _initialized = false
local _config = {}
local _saved_chats = {}
local _registered = {}
local _pending_folds = {}
local _chat_session_ids = {}
local _aug_id = nil

local DEFAULT_CONFIG = {
  enabled = true,
  autosave = {
    enabled = true,
    on_done = true,
    on_close = true,
  },
}

---@param lines string[]|nil
---@return string[]
local function _copy_lines(lines)
  return vim.deepcopy(lines or {})
end

---@param input string
---@return string
local function _slug(input)
  local slug = (input or "session"):lower()
  slug = slug:gsub("%s+", "-")
  slug = slug:gsub("[^a-z0-9%-_]", "")
  slug = slug:gsub("%-+", "-")
  slug = slug:gsub("^%-", "")
  slug = slug:gsub("%-$", "")
  return slug ~= "" and slug or "session"
end

---@param session_id? string
---@param data? table
---@return string
local function _make_session_id(session_id, data)
  if session_id and session_id ~= "" then return _slug(session_id) end

  local summary = data and data.session and data.session.summary or "session"
  return string.format("%s-%d", _slug(summary), os.time())
end

---@param chat CodeCompanion.Chat
---@return string|nil
local function _get_draft(chat)
  local ok, parser = pcall(require, "codecompanion.interactions.chat.parser")
  if not ok then return nil end

  local draft = parser.messages(chat, chat.header_line)
  if not draft or type(draft.content) ~= "string" then return nil end
  if vim.trim(draft.content) == "" then return nil end

  return draft.content
end

---@param bufnr number
---@return CodeCompanion.Chat|nil
local function _get_chat(bufnr)
  local ok, codecompanion = pcall(require, "codecompanion")
  if not ok then return nil end

  local chat_ok, chat = pcall(codecompanion.buf_get_chat, bufnr)
  if not chat_ok then return nil end

  return chat
end

---@param adapter_info table|nil
---@return table|nil
local function _resolve_adapter(adapter_info)
  if not adapter_info or adapter_info.type ~= "http" or not adapter_info.name then return nil end

  local ok, adapters = pcall(require, "codecompanion.adapters")
  if not ok then return nil end

  local cc_ok, cc_config = pcall(require, "codecompanion.config")
  if not cc_ok then return nil end

  local adapter_config = cc_config.adapters and cc_config.adapters.http and cc_config.adapters.http[adapter_info.name]
  if not adapter_config then return nil end

  local adapter = adapters.resolve(adapter_config)
  if not adapter then return nil end

  if adapter_info.model and adapter.schema and adapter.schema.model then
    adapter.schema.model.default = adapter_info.model
  end

  return adapter
end

---@param metadata table|nil
---@return table
local function _current_context(metadata)
  local ok, context_utils = pcall(require, "codecompanion.utils.context")
  if not ok then
    return metadata
      or {
        bufnr = api.nvim_get_current_buf(),
        path = api.nvim_buf_get_name(api.nvim_get_current_buf()),
      }
  end

  local current_bufnr = api.nvim_get_current_buf()
  if metadata and type(metadata.source_bufnr) == "number" and api.nvim_buf_is_valid(metadata.source_bufnr) then
    current_bufnr = metadata.source_bufnr
  end

  return context_utils.get(current_bufnr)
end

---@param data table
---@param key? string
---@return table
local function _node_data(data, key)
  if data.tree and data.tree.nodes then
    local node_key = key or data.tree.current_key
    if node_key and data.tree.nodes[node_key] then return data.tree.nodes[node_key] end
  end

  return {
    adapter = data.adapter,
    chat = data.chat,
    draft = data.draft,
    messages = data.messages,
    settings = data.settings,
    context_items = data.context_items,
    tool_registry = data.tool_registry,
    ui = data.ui,
    metadata = data.metadata,
    hierarchy = data.hierarchy,
  }
end

---@param node table
---@return table[]
local function _restore_messages(node)
  return vim.deepcopy(node.messages or {})
end

---@param chat CodeCompanion.Chat
---@param node table
local function _restore_buffer(chat, node)
  local buffer_lines = node.chat and node.chat.buffer_lines
  if type(buffer_lines) ~= "table" or vim.tbl_isempty(buffer_lines) then return end

  chat.ui:unlock_buf()
  api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, _copy_lines(buffer_lines))
  chat.ui:render_headers()
end

---@param chat CodeCompanion.Chat
local function _restore_pending_folds(chat)
  local folds = _pending_folds[chat.bufnr]
  if type(folds) ~= "table" or vim.tbl_isempty(folds) then return end

  _pending_folds[chat.bufnr] = nil

  vim.schedule(function()
    if not api.nvim_buf_is_valid(chat.bufnr) then return end

    local fold_ui = chat.ui and chat.ui.folds
    if not fold_ui then return end

    if chat.ui.winnr and api.nvim_win_is_valid(chat.ui.winnr) then fold_ui:setup(chat.ui.winnr) end

    fold_ui:cleanup(chat.bufnr)

    for _, fold in ipairs(folds) do
      if fold.type == "tool" and fold.start_row == fold.end_row then
        fold_ui:create_tool_fold(chat.bufnr, fold.start_row, fold.end_row, fold.content or "")
      elseif fold.type == "tool" then
        fold_ui:create_tool_fold(chat.bufnr, fold.start_row, fold.end_row, fold.content or "")
      elseif fold.type == "context" then
        fold_ui:create_context_fold(chat.bufnr, fold.start_row, fold.end_row, fold.content or "")
      elseif fold.type == "reasoning" and fold.end_row > fold.start_row then
        fold_ui:recreate(chat.bufnr, fold.start_row, fold.end_row, {
          type = "reasoning",
          content = fold.content or "",
        })
      end
    end
  end)
end

---@param chat CodeCompanion.Chat
---@param node table
local function _rehydrate_tools(chat, node)
  if not chat.tool_registry or not node.tool_registry then return end

  local ok_cc, cc_config = pcall(require, "codecompanion.config")
  if not ok_cc then return end
  local tools_config = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.tools
  if not tools_config then return end

  local agent_name = node.chat and node.chat.agent and node.chat.agent.name or nil

  for group_name, _ in pairs(node.tool_registry.groups or {}) do
    if agent_name and group_name == ("agent_" .. agent_name) then
    elseif tools_config.groups and tools_config.groups[group_name] then
      chat.tool_registry:add_group(group_name, { config = tools_config })
    end
  end

  for tool_name, enabled in pairs(node.tool_registry.in_use or {}) do
    if enabled and not chat.tool_registry.in_use[tool_name] then
      local tool_config = tools_config[tool_name]
      if tool_config then chat.tool_registry:add(tool_name, { config = tool_config, visible = false }) end
    end
  end
end

---@param chat CodeCompanion.Chat
---@param node table
local function _rehydrate_agent(chat, node)
  local agent_data = node.chat and node.chat.agent or nil
  if not agent_data or not agent_data.name then return end

  local ok_agents, agents = pcall(require, "hive.agents")
  if not ok_agents then return end

  agents.activate(agent_data.name, chat, { silent = true })
end

---@param chat CodeCompanion.Chat
---@param node table
---@param parent_chat CodeCompanion.Chat|nil
---@param visible boolean
local function _ensure_hierarchy_session(chat, node, parent_chat, visible)
  local hierarchy_data = node.hierarchy
  if not hierarchy_data or not hierarchy_data.agent_name then return end

  local ok_hierarchy, hierarchy = pcall(require, "hive.agents.hierarchy")
  if not ok_hierarchy then return end

  local session = hierarchy.get_session(chat.bufnr)
  if not session then
    session = hierarchy.create_session({
      bufnr = chat.bufnr,
      parent_bufnr = parent_chat and parent_chat.bufnr or nil,
      agent_name = hierarchy_data.agent_name,
      agent_type = hierarchy_data.agent_type,
      description = hierarchy_data.description,
      hidden = visible and false or hierarchy_data.hidden,
    })
  end

  session.id = hierarchy_data.id or session.id
  session.description = hierarchy_data.description or session.description
  session.agent_name = hierarchy_data.agent_name or session.agent_name
  session.agent_type = hierarchy_data.agent_type or session.agent_type
  session.status = hierarchy_data.status or session.status
  session.created_at = hierarchy_data.created_at or session.created_at
  session.started_at = hierarchy_data.started_at
  session.completed_at = hierarchy_data.completed_at
  session.duration_ms = hierarchy_data.duration_ms
  session.result = hierarchy_data.result
  session.tool_progress = vim.deepcopy(hierarchy_data.tool_progress or {})
  session.tool_count = hierarchy_data.tool_count or 0
  session.current_tool = hierarchy_data.current_tool
  session.hidden = visible and false or hierarchy_data.hidden

  if visible then
    hierarchy.show(chat.bufnr)
  elseif hierarchy_data.hidden then
    hierarchy.hide(chat.bufnr)
  end
end

---@param chat CodeCompanion.Chat
---@param node table
local function _apply_runtime_state(chat, node)
  chat.messages = _restore_messages(node)
  chat.cycle = (node.chat and node.chat.cycle) or chat.cycle or 1
  chat.header_line = (node.chat and node.chat.header_line) or chat.header_line
  chat._last_role = (node.chat and node.chat.last_role) or chat._last_role
  chat.context_items = vim.deepcopy(node.context_items or {})

  if chat.builder and node.chat and node.chat.builder_state then
    chat.builder.state = vim.deepcopy(node.chat.builder_state)
  end

  if chat.ui and node.ui and type(node.ui.tokens) == "number" then chat.ui.tokens = node.ui.tokens end

  _pending_folds[chat.bufnr] = vim.deepcopy(node.ui and node.ui.folds or {})

  _restore_buffer(chat, node)
  chat:update_metadata()
  _saved_chats[chat.id] = _chat_session_ids[chat.id]

  if chat.ui and chat.ui:is_visible() then _restore_pending_folds(chat) end
end

---@param node table
---@param parent_chat CodeCompanion.Chat|nil
---@param visible boolean
---@return CodeCompanion.Chat|nil, string|nil
local function _restore_node(node, parent_chat, visible)
  if not node.adapter or node.adapter.type ~= "http" then return nil, "Only HTTP chats are supported" end

  local adapter = _resolve_adapter(node.adapter)
  if not adapter then return nil, "Could not resolve saved adapter: " .. tostring(node.adapter.name) end

  local ok, Chat = pcall(require, "codecompanion.interactions.chat")
  if not ok then return nil, "CodeCompanion is not available" end

  local restored = Chat.new({
    adapter = adapter,
    auto_submit = false,
    buffer_context = _current_context(node.metadata),
    hidden = not visible,
    messages = _restore_messages(node),
    settings = node.settings,
    stop_context_insertion = true,
    title = node.chat and node.chat.title or nil,
    window_opts = node.ui and node.ui.window_opts or nil,
  })
  if not restored then return nil, "Failed to create restored chat" end

  _ensure_hierarchy_session(restored, node, parent_chat, visible)
  _rehydrate_agent(restored, node)
  _rehydrate_tools(restored, node)
  _apply_runtime_state(restored, node)
  M.register_chat(restored)

  return restored, nil
end

---@param data table
---@return string[]
local function _restore_order(data)
  if data.tree and type(data.tree.order) == "table" and not vim.tbl_isempty(data.tree.order) then
    return vim.deepcopy(data.tree.order)
  end
  return { "current" }
end

---@param chat CodeCompanion.Chat
function M.register_chat(chat)
  if not chat or not chat.id or _registered[chat.id] then return end

  chat:add_callback("on_completed", function(c)
    if not (_config.autosave and _config.autosave.enabled and _config.autosave.on_done) then return end
    M.save_chat(c, { silent = true, session_id = _chat_session_ids[c.id] })
  end)

  chat:add_callback("on_closed", function(c)
    if not (_config.autosave and _config.autosave.enabled and _config.autosave.on_close) then return end
    M.save_chat(c, { silent = true, session_id = _chat_session_ids[c.id] })
    _registered[c.id] = nil
    _chat_session_ids[c.id] = nil
    _pending_folds[c.bufnr] = nil
  end)

  _registered[chat.id] = true
end

---@param chat CodeCompanion.Chat
---@param opts? { session_id?: string, silent?: boolean }
---@return string|nil, string|nil
function M.save_chat(chat, opts)
  opts = opts or {}
  if not chat or not chat.adapter or chat.adapter.type ~= "http" then return nil, "Only HTTP chats are supported" end

  local existing_id = _saved_chats[chat.id] or _chat_session_ids[chat.id]
  local saved_at = os.time()
  local draft = _get_draft(chat)
  local data = snapshot.capture(chat, {
    draft = draft,
    saved_at = saved_at,
    session_id = opts.session_id or existing_id,
  })
  local session_id = _make_session_id(opts.session_id or existing_id, data)
  data.session.id = session_id
  data.session.saved_at = saved_at

  store.write(session_id, data)
  _saved_chats[chat.id] = session_id
  _chat_session_ids[chat.id] = session_id

  if not opts.silent then notify("Saved chat session: " .. (data.chat.title or data.session.summary)) end

  return session_id, nil
end

---@param bufnr? number
---@param opts? { session_id?: string, silent?: boolean }
---@return string|nil, string|nil
function M.save_current(bufnr, opts)
  local chat = _get_chat(bufnr or 0)
  if not chat then return nil, "No active CodeCompanion chat" end
  return M.save_chat(chat, opts)
end

---@return table[]
function M.list()
  return store.list()
end

---@param session_id string
---@param opts? { silent?: boolean }
---@return CodeCompanion.Chat|nil, string|nil
function M.restore(session_id, opts)
  opts = opts or {}

  local data, err = store.read(session_id)
  if not data then return nil, err end

  local restored_by_key = {}
  local order = _restore_order(data)
  local current_key = data.tree and data.tree.current_key or "current"

  for _, key in ipairs(order) do
    local node = _node_data(data, key)
    local parent_key = node.hierarchy and node.hierarchy.parent_key or nil
    local parent_chat = parent_key and restored_by_key[parent_key] or nil
    local restored, restore_err = _restore_node(node, parent_chat, key == current_key)
    if not restored then return nil, restore_err end

    _chat_session_ids[restored.id] = session_id
    _saved_chats[restored.id] = session_id
    restored_by_key[key] = restored
  end

  local restored = restored_by_key[current_key]
  if not restored then return nil, "Failed to restore current chat" end

  if not opts.silent then notify("Restored chat session: " .. (data.chat.title or data.session.summary)) end

  return restored, nil
end

---@param opts? { prompt?: string }
function M.restore_picker(opts)
  opts = opts or {}
  local sessions = M.list()
  if vim.tbl_isempty(sessions) then
    notify("No saved chat sessions found", vim.log.levels.INFO)
    return
  end

  vim.ui.select(sessions, {
    prompt = opts.prompt or "Restore Hive Session",
    format_item = function(item)
      local when = item.saved_at and os.date("%Y-%m-%d %H:%M", item.saved_at) or "unknown"
      local model = item.model and (" · " .. item.model) or ""
      return string.format("[%s] %s%s", when, item.title or item.summary or item.id, model)
    end,
  }, function(choice)
    if not choice then return end
    local _, restore_err = M.restore(choice.id)
    if restore_err then notify(restore_err, vim.log.levels.ERROR) end
  end)
end

function M.setup_commands()
  api.nvim_create_user_command("HiveSessionSave", function(args)
    local _, err = M.save_current(0, { session_id = args.args ~= "" and args.args or nil })
    if err then notify(err, vim.log.levels.ERROR) end
  end, {
    desc = "Save current CodeCompanion chat as a Hive session",
    nargs = "?",
  })

  api.nvim_create_user_command("HiveSessionRestore", function(args)
    if args.args ~= "" then
      local _, err = M.restore(args.args)
      if err then notify(err, vim.log.levels.ERROR) end
      return
    end

    M.restore_picker()
  end, {
    desc = "Restore a saved Hive chat session",
    nargs = "?",
  })

  api.nvim_create_user_command("HiveSessionDelete", function(args)
    if args.args == "" then
      notify("Provide a session id to delete", vim.log.levels.WARN)
      return
    end

    if store.delete(args.args) then
      notify("Deleted session: " .. args.args)
      return
    end

    notify("Session not found: " .. args.args, vim.log.levels.WARN)
  end, {
    desc = "Delete a saved Hive chat session",
    nargs = 1,
    complete = function()
      return vim.tbl_map(function(item)
        return item.id
      end, M.list())
    end,
  })
end

function M.setup_events()
  if _aug_id then return end

  _aug_id = api.nvim_create_augroup("HiveSessions", { clear = true })

  api.nvim_create_autocmd("User", {
    pattern = { "CodeCompanionChatCreated", "CodeCompanionChatOpened" },
    group = _aug_id,
    callback = function(event)
      local bufnr = event.data and event.data.bufnr
      if not bufnr then return end
      local chat = _get_chat(bufnr)
      if not chat then return end
      M.register_chat(chat)
      _restore_pending_folds(chat)
    end,
  })
end

---@param config? table
function M.setup(config)
  if _initialized then return end

  _config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_CONFIG), config or {})
  if not _config.enabled then return end

  M.setup_commands()
  M.setup_events()
  _initialized = true
end

return M
