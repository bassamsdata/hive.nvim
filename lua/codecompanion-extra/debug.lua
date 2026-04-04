local LOG_PATH = vim.fn.stdpath("data") .. "/ccextra_debug.log"

local M = {}

---Write a timestamped line to the ccextra debug log
---@param tag string Module tag (e.g. "state", "prune")
---@param msg string Log message
function M.log(tag, msg)
  local config = require("codecompanion-extra.config")
  if not (config.config and config.config.debug and config.config.debug.enabled) then return end

  local f = io.open(LOG_PATH, "a")
  if f then
    f:write(string.format("[%s] [%s] %s\n", os.date("%H:%M:%S"), tag, msg))
    f:close()
  end
end

---@return string
function M.path()
  return LOG_PATH
end

return M
