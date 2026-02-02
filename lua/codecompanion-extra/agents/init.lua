-- Agents module for codecompanion-extra
-- Provides agent system that configures tool sets, system prompts, and behavior options
-- Agents can be activated via keymaps, subagents can be spawned via task tool

local M = {}

local fmt = string.format

---@type table<string, CodeCompanionExtra.Agent>
M._agents = {}

---@type table<number, string> bufnr → agent_name
M._chat_agents = {}

---@type table
M._config = {}

---@type table Original tool opts to restore when deactivating
M._original_tool_opts = nil

---Initialize agents with configuration
---@param config table
function M.setup(config)
  M._config = config or {}

  local registry = require("codecompanion-extra.agents.registry")
  M._agents = registry.get_all()

  if M._config.definitions then
    for name, agent in pairs(M._config.definitions) do
      M._agents[name] = vim.tbl_deep_extend("force", M._agents[name] or {}, agent)
    end
  end

  local markdown = require("codecompanion-extra.agents.markdown")

  if M._config.load_default_agents ~= false then
    local default_loaded = markdown.load_from_dir(markdown.default_dir())
    M._agents = vim.tbl_deep_extend("force", M._agents, default_loaded)
  end

  if M._config.load_from_dir then
    local loaded = markdown.load_from_dir(M._config.load_from_dir)
    M._agents = vim.tbl_deep_extend("force", M._agents, loaded)
  end

  M._register_agent_groups()
  M._setup_keymap()
  M._setup_todo_keymap()
  M._setup_navigation()
  M._setup_chat_events()
  M._register_extra_tools()
end

---Register each agent as a tool group in codecompanion config
---@private
function M._register_agent_groups()
  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local tools_config = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.tools
  if not tools_config then return end

  if not tools_config.groups then tools_config.groups = {} end

  for name, agent in pairs(M._agents) do
    if agent.tools and #agent.tools > 0 then
      tools_config.groups["agent_" .. name] = {
        description = agent.description or fmt("Agent: %s", name),
        system_prompt = nil,
        tools = vim.deepcopy(agent.tools),
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
      if bufnr then
        local hierarchy = require("codecompanion-extra.agents.hierarchy")

        local session = hierarchy.get_session(bufnr)
        if session and session.status == "running" then
          local cb = hierarchy.pop_pending_callback(bufnr)
          if cb then
            hierarchy.set_status(bufnr, "cancelled")
            cb({
              status = "error",
              data = fmt("Subagent '%s' was closed by user before completion", session.agent_name),
            })
          end
        end

        M._chat_agents[bufnr] = nil
        hierarchy.remove(bufnr)
      end
    end,
  })
end

---Setup single keymap for agent switching
---@private
function M._setup_keymap()
  local keymap_config = M._config.keymap or {}
  local switch_key = keymap_config.switch or { n = "gO" }

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local chat_keymaps = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.keymaps
  if not chat_keymaps then return end

  chat_keymaps["agent_switch"] = {
    modes = switch_key,
    index = 50,
    description = "[Agent] Switch agent",
    callback = function(chat)
      M._switch_agent(chat)
    end,
  }
end

---Setup navigation keymaps
---@private
function M._setup_navigation()
  local navigation = require("codecompanion-extra.agents.navigation")
  navigation.setup()
end

---Setup todo viewer keymap
---@private
function M._setup_todo_keymap()
  local todo = require("codecompanion-extra.tools.todo")
  todo.setup_keymap("gT")
end

---Register extra tools (task, ask_user, skill) globally
---@private
function M._register_extra_tools()
  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local chat_tools = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.tools
  if not chat_tools then return end

  local task_tool = require("codecompanion-extra.tools.task")
  chat_tools["task"] = {
    callback = task_tool,
    description = task_tool.schema and task_tool.schema["function"] and task_tool.schema["function"].description
      or "Delegate tasks to specialized subagents (single or parallel)",
    opts = {},
  }

  local ask_user_tool = require("codecompanion-extra.tools.ask_user")
  chat_tools["ask_user"] = {
    callback = ask_user_tool,
    description = ask_user_tool.schema
        and ask_user_tool.schema["function"]
        and ask_user_tool.schema["function"].description
      or "Ask the user clarifying questions",
    opts = {},
  }

  local skills = require("codecompanion-extra.skills")
  if skills.has_skills() then
    local skill_tool = require("codecompanion-extra.tools.skill")
    chat_tools["skill"] = {
      callback = skill_tool,
      description = skill_tool.schema and skill_tool.schema["function"] and skill_tool.schema["function"].description
        or "Load specialized skill instructions",
      opts = {},
    }
  end

  local list_dir_tool = require("codecompanion-extra.tools.list_directory")
  chat_tools["list_directory"] = {
    callback = list_dir_tool,
    description = list_dir_tool.schema
        and list_dir_tool.schema["function"]
        and list_dir_tool.schema["function"].description
      or "List contents of a directory",
    opts = {},
  }

  local todo = require("codecompanion-extra.tools.todo")
  local todowrite = todo.get_todowrite()
  chat_tools["todowrite"] = {
    callback = todowrite,
    description = todowrite.schema and todowrite.schema["function"] and todowrite.schema["function"].description
      or "Create or update task list",
    opts = {},
  }

  local todoread = todo.get_todoread()
  chat_tools["todoread"] = {
    callback = todoread,
    description = todoread.schema and todoread.schema["function"] and todoread.schema["function"].description
      or "Read current task list",
    opts = {},
  }
end

---Handle agent switching with toggle or select
---@param chat table
function M._switch_agent(chat)
  local primary_agents = {}
  for name, agent in pairs(M._agents) do
    if agent.type == "agent" then table.insert(primary_agents, { name = name, agent = agent }) end
  end

  local agent_count = #primary_agents

  if agent_count == 0 then
    vim.notify("No agents defined", vim.log.levels.WARN)
    return
  end

  local current = M._chat_agents[chat.bufnr]

  if agent_count == 2 and current then
    table.sort(primary_agents, function(a, b)
      return a.name < b.name
    end)

    local next_agent
    if current == primary_agents[1].name then
      next_agent = primary_agents[2].name
    else
      next_agent = primary_agents[1].name
    end

    M.activate(next_agent, chat)
    return
  end

  local items = {}
  for _, entry in ipairs(primary_agents) do
    table.insert(items, {
      name = entry.name,
      description = entry.agent.description or entry.name,
    })
  end
  table.sort(items, function(a, b)
    return a.name < b.name
  end)

  vim.ui.select(items, {
    prompt = "Select Agent:",
    format_item = function(item)
      local prefix = ""
      if current == item.name then prefix = "● " end
      return prefix .. item.name .. " - " .. item.description
    end,
  }, function(choice)
    if choice then M.activate(choice.name, chat) end
  end)
end

---Get an agent definition
---@param name string
---@return CodeCompanionExtra.Agent|nil
function M.get(name)
  return M._agents[name]
end

---List available agents
---@param filter_type? CodeCompanionExtra.AgentType Filter by type ("agent" or "subagent")
---@return string[]
function M.list(filter_type)
  local names = {}
  for name, agent in pairs(M._agents) do
    if not filter_type or agent.type == filter_type then table.insert(names, name) end
  end
  table.sort(names)
  return names
end

---Get active agent name for a chat buffer
---@param bufnr? number Buffer number, defaults to nil
---@return string|nil
function M.active(bufnr)
  if bufnr then return M._chat_agents[bufnr] end
  return nil
end

---Create a new chat with an agent pre-configured
---@param agent_name string
---@return table|nil chat The created chat
function M.create_chat(agent_name)
  local agent = M._agents[agent_name]
  if not agent then
    vim.notify(fmt("Agent '%s' not found", agent_name), vim.log.levels.WARN)
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
    M.activate(agent_name, chat)
  end)

  return chat
end

---Activate an agent on a chat
---@param agent_name string
---@param chat table CodeCompanion.Chat instance
---@param opts? { silent?: boolean } Options (silent suppresses notifications)
---@return boolean success
function M.activate(agent_name, chat, opts)
  opts = opts or {}
  local agent = M._agents[agent_name]
  if not agent then
    if not opts.silent then vim.notify(fmt("Agent '%s' not found", agent_name), vim.log.levels.WARN) end
    return false
  end

  if not chat then
    if not opts.silent then vim.notify("No chat provided to activate agent", vim.log.levels.WARN) end
    return false
  end

  local current_agent = M._chat_agents[chat.bufnr]
  if current_agent == agent_name then
    if not opts.silent then vim.notify(fmt("Agent '%s' already active", agent_name), vim.log.levels.INFO) end
    return true
  end

  M._save_original_opts()

  if current_agent then M._cleanup_current_agent(chat, current_agent) end

  M._apply_agent(chat, agent, agent_name)

  M._chat_agents[chat.bufnr] = agent_name

  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local session = hierarchy.get_session(chat.bufnr)
  if not session then
    hierarchy.create_session({
      bufnr = chat.bufnr,
      agent_name = agent_name,
      agent_type = agent.type,
      description = agent.description,
      hidden = agent.opts and agent.opts.hidden or false,
    })
  else
    hierarchy.update_session_agent(chat.bufnr, agent_name, agent.type)
  end

  local is_subagent = agent.type == "subagent"
  if not opts.silent and not is_subagent then vim.notify(fmt("Agent: %s", agent_name), vim.log.levels.INFO) end

  local navigation = require("codecompanion-extra.agents.navigation")
  navigation.setup_winbar(chat.bufnr, true)

  return true
end

---Save original tool options before modifying
---@private
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

---Cleanup current agent state from chat
---@param chat table
---@param old_agent_name string
---@private
function M._cleanup_current_agent(chat, old_agent_name)
  local group_id = "<group>agent_" .. old_agent_name .. "</group>"
  local old_agent = M._agents[old_agent_name]
  local old_tools = old_agent and old_agent.tools or {}

  local old_tool_ids = {}
  for _, tool_name in ipairs(old_tools) do
    old_tool_ids["<tool>" .. tool_name .. "</tool>"] = true
  end

  if chat.messages then
    chat.messages = vim
      .iter(chat.messages)
      :filter(function(msg)
        if msg._meta and msg._meta.tag == "agent_system_prompt" then return false end
        if msg.context and msg.context.id == group_id then return false end
        if msg._meta and msg._meta.tag == "tool" and msg.context and msg.context.id then
          if old_tool_ids[msg.context.id] then return false end
        end
        if msg._meta and msg._meta.agent == old_agent_name then return false end
        return true
      end)
      :totable()
  end

  if chat.context_items then
    chat.context_items = vim
      .iter(chat.context_items)
      :filter(function(item)
        if item.id == group_id then return false end
        if old_tool_ids[item.id] then return false end
        return true
      end)
      :totable()
  end

  if chat.tool_registry then
    for _, tool_name in ipairs(old_tools) do
      chat.tool_registry.in_use[tool_name] = nil
      local tool_id = "<tool>" .. tool_name .. "</tool>"
      chat.tool_registry.schemas[tool_id] = nil
    end
  end
end

---Apply agent configuration to a chat
---@param chat table
---@param agent CodeCompanionExtra.Agent
---@param agent_name string
---@private
function M._apply_agent(chat, agent, agent_name)
  local opts = agent.opts or {}

  if not opts.include_default_system_prompt then chat:remove_tagged_message("system_prompt_from_config") end

  M._add_agent_tools(chat, agent, agent_name)
  M._apply_agent_system_prompt(chat, agent, agent_name)
  M._apply_agent_opts(agent)

  if chat.context then
    if chat.context.clear_rendered then chat.context:clear_rendered() end
    if chat.context.render then chat.context:render() end
  end
end

---Add agent's tools to the chat using the pre-registered group
---@param chat table
---@param agent CodeCompanionExtra.Agent
---@param agent_name string
---@private
function M._add_agent_tools(chat, agent, agent_name)
  if not agent.tools or #agent.tools == 0 then return end

  local cc_config = require("codecompanion.config")
  local tools_config = cc_config.interactions.chat.tools

  local group_name = "agent_" .. agent_name

  if tools_config.groups and tools_config.groups[group_name] then
    chat.tool_registry:add_group(group_name, tools_config)
  else
    for _, tool_name in ipairs(agent.tools) do
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

    if chat.tool_registry.add_tool_system_prompt then chat.tool_registry:add_tool_system_prompt() end
  end
end

---Get extra tool from codecompanion-extra
---@param tool_name string
---@return table|nil
---@private
function M._get_extra_tool(tool_name)
  local ok, tools = pcall(require, "codecompanion-extra.tools")
  if ok and tools.get then
    local tool_def = tools.get(tool_name)
    if tool_def then
      return {
        callback = function()
          return tool_def
        end,
        description = tool_def.schema and tool_def.schema["function"] and tool_def.schema["function"].description
          or "Custom tool",
      }
    end
  end
  return nil
end

---Apply agent system prompt to chat
---@param chat table
---@param agent CodeCompanionExtra.Agent
---@param agent_name string
---@private
function M._apply_agent_system_prompt(chat, agent, agent_name)
  local opts = agent.opts or {}

  if not opts.include_tools_system_prompt then
    chat:remove_tagged_message("tool_system_prompt")
  else
    if chat.tool_registry and chat.tool_registry.add_tool_system_prompt then
      chat:remove_tagged_message("tool_system_prompt")
      chat.tool_registry:add_tool_system_prompt()
    end
  end

  if agent.system_prompt then
    local prompt
    if type(agent.system_prompt) == "function" then
      prompt = agent.system_prompt(chat)
    else
      prompt = agent.system_prompt
    end

    if prompt and prompt ~= "" then
      local config = require("codecompanion.config")
      chat:add_message({
        role = config.constants.SYSTEM_ROLE,
        content = prompt,
      }, {
        visible = false,
        index = 2,
        _meta = { tag = "agent_system_prompt", agent = agent_name },
      })
    end
  end
end

---Apply agent options to global tool config
---@param agent CodeCompanionExtra.Agent
---@private
function M._apply_agent_opts(agent)
  local opts = agent.opts or {}
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

---Deactivate current agent, restoring defaults
---@param chat table
function M.deactivate(chat)
  local current_agent = M._chat_agents[chat.bufnr]
  if not current_agent then return end

  M._cleanup_current_agent(chat, current_agent)
  M._restore_original_opts()

  chat:set_system_prompt()

  M._chat_agents[chat.bufnr] = nil

  vim.notify("Agent deactivated", vim.log.levels.INFO)
end

---Restore original tool options
---@private
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

---Register a custom agent
---@param name string
---@param agent CodeCompanionExtra.Agent
function M.register(name, agent)
  M._agents[name] = agent
  M._register_agent_groups()
end

return M
