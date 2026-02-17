--[[
Description:
  Backward-compatibility shim for CodeCompanion tool API changes.
  v18 uses positional arguments; v19+ uses structured meta-tables.
]]

local M = {}

local _is_new_api = nil ---@type boolean|nil
local _detected_new_api = nil ---@type boolean|nil

--- Detect whether the running CodeCompanion uses the new tool API.
--- Uses structural detection: checks for the cmd_tool factory module
--- which only exists in the new API. Falls back to version >= 19 check.
--- Runtime detection from cmds() takes highest priority.
---@return boolean
function M.is_new_api()
  if _detected_new_api ~= nil then return _detected_new_api end
  if _is_new_api ~= nil then return _is_new_api end

  -- Structural detection: cmd_tool factory only exists in new API
  local ok = pcall(require, "codecompanion.interactions.chat.tools.builtin.cmd_tool")
  if ok then
    _is_new_api = true
    return true
  end

  -- Fallback: version-based detection
  local cc_ok, cc = pcall(require, "codecompanion")
  if cc_ok and type(cc.version) == "function" then
    local ver = cc.version()
    if ver then
      local major = tonumber(ver:match("^(%d+)"))
      _is_new_api = major ~= nil and major >= 19
      return _is_new_api
    end
  end

  _is_new_api = false
  return false
end

--- Wrap a `cmds` function.
--- NEW: `function(tools, args, opts)`   — opts = { input, output_cb }
--- OLD: `function(tools, args, input, output_handler)`
---@param fn fun(tools: table, args: table, opts: table): any
---@return fun(...): any
function M.cmds(fn)
  return function(tools, args, arg3, arg4)
    if _detected_new_api == nil then _detected_new_api = (type(arg4) ~= "function") end

    if _detected_new_api then
      return fn(tools, args, arg3 or {})
    else
      return fn(tools, args, { input = arg3, output_cb = arg4 })
    end
  end
end

--- Wrap an `output.success` callback.
--- NEW: `function(self, stdout, meta)`  — meta = { cmd, tools }
--- OLD: `function(self, tools, cmd, stdout)`
---@param fn fun(self: table, stdout: table, meta: table)
---@return fun(...)
function M.output_success(fn)
  return function(self, arg2, arg3, arg4)
    if M.is_new_api() then
      return fn(self, arg2, arg3 or {})
    else
      return fn(self, arg4, { tools = arg2, cmd = arg3 })
    end
  end
end

--- Wrap an `output.error` callback.
--- NEW: `function(self, stderr, meta)`  — meta = { cmd, tools }
--- OLD: `function(self, tools, cmd, stderr)`
---@param fn fun(self: table, stderr: table, meta: table)
---@return fun(...)
function M.output_error(fn)
  return function(self, arg2, arg3, arg4)
    if M.is_new_api() then
      return fn(self, arg2, arg3 or {})
    else
      return fn(self, arg4, { tools = arg2, cmd = arg3 })
    end
  end
end

--- Wrap an `output.rejected` callback.
--- NEW: `function(self, meta)` — meta = { cmd, tools, opts }
--- OLD: `function(self, tools, cmd, opts)`
---@param fn fun(self: table, meta: table)
---@return fun(...)
function M.output_rejected(fn)
  return function(self, arg2, arg3, arg4)
    if M.is_new_api() then
      return fn(self, arg2 or {})
    else
      return fn(self, { tools = arg2, cmd = arg3, opts = arg4 or {} })
    end
  end
end

--- Wrap an `output.cancelled` callback.
--- NEW: `function(self, meta)` — meta = { cmd, tools }
--- OLD: `function(self, tools, cmd)`
---@param fn fun(self: table, meta: table)
---@return fun(...)
function M.output_cancelled(fn)
  return function(self, arg2, arg3)
    if M.is_new_api() then
      return fn(self, arg2 or {})
    else
      return fn(self, { tools = arg2, cmd = arg3 })
    end
  end
end

--- Wrap an `output.prompt` callback.
--- NEW: `function(self, meta)` — meta = { tools }
--- OLD: `function(self, tools)`
---@param fn fun(self: table, meta: table): string
---@return fun(...): string
function M.output_prompt(fn)
  return function(self, arg2)
    if M.is_new_api() then
      return fn(self, arg2 or {})
    else
      return fn(self, { tools = arg2 })
    end
  end
end

--- Wrap an `output.cmd_string` callback.
--- Same shape as prompt: `(self, meta)` vs `(self, tools)`.
---@param fn fun(self: table, meta: table): string
---@return fun(...): string
M.output_cmd_string = M.output_prompt

--- Wrap a `handlers.setup` callback.
--- NEW: `function(self, meta)` — meta = { tools }
--- OLD: `function(self, tools)`
---@param fn fun(self: table, meta: table)
---@return fun(...)
function M.handler_setup(fn)
  return function(self, arg2)
    if M.is_new_api() then
      return fn(self, arg2 or {})
    else
      return fn(self, { tools = arg2 })
    end
  end
end

--- Wrap a `handlers.on_exit` callback.
--- NEW: `function(self, meta)` — meta = { tools }
--- OLD: `function(self, tools)`
---@param fn fun(self_or_tools: table, meta: table|nil)
---@return fun(...)
function M.handler_on_exit(fn)
  return function(arg1, arg2)
    if M.is_new_api() then
      return fn(arg1, arg2 or {})
    else
      return fn(arg1, { tools = arg2 })
    end
  end
end

--- Wrap a `handlers.prompt_condition` callback.
--- NEW: `function(self, meta)` — meta = { tools }
--- OLD: `function(self, tools)`
---@param fn fun(self: table, meta: table): boolean
---@return fun(...): boolean
M.handler_prompt_condition = M.handler_setup

return M
