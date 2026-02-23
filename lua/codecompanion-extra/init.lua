-- codecompanion-extra
-- Extra features for CodeCompanion.nvim
-- Provides: spinner, adapters (groq, cerebras, openrouter), tools (get_diagnostics, task, ask_user, skill), agents, and skills

local M = {}

---@type boolean
M._initialized = false

---@type CodeCompanionExtra.Config|nil
M._config = nil

---Setup codecompanion-extra as a standalone plugin
---@param opts? table User configuration
function M.setup(opts)
  if M._initialized then return end

  local config = require("codecompanion-extra.config")
  M._config = config.setup(opts)

  M._setup_modules()
  M._initialized = true
end

---Setup individual modules based on config
function M._setup_modules()
  local config = require("codecompanion-extra.config")

  if config.is_module_enabled("spinner") then
    local spinner = require("codecompanion-extra.spinner")
    spinner.setup(M._config.spinner)
  end

  if config.is_module_enabled("notify") then
    local notify = require("codecompanion-extra.notify_controller")
    notify.setup(M._config.sys_notify or {})
    local state = require("codecompanion-extra.state")
    if not state.instance() then state.setup(M._config) end
    if notify.instance() then notify.instance():attach_state(state.instance()) end
  end

  if config.is_module_enabled("skills") then
    local skills = require("codecompanion-extra.skills")
    skills.setup(M._config.skills)
  end

  if config.is_module_enabled("agents") then
    local agents = require("codecompanion-extra.agents")
    agents.setup(M._config.agents)
  end

  if config.is_module_enabled("context_pruning") then
    local context_pruning = require("codecompanion-extra.context_pruning")
    context_pruning.setup(M._config.context_pruning or {})
  end
end

---Get list of available extra adapter names
---@return string[]
function M.adapter_list()
  return { "groq", "cerebras", "openrouter" }
end

---Get a specific adapter table by name
---These are plain tables that should be used with require("codecompanion.adapters").extend()
---
---TODO:MOVE to README, once created
---Example usage in codecompanion setup:
---```lua
---adapters = {
---  openrouter = function()
---    return require("codecompanion.adapters").extend("openrouter", {
---      env = { api_key = "your-key" },
---      schema = { model = { default = "anthropic/claude-sonnet-4" } },
---    })
---  end,
---}
---```
---@param name string Adapter name (groq, cerebras, openrouter)
---@return table|nil Adapter table
function M.adapter(name)
  local adapter_paths = {
    groq = "codecompanion.adapters.http.groq",
    cerebras = "codecompanion.adapters.http.cerebras",
    openrouter = "codecompanion.adapters.http.openrouter",
  }
  local module_path = adapter_paths[name]
  if not module_path then return nil end
  local ok, adapter = pcall(require, module_path)
  if not ok then return nil end
  return adapter
end

---Get registered tools for use in codecompanion config
---@param tools_opts? table Override tool options
---@return table tools Table of tool definitions
function M.tools(tools_opts)
  local config = require("codecompanion-extra.config")
  local tools_module = require("codecompanion-extra.tools")

  local tools_config = vim.tbl_deep_extend("force", config.get().tools or {}, tools_opts or {})

  return tools_module.register(tools_config)
end

---Get a specific tool
---@param name string Tool name
---@return table|nil Tool definition
function M.tool(name)
  local tools_module = require("codecompanion-extra.tools")
  return tools_module.get(name)
end

---Get agents module
---@return table Agents module
function M.agents()
  return (require("codecompanion-extra.agents"))
end

---Get spinner module
---@return table Spinner module
function M.spinner()
  return (require("codecompanion-extra.spinner"))
end

---Get skills module
---@return table Skills module
function M.skills()
  return (require("codecompanion-extra.skills"))
end

---Check if initialized
---@return boolean
function M.is_initialized()
  return M._initialized
end

---Get current config
---@return CodeCompanionExtra.Config|nil
function M.get_config()
  return M._config
end

return M
