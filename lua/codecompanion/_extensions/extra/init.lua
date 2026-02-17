-- CodeCompanion Extension: extra
-- Entry point for codecompanion-extra integration with CodeCompanion's extension system
-- Provides: spinner, adapters (groq, cerebras, openrouter), tools (get_diagnostics, task), and agents

local M = {}

---@type boolean
M._initialized = false

---@type table
M._opts = {}

---@type table<string, string>
M.extra_adapters = {
  groq = "groq",
  cerebras = "cerebras",
  openrouter = "openrouter",
}

---Setup the extension
---Called by CodeCompanion's extension loader
---@param opts table Extension options
function M.setup(opts)
  if M._initialized then return end

  M._opts = opts or {}

  local extra = require("codecompanion-extra")
  extra.setup(M._opts)

  M._register_adapters()
  M._register_tools()
  M._register_agents()

  M._initialized = true
end

---Register adapters with CodeCompanion config
---This adds adapter entries to config.adapters.http so they show up in adapter selection
---The adapters are complete standalone adapters (already extend OpenAI internally)
---so we just register them as strings - CodeCompanion will require() them directly
function M._register_adapters()
  local config_module = require("codecompanion-extra.config")
  if not config_module.is_module_enabled("adapters") then return end

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  if not cc_config.adapters then cc_config.adapters = {} end
  if not cc_config.adapters.http then cc_config.adapters.http = {} end

  local adapter_config = config_module.get().adapters or {}

  for name, _ in pairs(M.extra_adapters) do
    local config = adapter_config[name] or {}
    if config.enabled ~= false then
      if cc_config.adapters.http[name] == nil then cc_config.adapters.http[name] = name end
    end
  end
end

---Register tools with CodeCompanion config
function M._register_tools()
  local config_module = require("codecompanion-extra.config")
  if not config_module.is_module_enabled("tools") then return end

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local tools_module = require("codecompanion-extra.tools")
  local tools_config = config_module.get().tools or {}

  local chat_tools = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.tools
  if not chat_tools then return end

  for name, config in pairs(tools_config) do
    if config.enabled ~= false and tools_module.tools[name] then
      local tool_def = tools_module.get(name)
      if tool_def then
        local tool_name = name
        chat_tools[name] = {
          callback = function()
            return tools_module.get(tool_name)
          end,
          description = tool_def.schema and tool_def.schema["function"] and tool_def.schema["function"].description
            or "Tool from codecompanion-extra",
          opts = config.opts or tool_def.opts or {},
        }
      end
    end
  end
end

---Register agents module
function M._register_agents()
  local config_module = require("codecompanion-extra.config")
  if not config_module.is_module_enabled("agents") then return end

  local agents_config = config_module.get().agents or {}
  local agents = require("codecompanion-extra.agents")
  agents.setup(agents_config)
end

---@type CodeCompanion.Extension
return {
  setup = M.setup,

  exports = {
    ---Get the extra module
    ---@return table
    get = function()
      return require("codecompanion-extra")
    end,

    ---Get list of available extra adapter names
    ---@return string[]
    adapter_list = function()
      return vim.tbl_keys(M.extra_adapters)
    end,

    ---Get a specific adapter table by name
    ---These are plain tables that should be used with require("codecompanion.adapters").extend()
    ---@param name string
    ---@return table|nil
    adapter = function(name)
      if not M.extra_adapters[name] then return nil end
      local ok, adapter = pcall(require, "codecompanion.adapters.http." .. name)
      if not ok then return nil end
      return adapter
    end,

    ---Get tools
    ---@param opts? table
    ---@return table
    tools = function(opts)
      return require("codecompanion-extra").tools(opts)
    end,

    ---Get a specific tool
    ---@param name string
    ---@return table|nil
    tool = function(name)
      return require("codecompanion-extra").tool(name)
    end,

    ---Get agents module
    ---@return table
    agents = function()
      return require("codecompanion-extra").agents()
    end,

    ---Activate an agent
    ---@param agent_name string
    ---@param chat table
    ---@return boolean
    activate_agent = function(agent_name, chat)
      return require("codecompanion-extra.agents").activate(agent_name, chat)
    end,

    ---Get spinner module
    ---@return table
    spinner = function()
      return require("codecompanion-extra").spinner()
    end,
  },
}
