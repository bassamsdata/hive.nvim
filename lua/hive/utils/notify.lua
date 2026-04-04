local TITLE = "Hive"

---@param msg string
---@param level? integer vim.log.levels value (default: INFO)
---@param opts? table extra opts forwarded to vim.notify
return function(msg, level, opts)
  opts = vim.tbl_extend("force", { title = TITLE }, opts or {})
  vim.notify(msg, level or vim.log.levels.INFO, opts)
end
