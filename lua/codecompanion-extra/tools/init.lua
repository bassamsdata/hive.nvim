-- Tools module for codecompanion-extra
-- Registers custom tools with CodeCompanion

local M = {}

---@type table<string, table|fun():table>
M.tools = {
  get_diagnostics = function()
    return require("codecompanion-extra.tools.get_diagnostics")
  end,
  task = function()
    return require("codecompanion-extra.tools.task")
  end,
  ask_user = function()
    return require("codecompanion-extra.tools.ask_user")
  end,
  skill = function()
    return require("codecompanion-extra.tools.skill")
  end,
  list_directory = function()
    return require("codecompanion-extra.tools.list_directory")
  end,
}

---Get a tool definition
---@param name string
---@return table|nil
function M.get(name)
  local tool = M.tools[name]
  if type(tool) == "function" then return tool() end
  return tool
end

---Register tools with CodeCompanion config
---@param tools_config table Table of tool names to their enabled/opts config
---@return table tools Table suitable for codecompanion.interactions.chat.tools
function M.register(tools_config)
  local tools = {}

  for name, config in pairs(tools_config) do
    if config.enabled ~= false and M.tools[name] then
      local tool_def = M.get(name)
      if tool_def then
        local callback = "codecompanion-extra.tools." .. name
        tools[name] = {
          callback = callback,
          description = tool_def.schema and tool_def.schema["function"] and tool_def.schema["function"].description
            or "Custom tool from codecompanion-extra",
          opts = config.opts or {},
        }
      end
    end
  end

  return tools
end

---Get list of available tool names
---@return string[]
function M.list()
  return vim.tbl_keys(M.tools)
end

return M
