-- API compatibility tests for codecompanion.nvim internals
-- Validates that the APIs codecompanion-extra depends on still exist and have
-- the expected shape. Run via: make test-compat

local MiniTest = require("mini.test")
local expect = MiniTest.expect
local new_set = MiniTest.new_set

local T = new_set()

-- ============================================================================
-- Helpers
-- ============================================================================

local function has_method(tbl, name)
  return type(tbl[name]) == "function"
end

local function require_ok(mod)
  local ok, result = pcall(require, mod)
  return ok, result
end

--- Get parameter count for a function (excludes self for methods)
local function get_nparams(fn)
  local info = debug.getinfo(fn, "u")
  return info.nparams
end

--- Create a ToolRegistry instance with a minimal mock chat
local function make_registry()
  local ToolRegistry = require("codecompanion.interactions.chat.tool_registry")
  local mock_chat = { bufnr = 0 }
  return ToolRegistry.new({ chat = mock_chat }), ToolRegistry
end

-- ============================================================================
-- ToolRegistry API
-- ============================================================================

T["ToolRegistry"] = new_set()

T["ToolRegistry"]["module loads"] = function()
  local ok, mod = require_ok("codecompanion.interactions.chat.tool_registry")
  expect.equality(ok, true)
  expect.equality(type(mod), "table")
end

T["ToolRegistry"]["new() returns instance with expected fields"] = function()
  local instance = make_registry()

  expect.equality(type(instance), "table")
  expect.equality(type(instance.in_use), "table")
  expect.equality(type(instance.schemas), "table")
  expect.equality(type(instance.flags), "table")
end

T["ToolRegistry"]["has core methods"] = function()
  local instance = make_registry()

  expect.equality(has_method(instance, "add"), true)
  expect.equality(has_method(instance, "add_group"), true)
  expect.equality(has_method(instance, "add_tool_system_prompt"), true)
  expect.equality(has_method(instance, "loaded"), true)
  expect.equality(has_method(instance, "clear"), true)
end

T["ToolRegistry"]["detects new vs old API via add_single_tool"] = function()
  local instance = make_registry()

  -- v19+: add_single_tool exists. v18.x: it does not.
  local has_new = instance.add_single_tool ~= nil
  expect.equality(type(has_new), "boolean")
end

-- ============================================================================
-- ToolRegistry behavioral / signature tests
-- ============================================================================

T["ToolRegistry signatures"] = new_set()

T["ToolRegistry signatures"]["add() param count matches known API"] = function()
  local _, ToolRegistry = make_registry()
  local nparams = get_nparams(ToolRegistry.add)

  -- v18.x: add(self, tool, tool_config, opts) = 4 params
  -- v19+:  add(self, name, opts) = 3 params
  -- Either is acceptable; a different count means a breaking change
  local known = (nparams == 4 or nparams == 3)
  expect.equality(known, true)
end

T["ToolRegistry signatures"]["add_group() param count matches known API"] = function()
  local _, ToolRegistry = make_registry()
  local nparams = get_nparams(ToolRegistry.add_group)

  -- v18.x: add_group(self, group, tools_config) = 3 params
  -- v19+:  add_group(self, group, opts) = 3 params
  -- Both versions take 3 params (self + 2 args)
  expect.equality(nparams, 3)
end

T["ToolRegistry signatures"]["clear() takes only self"] = function()
  local _, ToolRegistry = make_registry()
  expect.equality(get_nparams(ToolRegistry.clear), 1)
end

T["ToolRegistry signatures"]["loaded() takes only self"] = function()
  local _, ToolRegistry = make_registry()
  expect.equality(get_nparams(ToolRegistry.loaded), 1)
end

T["ToolRegistry signatures"]["add_tool_system_prompt() takes only self"] = function()
  local _, ToolRegistry = make_registry()
  expect.equality(get_nparams(ToolRegistry.add_tool_system_prompt), 1)
end

T["ToolRegistry behavior"] = new_set()

T["ToolRegistry behavior"]["clear() resets in_use and schemas"] = function()
  local instance = make_registry()

  -- Simulate some state
  instance.in_use["test_tool"] = true
  instance.schemas["<tool>test_tool</tool>"] = { name = "test_tool" }
  instance.flags["some_flag"] = true

  instance:clear()

  expect.equality(vim.tbl_isempty(instance.in_use), true)
  expect.equality(vim.tbl_isempty(instance.schemas), true)
  expect.equality(vim.tbl_isempty(instance.flags), true)
end

T["ToolRegistry behavior"]["loaded() reflects in_use state"] = function()
  local instance = make_registry()

  expect.equality(instance:loaded(), false)

  instance.in_use["test_tool"] = true
  expect.equality(instance:loaded(), true)

  instance:clear()
  expect.equality(instance:loaded(), false)
end

T["ToolRegistry behavior"]["new() param count is 1 (args table)"] = function()
  local _, ToolRegistry = make_registry()
  expect.equality(get_nparams(ToolRegistry.new), 1)
end

-- ============================================================================
-- Config shape
-- ============================================================================

T["Config"] = new_set()

T["Config"]["module loads"] = function()
  local ok, config = require_ok("codecompanion.config")
  expect.equality(ok, true)
  expect.equality(type(config), "table")
end

T["Config"]["interactions.chat.tools path exists"] = function()
  local config = require("codecompanion.config")

  expect.equality(type(config.interactions), "table")
  expect.equality(type(config.interactions.chat), "table")
  expect.equality(type(config.interactions.chat.tools), "table")
end

T["Config"]["interactions.chat.tools.opts path exists"] = function()
  local config = require("codecompanion.config")
  expect.equality(type(config.interactions.chat.tools.opts), "table")
end

T["Config"]["interactions.chat.keymaps exists"] = function()
  local config = require("codecompanion.config")
  expect.equality(type(config.interactions.chat.keymaps), "table")
end

T["Config"]["constants has SYSTEM_ROLE and USER_ROLE"] = function()
  local config = require("codecompanion.config")

  expect.equality(type(config.constants), "table")
  expect.equality(type(config.constants.SYSTEM_ROLE), "string")
  expect.equality(type(config.constants.USER_ROLE), "string")
end

-- ============================================================================
-- Public API
-- ============================================================================

T["Public API"] = new_set()

T["Public API"]["codecompanion module loads"] = function()
  local ok, cc = require_ok("codecompanion")
  expect.equality(ok, true)
  expect.equality(type(cc), "table")
end

T["Public API"]["version() returns string"] = function()
  local cc = require("codecompanion")

  expect.equality(has_method(cc, "version"), true)

  local ver = cc.version()
  if ver ~= nil then
    expect.equality(type(ver), "string")
    expect.equality(ver:match("^%d+%.%d+") ~= nil, true)
  end
end

T["Public API"]["chat function exists"] = function()
  local cc = require("codecompanion")
  expect.equality(type(cc.chat), "function")
end

T["Public API"]["buf_get_chat function exists"] = function()
  local cc = require("codecompanion")
  expect.equality(type(cc.buf_get_chat), "function")
end

-- ============================================================================
-- Utility modules we depend on
-- ============================================================================

T["Utils"] = new_set()

T["Utils"]["utils module loads and has fire"] = function()
  local ok, utils = require_ok("codecompanion.utils")
  expect.equality(ok, true)
  expect.equality(has_method(utils, "fire"), true)
end

T["Utils"]["log module loads"] = function()
  local ok, _ = require_ok("codecompanion.utils.log")
  expect.equality(ok, true)
end

-- ============================================================================
-- Chat module structure (without creating a real chat)
-- ============================================================================

T["Chat module"] = new_set()

T["Chat module"]["loads"] = function()
  local ok, chat_mod = require_ok("codecompanion.interactions.chat")
  expect.equality(ok, true)
  expect.equality(type(chat_mod), "table")
end

T["Chat module"]["has new constructor"] = function()
  local chat_mod = require("codecompanion.interactions.chat")
  expect.equality(has_method(chat_mod, "new"), true)
end

T["Chat module"]["has buf_get_chat"] = function()
  local chat_mod = require("codecompanion.interactions.chat")
  expect.equality(has_method(chat_mod, "buf_get_chat"), true)
end

-- ============================================================================
-- Context module
-- ============================================================================

T["Context module"] = new_set()

T["Context module"]["loads"] = function()
  local ok, ctx = require_ok("codecompanion.interactions.chat.context")
  expect.equality(ok, true)
  expect.equality(type(ctx), "table")
end

T["Context module"]["has new constructor"] = function()
  local ctx = require("codecompanion.interactions.chat.context")
  expect.equality(has_method(ctx, "new"), true)
end

return T
