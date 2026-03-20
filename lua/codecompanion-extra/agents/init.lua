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

  if M._config.load_cwd_agents ~= false then
    local cwd_agents_dir = vim.fs.joinpath(vim.fn.getcwd(), ".codecompanion", "agents")
    local cwd_loaded = markdown.load_from_dir(cwd_agents_dir)
    M._agents = vim.tbl_deep_extend("force", M._agents, cwd_loaded)
  end

  if M._config.load_from_dir then
    local loaded = markdown.load_from_dir(M._config.load_from_dir)
    M._agents = vim.tbl_deep_extend("force", M._agents, loaded)
  end

  M._register_agent_groups()
  M._setup_keymap()
  M._setup_navigation()
  M._setup_chat_events()
  M._register_extra_tools()
  M._setup_todo_keymap()
  M._setup_model_picker()
  M._setup_debug_keymap()
  M._setup_agent_manager_keymap()
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

---Close all children of a parent chat recursively by calling chat:close() on each
---@param child_bufnrs number[] List of child buffer numbers to close
local function close_children_recursive(child_bufnrs)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local ok, codecompanion = pcall(require, "codecompanion")

  for _, child_bufnr in ipairs(child_bufnrs) do
    local session = hierarchy.get_session(child_bufnr)

    -- Cancel any pending async callback so the task tool doesn't hang
    if session and (session.status == "pending" or session.status == "running") then
      local cb = hierarchy.pop_pending_callback(child_bufnr)
      if cb then
        hierarchy.set_status(child_bufnr, "cancelled")
        cb({
          status = "error",
          data = fmt("Subagent '%s' was closed because parent chat was closed", session.agent_name or "unknown"),
        })
      end
    end

    if session and #session.children > 0 then close_children_recursive(vim.deepcopy(session.children)) end

    if ok then
      local chat_ok, chat = pcall(codecompanion.buf_get_chat, child_bufnr)
      if chat_ok and chat then
        pcall(chat.close, chat)
      elseif vim.api.nvim_buf_is_valid(child_bufnr) then
        pcall(vim.api.nvim_buf_delete, child_bufnr, { force = true })
      end
    elseif vim.api.nvim_buf_is_valid(child_bufnr) then
      pcall(vim.api.nvim_buf_delete, child_bufnr, { force = true })
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
        local children_to_close = session and #session.children > 0 and vim.deepcopy(session.children) or {}

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

        local ok, todo = pcall(require, "codecompanion-extra.tools.todo")
        if ok then todo.clear_todos(bufnr) end

        M._chat_agents[bufnr] = nil
        hierarchy.remove(bufnr)

        if #children_to_close > 0 then
          vim.schedule(function()
            close_children_recursive(children_to_close)
          end)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = { "CodeCompanionChatAdapter", "CodeCompanionChatModel" },
    callback = function(event)
      local bufnr = event.data and event.data.bufnr
      if not bufnr then return end

      local agent_name = M._chat_agents[bufnr]
      if not agent_name then return end

      local agent = M._agents and M._agents[agent_name]
      if not agent then return end

      local ok, codecompanion = pcall(require, "codecompanion")
      if not ok then return end
      local chat_ok, chat = pcall(codecompanion.buf_get_chat, bufnr)
      if not chat_ok or not chat then return end

      local opts = agent.opts or {}
      if not opts.include_default_system_prompt then chat:remove_tagged_message("system_prompt_from_config") end

      chat:remove_tagged_message("agent_system_prompt")
      M._apply_agent_system_prompt(chat, agent, agent_name)
    end,
  })
end

---Setup single keymap for agent switching
---@private
function M._setup_keymap()
  local keymap_config = M._config.keymap or {}
  local switch_key = keymap_config.switch

  if not switch_key then return end

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

  local cycle_key = keymap_config.cycle
  if cycle_key then
    chat_keymaps["agent_cycle"] = {
      modes = cycle_key,
      index = 51,
      description = "[Agent] Cycle to next agent",
      callback = function(chat)
        M._cycle_agent(chat)
      end,
    }
  end
end

---Setup navigation keymaps
---@private
function M._setup_navigation()
  local navigation = require("codecompanion-extra.agents.navigation")
  navigation.setup()

  local prunable_viewer = require("codecompanion-extra.prune.viewer")
  prunable_viewer.setup()
end

---Override debug keymap to inject agent name into the debug window
---@private
function M._setup_debug_keymap()
  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local chat_keymaps = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.keymaps
  if not chat_keymaps or not chat_keymaps["debug"] then return end

  chat_keymaps["debug"].callback = function(chat)
    local settings, messages = chat:debug()
    if not settings and not messages then return end

    local debug_mod = require("codecompanion.interactions.chat.debug")
    local debug_instance = debug_mod.new({ chat = chat, settings = settings })
    debug_instance:render()

    if not debug_instance.bufnr or not vim.api.nvim_buf_is_valid(debug_instance.bufnr) then return end

    local agent_name = M._chat_agents[chat.bufnr]
    if not agent_name then return end

    local lines = vim.api.nvim_buf_get_lines(debug_instance.bufnr, 0, -1, false)
    local insert_idx
    for i, line in ipairs(lines) do
      if line:match("^%-%- Buffer Number:") then
        insert_idx = i
        break
      end
    end

    if insert_idx then
      local agent_def = M._agents[agent_name]
      local agent_line = '-- Agent: "' .. agent_name .. '"'
      if agent_def and agent_def.description then agent_line = agent_line .. " (" .. agent_def.description .. ")" end
      vim.api.nvim_buf_set_lines(debug_instance.bufnr, insert_idx, insert_idx, false, { agent_line })
    end
  end
end

---Setup todo viewer keymap
---@private
function M._setup_todo_keymap()
  local todo = require("codecompanion-extra.tools.todo")
  todo.setup_keymap({ n = { "gT", "st", "]t" } })
end

---Setup agent manager toggle keymap in chat buffer
---@private
function M._setup_agent_manager_keymap()
  local keymap_config = M._config.keymap or {}
  local manager_key = keymap_config.agent_manager
  if not manager_key then return end

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local chat_keymaps = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.keymaps
  if not chat_keymaps then return end

  chat_keymaps["agent_manager"] = {
    modes = manager_key,
    index = 52,
    description = "[Agent] Toggle agent manager",
    callback = function(_chat)
      local agent_manager = require("codecompanion-extra.agent_manager")
      agent_manager.toggle()
    end,
  }
end

---Setup model picker keymap for subagent small/big model assignment
---@private
function M._setup_model_picker()
  local model_picker = require("codecompanion-extra.tools.subagent.model_picker")
  model_picker.setup()
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
    callback = function()
      return task_tool
    end,
    description = task_tool.schema and task_tool.schema["function"] and task_tool.schema["function"].description
      or "Delegate tasks to specialized subagents (single or parallel)",
    opts = {},
  }

  local ask_user_tool = require("codecompanion-extra.tools.ask_user")
  chat_tools["ask_user"] = {
    callback = function()
      return ask_user_tool
    end,
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
      callback = function()
        return skill_tool
      end,
      description = skill_tool.schema and skill_tool.schema["function"] and skill_tool.schema["function"].description
        or "Load specialized skill instructions",
      opts = {},
    }
  end

  local list_dir_tool = require("codecompanion-extra.tools.list_directory")
  chat_tools["list_directory"] = {
    callback = function()
      return list_dir_tool
    end,
    description = list_dir_tool.schema
        and list_dir_tool.schema["function"]
        and list_dir_tool.schema["function"].description
      or "List contents of a directory",
    opts = {},
  }

  local todo = require("codecompanion-extra.tools.todo")
  local todowrite = todo.get_todowrite()
  chat_tools["todowrite"] = {
    callback = function()
      return todowrite
    end,
    description = todowrite.schema and todowrite.schema["function"] and todowrite.schema["function"].description
      or "Create or update task list",
    opts = {},
  }

  local todoread = todo.get_todoread()
  chat_tools["todoread"] = {
    callback = function()
      return todoread
    end,
    description = todoread.schema and todoread.schema["function"] and todoread.schema["function"].description
      or "Read current task list",
    opts = {},
  }

  local consult_tool = require("codecompanion-extra.tools.consult")
  chat_tools["consult"] = {
    callback = function()
      return consult_tool
    end,
    description = consult_tool.schema
        and consult_tool.schema["function"]
        and consult_tool.schema["function"].description
      or "Consult specialist advisors for expert guidance",
    opts = {},
  }

  local cmd_runner_tool = require("codecompanion-extra.tools.cmd_runner")
  chat_tools["cmd_runner"] = {
    callback = function()
      return cmd_runner_tool
    end,
    description = cmd_runner_tool.schema
        and cmd_runner_tool.schema["function"]
        and cmd_runner_tool.schema["function"].description
      or "Run shell commands with timeout and filtering",
    opts = vim.tbl_deep_extend("force", {
      allowed_in_yolo_mode = false,
      require_approval_before = true,
      require_cmd_approval = true,
    }, chat_tools["cmd_runner"] and chat_tools["cmd_runner"].opts or {}),
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

---Cycle to the next primary agent in sorted order
---@param chat table
function M._cycle_agent(chat)
  local primary_agents = {}
  for name, agent in pairs(M._agents) do
    if agent.type == "agent" then table.insert(primary_agents, name) end
  end

  table.sort(primary_agents)

  local count = #primary_agents
  if count == 0 then
    vim.notify("No agents defined", vim.log.levels.WARN)
    return
  end

  local current = M._chat_agents[chat.bufnr]
  local next_idx = 1

  if current then
    for i, name in ipairs(primary_agents) do
      if name == current then
        next_idx = (i % count) + 1
        break
      end
    end
  end

  M.activate(primary_agents[next_idx], chat)
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

---Build a system reminder message for agent mode changes
---@param from_agent string|nil Previous agent name
---@param to_agent string New agent name
---@return string|nil reminder_text
---TODO: move it to new module for maintainability
local function build_agent_change_reminder(from_agent, to_agent)
  if not from_agent then return nil end

  local to_def = M._agents[to_agent]
  if not to_def then return nil end

  local can_edit = to_def.permissions and to_def.permissions.can_edit_files
  local can_run_cmd = to_def.permissions and to_def.permissions.can_run_commands

  local mode_desc
  if can_edit and can_run_cmd then
    mode_desc = [[You are no longer in read-only mode.
You are permitted to make file changes, run shell commands, and utilize your arsenal of tools as needed.]]
  elseif can_edit then
    mode_desc = [[You are no longer in read-only mode.
You are permitted to make file changes using your tools.]]
  elseif can_run_cmd then
    mode_desc = [[You can run shell commands but cannot edit files directly.]]
  else
    mode_desc = [[You are in read-only mode.
Focus on exploration, analysis, and planning. Do not attempt to modify files.]]
  end

  return fmt(
    [[<system-reminder>
Your operational mode has changed from %s to %s.
%s
</system-reminder>]],
    from_agent,
    to_agent,
    mode_desc
  )
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

  local previous_agent = current_agent
  if current_agent then M._cleanup_current_agent(chat, current_agent) end
  M._apply_agent(chat, agent, agent_name)
  M._chat_agents[chat.bufnr] = agent_name

  if previous_agent and agent.type == "agent" then
    local reminder = build_agent_change_reminder(previous_agent, agent_name)
    if reminder then
      local ok, cc_config = pcall(require, "codecompanion.config")
      if ok and chat.add_message then
        chat:remove_tagged_message("agent_change_reminder")
        chat:add_message({
          role = cc_config.constants.SYSTEM_ROLE,
          content = reminder,
        }, { visible = false, _meta = { tag = "agent_change_reminder" } })
      end
    end
  end

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

  if not is_subagent then navigation.flash_model_info(chat.bufnr) end

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

  -- NOTE: v19+ wraps tool_config inside opts table; v18.x passes it as a direct arg
  local has_new_api = chat.tool_registry.add_single_tool ~= nil
  local group_name = "agent_" .. agent_name

  if tools_config.groups and tools_config.groups[group_name] then
    if has_new_api then
      chat.tool_registry:add_group(group_name, { config = tools_config })
    else
      chat.tool_registry:add_group(group_name, tools_config)
    end
  else
    for _, tool_name in ipairs(agent.tools) do
      if chat.tool_registry.in_use[tool_name] then goto continue end

      local tool_config = tools_config[tool_name]
      if tool_config then
        if has_new_api then
          chat.tool_registry:add(tool_name, { config = tool_config, visible = false })
        else
          chat.tool_registry:add(tool_name, tool_config, { visible = false })
        end
      else
        local extra_tool = M._get_extra_tool(tool_name)
        if extra_tool then
          if has_new_api then
            chat.tool_registry:add(tool_name, { config = extra_tool, visible = false })
          else
            chat.tool_registry:add(tool_name, extra_tool, { visible = false })
          end
        end
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

---Resolve the system prompt for an agent, checking model-specific overrides.
---Checks agent.model_prompts first, then config model_prompts.
---@param chat table
---@param agent CodeCompanionExtra.Agent
---@param agent_name string
---@return string|nil
---@private
function M._resolve_system_prompt(chat, agent, agent_name)
  local model_name = ""
  if chat.adapter then
    if type(chat.adapter.model) == "table" and chat.adapter.model.name then
      model_name = chat.adapter.model.name
    elseif chat.adapter.schema and chat.adapter.schema.model then
      model_name = chat.adapter.schema.model.default or ""
    end
  end
  local model_lower = model_name:lower()

  -- Check agent-level model_prompts first
  local prompt_fn = M._match_model_prompt(agent.model_prompts, model_lower)

  -- Then check global config model_prompts for this agent
  if not prompt_fn then
    local config_prompts = M._config.model_prompts and M._config.model_prompts[agent_name]
    prompt_fn = M._match_model_prompt(config_prompts, model_lower)
  end

  if prompt_fn then
    if type(prompt_fn) == "function" then return prompt_fn(chat) end
    return prompt_fn
  end

  -- Fall back to default agent system_prompt
  if agent.system_prompt then
    if type(agent.system_prompt) == "function" then return agent.system_prompt(chat) end
    ---@cast agent {system_prompt: string}
    return agent.system_prompt
  end

  return nil
end

---Find a matching model prompt from a model_prompts table
---@param model_prompts? table<string, string|fun(chat: table): string>
---@param model_lower string Lowercased model name
---@return (string|fun(chat: table): string)?
---@private
function M._match_model_prompt(model_prompts, model_lower)
  if not model_prompts or model_lower == "" then return nil end
  for pattern, prompt in pairs(model_prompts) do
    if model_lower:find(pattern:lower(), 1, true) then return prompt end
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

  if
    agent.system_prompt
    or agent.model_prompts
    or (M._config.model_prompts and M._config.model_prompts[agent_name])
  then
    local prompt = M._resolve_system_prompt(chat, agent, agent_name)

    if prompt and prompt ~= "" then
      local config = require("codecompanion.config")
      chat:add_message({
        role = config.constants.SYSTEM_ROLE,
        content = prompt,
      }, {
        visible = false,
        index = 1, -- Old API, TODO: remove it when codecompanion reach proper v21
        _meta = { tag = "agent_system_prompt", agent = agent_name, index = 1 },
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
