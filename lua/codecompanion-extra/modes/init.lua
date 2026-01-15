-- Modes module for codecompanion-extra
-- Provides agent modes that configure tool sets, system prompts, and behavior options
-- Modes can be activated via keymaps to switch chat behavior on-the-fly
-- Modes can also create new chats with pre-configured tools via commands

local M = {}

local fmt = string.format

---@class CodeCompanionExtra.Mode
---@field description string
---@field tools string[]
---@field system_prompt? string|fun(chat: table): string
---@field opts? CodeCompanionExtra.ModeOpts

---@class CodeCompanionExtra.ModeOpts
---@field include_default_system_prompt? boolean
---@field include_tools_system_prompt? boolean
---@field auto_submit_errors? boolean
---@field auto_submit_success? boolean

---@type table<string, CodeCompanionExtra.Mode>
M._modes = {}

---@type string|nil
M._active_mode = nil

---@type table
M._config = {}

---@type table Original tool opts to restore when deactivating
M._original_tool_opts = nil

---@type table<number, string> Track active mode per chat buffer
M._chat_modes = {}

---Get the markdown loader module
---@private
---@return table
function M._get_markdown()
  return require("codecompanion-extra.modes.markdown")
end

---Initialize modes with configuration
---@param config table
function M.setup(config)
  M._config = config or {}
  M._modes = vim.tbl_deep_extend("force", {}, M._config.definitions or {})

  if M._config.load_from_dir then
    local markdown = M._get_markdown()
    local loaded = markdown.load_from_dir(M._config.load_from_dir)
    M._modes = vim.tbl_deep_extend("force", M._modes, loaded)
  end

  M._register_mode_groups()
  M._setup_keymap()
  M._setup_chat_events()
end

---Register each mode as a tool group in codecompanion config
---@private
---NOTE: We set system_prompt = nil here because we handle it separately via mode_system_prompt
function M._register_mode_groups()
  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local tools_config = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.tools
  if not tools_config then return end

  if not tools_config.groups then tools_config.groups = {} end

  for name, mode in pairs(M._modes) do
    if mode.tools and #mode.tools > 0 then
      tools_config.groups["mode_" .. name] = {
        description = mode.description or fmt("Mode: %s", name),
        system_prompt = nil,
        tools = vim.deepcopy(mode.tools),
        opts = {
          collapse_tools = true,
        },
        hide_in_help_window = true,
      }
    end
  end
end

---Setup event listeners for chat lifecycle
---@private
function M._setup_chat_events()
  vim.api.nvim_create_autocmd("User", {
    pattern = "CodeCompanionChatClosed",
    callback = function(event)
      local bufnr = event.data and event.data.bufnr
      if bufnr then M._chat_modes[bufnr] = nil end
    end,
  })
end

---Load modes from a markdown directory
---@param dir string
---@return number count Number of modes loaded
function M.load_from_dir(dir)
  local markdown = M._get_markdown()
  local loaded = markdown.load_from_dir(dir)

  for name, mode in pairs(loaded) do
    M._modes[name] = mode
  end

  M._register_mode_groups()

  return vim.tbl_count(loaded)
end

---Setup single keymap for mode switching
function M._setup_keymap()
  local keymap_config = M._config.keymap or { modes = { n = "gO" }, description = "[Mode] Switch mode" }

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local chat_keymaps = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.keymaps
  if not chat_keymaps then return end

  chat_keymaps["mode_switch"] = {
    modes = keymap_config.modes,
    index = keymap_config.index or 50,
    description = keymap_config.description,
    callback = function(chat)
      M._switch_mode(chat)
    end,
  }
end

---Handle mode switching with toggle or select
---@param chat table
function M._switch_mode(chat)
  local mode_names = vim.tbl_keys(M._modes)
  local mode_count = #mode_names

  if mode_count == 0 then
    vim.notify("No modes defined", vim.log.levels.WARN)
    return
  end

  local current = M._chat_modes[chat.bufnr]

  -- With exactly 2 modes, toggle between them
  if mode_count == 2 and current then
    table.sort(mode_names)
    local next_mode

    if current == mode_names[1] then
      next_mode = mode_names[2]
    else
      next_mode = mode_names[1]
    end

    M.activate(next_mode, chat)
    return
  end

  -- Otherwise show selector
  local items = {}
  for name, mode in pairs(M._modes) do
    table.insert(items, {
      name = name,
      description = mode.description or name,
    })
  end
  table.sort(items, function(a, b)
    return a.name < b.name
  end)

  vim.ui.select(items, {
    prompt = "Select Mode:",
    format_item = function(item)
      local prefix = ""
      if current == item.name then prefix = "● " end
      return prefix .. item.name .. " - " .. item.description
    end,
  }, function(choice)
    if choice then M.activate(choice.name, chat) end
  end)
end

---Get a mode definition
---@param name string
---@return CodeCompanionExtra.Mode|nil
function M.get(name)
  return M._modes[name]
end

---List available modes
---@return string[]
function M.list()
  return vim.tbl_keys(M._modes)
end

---Get active mode name for a chat buffer
---@param bufnr? number Buffer number, defaults to current active mode
---@return string|nil
function M.active(bufnr)
  if bufnr then return M._chat_modes[bufnr] end
  return M._active_mode
end

---Create a new chat with a mode pre-configured
---@param mode_name string
---@return table|nil chat The created chat
function M.create_chat(mode_name)
  local mode = M._modes[mode_name]
  if not mode then
    vim.notify(fmt("Mode '%s' not found", mode_name), vim.log.levels.WARN)
    return nil
  end

  local codecompanion = require("codecompanion")

  local chat = codecompanion.chat({
    auto_submit = false,
  })

  if not chat then
    vim.notify("Failed to create chat", vim.log.levels.ERROR)
    return nil
  end

  vim.schedule(function()
    M.activate(mode_name, chat)
  end)

  return chat
end

---Activate a mode on a chat
---@param mode_name string
---@param chat table CodeCompanion.Chat instance
---@return boolean success
function M.activate(mode_name, chat)
  local mode = M._modes[mode_name]
  if not mode then
    vim.notify(fmt("Mode '%s' not found", mode_name), vim.log.levels.WARN)
    return false
  end

  if not chat then
    vim.notify("No chat provided to activate mode", vim.log.levels.WARN)
    return false
  end

  local current_mode = M._chat_modes[chat.bufnr]
  if current_mode == mode_name then
    vim.notify(fmt("Mode '%s' already active", mode_name), vim.log.levels.INFO)
    return true
  end

  M._save_original_opts()

  if current_mode then M._cleanup_current_mode(chat, current_mode) end

  M._apply_mode(chat, mode, mode_name)

  M._chat_modes[chat.bufnr] = mode_name
  M._active_mode = mode_name

  vim.notify(fmt("Mode: %s", mode_name), vim.log.levels.INFO)
  return true
end

---Save original tool options before modifying
function M._save_original_opts()
  if M._original_tool_opts then return end

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local tools_opts = cc_config.interactions
    and cc_config.interactions.chat
    and cc_config.interactions.chat.tools
    and cc_config.interactions.chat.tools.opts
  if tools_opts then
    M._original_tool_opts = {
      auto_submit_errors = tools_opts.auto_submit_errors,
      auto_submit_success = tools_opts.auto_submit_success,
    }
  end
end

---Cleanup current mode state from chat
---@param chat table
---@param old_mode_name string
function M._cleanup_current_mode(chat, old_mode_name)
  local group_id = "<group>mode_" .. old_mode_name .. "</group>"
  local old_mode = M._modes[old_mode_name]
  local old_tools = old_mode and old_mode.tools or {}

  -- Build set of tool IDs for fast lookup
  local old_tool_ids = {}
  for _, tool_name in ipairs(old_tools) do
    old_tool_ids["<tool>" .. tool_name .. "</tool>"] = true
  end

  -- Remove messages associated with the old mode
  if chat.messages then
    chat.messages = vim
      .iter(chat.messages)
      :filter(function(msg)
        -- Remove mode_system_prompt
        if msg._meta and msg._meta.tag == "mode_system_prompt" then return false end
        -- Remove tool messages that belong to this mode's group
        if msg.context and msg.context.id == group_id then return false end
        -- Remove individual tool system prompt messages from this mode's tools
        if msg._meta and msg._meta.tag == "tool" and msg.context and msg.context.id then
          if old_tool_ids[msg.context.id] then return false end
        end
        -- Remove individual tool messages added by the mode
        if msg._meta and msg._meta.mode == old_mode_name then return false end
        return true
      end)
      :totable()
  end

  -- Remove context items for the old mode's group and its tools
  if chat.context_items then
    chat.context_items = vim
      .iter(chat.context_items)
      :filter(function(item)
        if item.id == group_id then return false end
        -- Remove individual tool context from this mode
        if old_tool_ids[item.id] then return false end
        return true
      end)
      :totable()
  end

  -- Clear tools from registry that were part of the old mode
  if chat.tool_registry then
    for _, tool_name in ipairs(old_tools) do
      chat.tool_registry.in_use[tool_name] = nil
      local tool_id = "<tool>" .. tool_name .. "</tool>"
      chat.tool_registry.schemas[tool_id] = nil
    end
  end
end

---Apply mode configuration to a chat
---@param chat table
---@param mode CodeCompanionExtra.Mode
---@param mode_name string
function M._apply_mode(chat, mode, mode_name)
  local opts = mode.opts or {}

  if not opts.include_default_system_prompt then chat:remove_tagged_message("system_prompt_from_config") end

  M._add_mode_tools(chat, mode, mode_name)
  M._apply_mode_system_prompt(chat, mode, mode_name)
  M._apply_mode_opts(mode)

  -- Refresh context display - clear first then render
  if chat.context then
    if chat.context.clear_rendered then chat.context:clear_rendered() end
    if chat.context.render then chat.context:render() end
  end
end

---Add mode's tools to the chat using the pre-registered group
---@param chat table
---@param mode CodeCompanionExtra.Mode
---@param mode_name string
function M._add_mode_tools(chat, mode, mode_name)
  if not mode.tools or #mode.tools == 0 then return end

  local cc_config = require("codecompanion.config")
  local tools_config = cc_config.interactions.chat.tools

  local group_name = "mode_" .. mode_name

  if tools_config.groups and tools_config.groups[group_name] then
    chat.tool_registry:add_group(group_name, tools_config)
  else
    for _, tool_name in ipairs(mode.tools) do
      if chat.tool_registry.in_use[tool_name] then goto continue end

      local tool_config = tools_config[tool_name]
      if tool_config then
        chat.tool_registry:add(tool_name, tool_config, { visible = false })
      else
        local extra_tool = M._get_extra_tool(tool_name)
        if extra_tool then chat.tool_registry:add(tool_name, extra_tool, { visible = false }) end
      end
      ::continue::
    end
  end
end

---Get extra tool from codecompanion-extra
---@param tool_name string
---@return table|nil
function M._get_extra_tool(tool_name)
  local ok, tools = pcall(require, "codecompanion-extra.tools")
  if ok and tools.get then
    local tool_def = tools.get(tool_name)
    if tool_def then
      return {
        callback = tool_def,
        description = tool_def.schema and tool_def.schema["function"] and tool_def.schema["function"].description
          or "Custom tool",
      }
    end
  end
  return nil
end

---Apply mode system prompt to chat
---@param chat table
---@param mode CodeCompanionExtra.Mode
---@param mode_name string
function M._apply_mode_system_prompt(chat, mode, mode_name)
  local opts = mode.opts or {}

  if not opts.include_tools_system_prompt then
    chat:remove_tagged_message("tool_system_prompt")
  else
    if chat.tool_registry and chat.tool_registry.add_tool_system_prompt then
      chat:remove_tagged_message("tool_system_prompt")
      chat.tool_registry:add_tool_system_prompt()
    end
  end

  if mode.system_prompt then
    local prompt
    if type(mode.system_prompt) == "function" then
      prompt = mode.system_prompt(chat)
    else
      prompt = mode.system_prompt
    end

    if prompt and prompt ~= "" then
      local config = require("codecompanion.config")
      chat:add_message({
        role = config.constants.SYSTEM_ROLE,
        content = prompt,
      }, {
        visible = false,
        index = 2,
        _meta = { tag = "mode_system_prompt", mode = mode_name },
      })
    end
  end
end

---Apply mode options to global tool config
---@param mode CodeCompanionExtra.Mode
function M._apply_mode_opts(mode)
  local opts = mode.opts or {}
  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local tools_opts = cc_config.interactions
    and cc_config.interactions.chat
    and cc_config.interactions.chat.tools
    and cc_config.interactions.chat.tools.opts

  if not tools_opts then return end

  if opts.auto_submit_errors ~= nil then tools_opts.auto_submit_errors = opts.auto_submit_errors end

  if opts.auto_submit_success ~= nil then tools_opts.auto_submit_success = opts.auto_submit_success end
end

---Deactivate current mode, restoring defaults
---@param chat table
function M.deactivate(chat)
  local current_mode = M._chat_modes[chat.bufnr]
  if not current_mode then return end

  M._cleanup_current_mode(chat, current_mode)
  M._restore_original_opts()

  chat:set_system_prompt()

  M._chat_modes[chat.bufnr] = nil
  if M._active_mode == current_mode then M._active_mode = nil end

  vim.notify("Mode deactivated", vim.log.levels.INFO)
end

---Restore original tool options
function M._restore_original_opts()
  if not M._original_tool_opts then return end

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local tools_opts = cc_config.interactions
    and cc_config.interactions.chat
    and cc_config.interactions.chat.tools
    and cc_config.interactions.chat.tools.opts

  if tools_opts then
    tools_opts.auto_submit_errors = M._original_tool_opts.auto_submit_errors
    tools_opts.auto_submit_success = M._original_tool_opts.auto_submit_success
  end

  M._original_tool_opts = nil
end

---Register a custom mode
---@param name string
---@param mode CodeCompanionExtra.Mode
function M.register(name, mode)
  M._modes[name] = mode
  M._register_mode_groups()
end

return M
