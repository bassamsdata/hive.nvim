-- Tools module for hive
-- Registers custom tools with CodeCompanion

local M = {}

---@type table<string, table|fun():table>
M.tools = {
  get_diagnostics = function()
    return (require("hive.tools.get_diagnostics"))
  end,
  task = function()
    return (require("hive.tools.task"))
  end,
  ask_user = function()
    return (require("hive.tools.ask_user"))
  end,
  skill = function()
    return (require("hive.tools.skill"))
  end,
  list_directory = function()
    return (require("hive.tools.list_directory"))
  end,
  grep_search = function()
    return (require("hive.tools.grep_search"))
  end,
  todowrite = function()
    local todo = require("hive.tools.todo")
    return todo.get_todowrite()
  end,
  todoread = function()
    local todo = require("hive.tools.todo")
    return todo.get_todoread()
  end,
  consult = function()
    return (require("hive.tools.consult"))
  end,
  cmd_runner = function()
    return (require("hive.tools.cmd_runner"))
  end,
  prune = function()
    return (require("hive.tools.prune"))
  end,
  swarm = function()
    local manager = require("hive.swarm.tools.manager")
    return manager.get_tool()
  end,
  claim_task = function()
    local worker = require("hive.swarm.tools.worker")
    return worker.get("claim_task")
  end,
  complete_task = function()
    local worker = require("hive.swarm.tools.worker")
    return worker.get("complete_task")
  end,
  release_task = function()
    local worker = require("hive.swarm.tools.worker")
    return worker.get("release_task")
  end,
  lock_file = function()
    local worker = require("hive.swarm.tools.worker")
    return worker.get("lock_file")
  end,
  unlock_file = function()
    local worker = require("hive.swarm.tools.worker")
    return worker.get("unlock_file")
  end,
  send_update = function()
    local worker = require("hive.swarm.tools.worker")
    return worker.get("send_update")
  end,
  send_to_peer = function()
    local worker = require("hive.swarm.tools.worker")
    return worker.get("send_to_peer")
  end,
  read_messages = function()
    local worker = require("hive.swarm.tools.worker")
    return worker.get("read_messages")
  end,
  get_swarm_status = function()
    local worker = require("hive.swarm.tools.worker")
    return worker.get("get_swarm_status")
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
        local callback = function()
          return M.get(name)
        end
        tools[name] = {
          callback = callback,
          description = tool_def.schema and tool_def.schema["function"] and tool_def.schema["function"].description
            or "Custom tool from hive",
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
