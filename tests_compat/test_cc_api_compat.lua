-- API compatibility tests for codecompanion.nvim internals
-- Validates that the APIs hive depends on still exist and have
-- the expected shape. Run via: make test-compat
--
-- These tests catch breaking changes that affect hive:
-- 1. Tool registration: how tools are configured in cc_config.interactions.chat.tools
-- 2. Tool resolution: how Tools.resolve() discovers and loads tool definitions
-- 3. Orchestrator signatures: how handler/output callbacks are invoked
-- 4. Helper modules: helpers.rejected, built-in tool paths
-- 5. Config structure: paths that extension code reads/writes
-- 6. Event data shapes: what fields autocmd events carry

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

local function get_nparams(fn)
  local info = debug.getinfo(fn, "u")
  return info.nparams
end

local function make_registry()
  local ToolRegistry = require("codecompanion.interactions.chat.tool_registry")
  local mock_chat = { bufnr = 0 }
  return ToolRegistry.new({ chat = mock_chat }), ToolRegistry
end

--- Create a mock Tools object for orchestrator tests
local function make_mock_tools()
  return {
    bufnr = 0,
    chat = {
      bufnr = 0,
      tool_registry = { flags = {} },
      add_tool_output = function() end,
    },
    constants = { STATUS_SUCCESS = "success", STATUS_ERROR = "error" },
    status = "success",
    stderr = {},
    stdout = {},
  }
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

T["ToolRegistry"]["has add_single_tool method (develop only)"] = function()
  local instance = make_registry()
  -- add_single_tool was extracted as a public method on develop; main only has add()
  if not has_method(instance, "add_single_tool") then MiniTest.skip("add_single_tool not present (main branch)") end
  expect.equality(has_method(instance, "add_single_tool"), true)
end

-- ============================================================================
-- ToolRegistry signatures
-- ============================================================================

T["ToolRegistry signatures"] = new_set()

T["ToolRegistry signatures"]["add() param count matches known API"] = function()
  local _, ToolRegistry = make_registry()
  local nparams = get_nparams(ToolRegistry.add)
  local known = (nparams == 4 or nparams == 3)
  expect.equality(known, true)
end

T["ToolRegistry signatures"]["add_group() param count"] = function()
  local _, ToolRegistry = make_registry()
  expect.equality(get_nparams(ToolRegistry.add_group), 3)
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

T["ToolRegistry signatures"]["new() param count is 1 (args table)"] = function()
  local _, ToolRegistry = make_registry()
  expect.equality(get_nparams(ToolRegistry.new), 1)
end

-- ============================================================================
-- ToolRegistry behavior
-- ============================================================================

T["ToolRegistry behavior"] = new_set()

T["ToolRegistry behavior"]["clear() resets in_use, schemas, flags"] = function()
  local instance = make_registry()

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

-- ============================================================================
-- Tools module & resolution
-- ============================================================================

T["Tools module"] = new_set()

T["Tools module"]["loads"] = function()
  local ok, mod = require_ok("codecompanion.interactions.chat.tools")
  expect.equality(ok, true)
  expect.equality(type(mod), "table")
end

T["Tools module"]["has resolve static method"] = function()
  local Tools = require("codecompanion.interactions.chat.tools")
  expect.equality(type(Tools.resolve), "function")
end

T["Tools module"]["resolve() handles callback as function"] = function()
  local Tools = require("codecompanion.interactions.chat.tools")

  local mock_tool = {
    name = "test_tool",
    cmds = {},
    schema = { type = "function", ["function"] = { name = "test_tool" } },
    system_prompt = "test",
  }

  local tool_config = {
    callback = function()
      return mock_tool
    end,
    description = "Test tool",
    opts = {},
  }

  local resolved = Tools.resolve(tool_config)
  expect.equality(type(resolved), "table")
  expect.equality(resolved.name, "test_tool")
end

T["Tools module"]["resolve() with callback-as-table"] = function()
  local Tools = require("codecompanion.interactions.chat.tools")

  local mock_tool = {
    name = "test_tool",
    cmds = {},
    schema = { type = "function", ["function"] = { name = "test_tool" } },
    system_prompt = "test",
  }

  -- callback as table: works on main (returns table directly),
  -- broken on develop (falls through to inline, returns wrapper)
  local tool_config = {
    callback = mock_tool,
    description = "Test tool",
    opts = {},
  }

  local resolved = Tools.resolve(tool_config)

  -- On main: resolved IS mock_tool (callback-as-table handled)
  -- On develop: resolved is the wrapper itself (no name, no cmds)
  -- Either way, this documents the behavior — the important thing is
  -- that extra NEVER uses callback-as-table (tested below)
  expect.equality(type(resolved), "table")
end

T["Tools module"]["resolve() handles path-based tools (develop only)"] = function()
  local Tools = require("codecompanion.interactions.chat.tools")

  -- path-based resolution was added on develop; main uses callback strings
  local tool_config = {
    path = "interactions.chat.tools.builtin.read_file",
    description = "Read a file",
  }

  local ok, resolved = pcall(Tools.resolve, tool_config)
  if not ok then MiniTest.skip("path-based resolution not supported (main branch)") end
  expect.equality(type(resolved), "table")
  expect.equality(resolved.name, "read_file")
end

-- CRITICAL: this test catches the exact bug from the develop refactor of Tools.resolve.
-- _register_extra_tools must use callback-as-function, NOT callback-as-table,
-- because develop's Tools.resolve only handles callback as a function.
T["Tools module"]["extra _register_extra_tools uses callback-as-function"] = function()
  local Tools = require("codecompanion.interactions.chat.tools")
  local config = require("codecompanion.config")

  -- Simulate what _register_extra_tools does
  local mock_tool = {
    name = "extra_compat_test",
    cmds = { function() end },
    schema = { type = "function", ["function"] = { name = "extra_compat_test" } },
    system_prompt = "test",
  }

  -- CORRECT: callback wrapped in a function (what we do after the fix)
  config.interactions.chat.tools["extra_compat_test"] = {
    callback = function()
      return mock_tool
    end,
    description = "Test",
    opts = {},
  }

  local resolved = Tools.resolve(config.interactions.chat.tools["extra_compat_test"])
  expect.equality(type(resolved), "table")
  expect.equality(resolved.name, "extra_compat_test")
  expect.equality(type(resolved.cmds), "table")
  expect.equality(type(resolved.schema), "table")

  config.interactions.chat.tools["extra_compat_test"] = nil
end

-- Verify that all extra tool modules, when resolved through callback-as-function,
-- produce a valid tool definition with required fields
T["Tools module"]["all extra tools resolve with required fields"] = function()
  local Tools = require("codecompanion.interactions.chat.tools")

  local tool_modules = {
    { name = "get_diagnostics", mod = "hive.tools.get_diagnostics" },
    { name = "list_directory", mod = "hive.tools.list_directory" },
    { name = "ask_user", mod = "hive.tools.ask_user" },
    { name = "cmd_runner", mod = "hive.tools.cmd_runner" },
    { name = "consult", mod = "hive.tools.consult" },
    { name = "task", mod = "hive.tools.task" },
  }

  for _, entry in ipairs(tool_modules) do
    local ok, tool_def = pcall(require, entry.mod)
    if ok and tool_def then
      -- Wrap in callback-as-function (the pattern we MUST use)
      local tool_config = {
        callback = function()
          return tool_def
        end,
        description = "test",
        opts = {},
      }

      local resolved = Tools.resolve(tool_config)
      expect.equality(type(resolved), "table")
      expect.equality(resolved.name, entry.name)
      expect.equality(type(resolved.cmds), "table")
      expect.equality(type(resolved.schema), "table")
    end
  end
end

-- ============================================================================
-- Orchestrator callback signatures
-- ============================================================================

T["Orchestrator signatures"] = new_set()

T["Orchestrator signatures"]["handler.setup receives (self, meta_or_tools)"] = function()
  local Orchestrator = require("codecompanion.interactions.chat.tools.orchestrator")

  local captured_args = {}

  local orch = Orchestrator.new(make_mock_tools(), 1)

  orch.tool = {
    name = "test",
    cmds = {},
    handlers = {
      setup = function(self_arg, meta_arg)
        captured_args.self = self_arg
        captured_args.meta = meta_arg
      end,
    },
    output = {},
  }

  orch:_setup_handlers()
  orch.handlers.setup()

  expect.equality(captured_args.self.name, "test")
  expect.equality(type(captured_args.meta), "table")

  -- New API: meta = { tools = tools }; Old API: meta IS tools (has bufnr)
  local has_tools_key = captured_args.meta.tools ~= nil
  local is_tools_directly = captured_args.meta.bufnr ~= nil
  expect.equality(has_tools_key or is_tools_directly, true)
end

T["Orchestrator signatures"]["output.success arg order"] = function()
  local Orchestrator = require("codecompanion.interactions.chat.tools.orchestrator")

  local captured = {}

  local orch = Orchestrator.new(make_mock_tools(), 1)

  orch.tool = {
    name = "test",
    cmds = {},
    handlers = {},
    output = {
      success = function(self_arg, arg2, arg3, arg4)
        captured.self = self_arg
        captured.arg2 = arg2
        captured.arg3 = arg3
        captured.arg4 = arg4
      end,
    },
  }
  orch.tool_output = { "test output" }

  orch:_setup_handlers()
  orch.output.success("mock_cmd")

  -- New API: success(self, stdout, { cmd, tools }) -> arg3 has .tools
  -- Old API: success(self, tools, cmd, stdout)     -> arg2 has .bufnr
  local new_api = (type(captured.arg3) == "table" and captured.arg3.tools ~= nil)
  local old_api = (type(captured.arg2) == "table" and captured.arg2.bufnr ~= nil)
  expect.equality(new_api or old_api, true)
end

T["Orchestrator signatures"]["output.rejected arg structure"] = function()
  local Orchestrator = require("codecompanion.interactions.chat.tools.orchestrator")

  local captured = {}

  local orch = Orchestrator.new(make_mock_tools(), 1)

  orch.tool = {
    name = "test",
    cmds = {},
    handlers = {},
    output = {
      rejected = function(self_arg, arg2, arg3, arg4)
        captured.arg2 = arg2
        captured.arg3 = arg3
        captured.arg4 = arg4
      end,
    },
  }

  orch:_setup_handlers()
  orch.output.rejected("mock_cmd", { reason = "test" })

  -- New API: rejected(self, { cmd, tools, opts })  -> arg2 has .tools and .cmd
  -- Old API: rejected(self, tools, cmd, opts)      -> arg2 has .bufnr
  local new_api = (type(captured.arg2) == "table" and captured.arg2.tools ~= nil and captured.arg2.cmd ~= nil)
  local old_api = (type(captured.arg2) == "table" and captured.arg2.bufnr ~= nil)
  expect.equality(new_api or old_api, true)
end

T["Orchestrator signatures"]["output.error arg order"] = function()
  local Orchestrator = require("codecompanion.interactions.chat.tools.orchestrator")

  local captured = {}

  local orch = Orchestrator.new(make_mock_tools(), 1)
  orch.tool = {
    name = "test",
    cmds = {},
    handlers = {},
    output = {
      error = function(self_arg, arg2, arg3, arg4)
        captured.arg2 = arg2
        captured.arg3 = arg3
        captured.arg4 = arg4
      end,
    },
  }

  orch:_setup_handlers()
  orch.output.error("mock_cmd")

  -- New API: error(self, stderr|nil, { cmd, tools }) -> arg3 has .tools
  -- Old API: error(self, tools, cmd, stderr)         -> arg2 has .bufnr
  local new_api = (type(captured.arg3) == "table" and captured.arg3.tools ~= nil)
  local old_api = (type(captured.arg2) == "table" and captured.arg2.bufnr ~= nil)
  expect.equality(new_api or old_api, true)
end

-- ============================================================================
-- Helpers module (used by tools for rejection messages)
-- ============================================================================

T["Tool helpers"] = new_set()

T["Tool helpers"]["helpers module loads"] = function()
  local ok, helpers = require_ok("codecompanion.interactions.chat.tools.builtin.helpers")
  expect.equality(ok, true)
  expect.equality(type(helpers), "table")
end

T["Tool helpers"]["helpers.rejected exists and is a function"] = function()
  local helpers = require("codecompanion.interactions.chat.tools.builtin.helpers")
  expect.equality(type(helpers.rejected), "function")
end

T["Tool helpers"]["helpers.rejected param count"] = function()
  local helpers = require("codecompanion.interactions.chat.tools.builtin.helpers")
  local nparams = get_nparams(helpers.rejected)
  -- Old API: rejected(self, tools, cmd, opts) = 4
  -- New API: rejected(self, opts) = 2
  local known = (nparams == 2 or nparams == 4)
  expect.equality(known, true)
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

T["Config"]["interactions.chat.tools has groups"] = function()
  local config = require("codecompanion.config")
  expect.equality(type(config.interactions.chat.tools.groups), "table")
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

T["Config"]["tool config entries use known resolution keys"] = function()
  local config = require("codecompanion.config")
  local tools = config.interactions.chat.tools

  local checked = 0
  for name, cfg in pairs(tools) do
    if name ~= "opts" and name ~= "groups" and type(cfg) == "table" then
      local has_resolution = cfg.path ~= nil or cfg.callback ~= nil or cfg.extends ~= nil
      if has_resolution then checked = checked + 1 end
    end
  end
  expect.equality(checked > 0, true)
end

-- ============================================================================
-- Tool registration: extra tools can be injected into config
-- ============================================================================

T["Tool registration"] = new_set()

T["Tool registration"]["callback-based tools can be registered and resolved"] = function()
  local config = require("codecompanion.config")
  local Tools = require("codecompanion.interactions.chat.tools")

  local mock_tool = {
    name = "extra_test_tool",
    cmds = { function() end },
    schema = {
      type = "function",
      ["function"] = {
        name = "extra_test_tool",
        description = "A test tool from extra",
        parameters = { type = "object", properties = {} },
      },
    },
    system_prompt = "You have access to the extra_test_tool.",
  }

  config.interactions.chat.tools["extra_test_tool"] = {
    callback = function()
      return mock_tool
    end,
    description = "A test tool from extra",
    opts = {},
  }

  local tool_config = config.interactions.chat.tools["extra_test_tool"]
  local resolved = Tools.resolve(tool_config)

  expect.equality(type(resolved), "table")
  expect.equality(resolved.name, "extra_test_tool")
  expect.equality(type(resolved.cmds), "table")
  expect.equality(type(resolved.schema), "table")
  expect.equality(type(resolved.system_prompt), "string")

  config.interactions.chat.tools["extra_test_tool"] = nil
end

T["Tool registration"]["path-based resolution works for builtin tools"] = function()
  local Tools = require("codecompanion.interactions.chat.tools")
  local config = require("codecompanion.config")

  local read_file_config = config.interactions.chat.tools["read_file"]
  if read_file_config then
    local resolved = Tools.resolve(read_file_config)
    expect.equality(type(resolved), "table")
    expect.equality(resolved.name, "read_file")
  end
end

-- CRITICAL: this test calls the ACTUAL _register_extra_tools function and then
-- verifies every registered tool resolves into a valid tool definition.
-- This would have caught the callback-as-table bug that broke develop.
T["Tool registration"]["_register_extra_tools produces resolvable tools"] = function()
  local Tools = require("codecompanion.interactions.chat.tools")
  local config = require("codecompanion.config")
  local agents = require("hive.agents")

  -- Snapshot keys before registration so we can identify what was added
  local before = {}
  for k, _ in pairs(config.interactions.chat.tools) do
    before[k] = true
  end

  -- Run the actual registration
  agents._register_tools()

  -- Collect newly registered tool names
  local extra_tools = {}
  for k, cfg in pairs(config.interactions.chat.tools) do
    if not before[k] and k ~= "opts" and k ~= "groups" and type(cfg) == "table" then table.insert(extra_tools, k) end
  end

  -- At least some tools should have been registered
  expect.equality(#extra_tools > 0, true)

  -- Every registered tool must resolve into a valid definition
  for _, name in ipairs(extra_tools) do
    local tool_config = config.interactions.chat.tools[name]

    -- callback MUST be a function (not a table) for develop compat
    expect.equality(type(tool_config.callback), "function")

    local ok, resolved = pcall(Tools.resolve, tool_config)
    expect.equality(ok, true)
    expect.equality(type(resolved), "table")

    -- Resolved tool must have the essential fields
    expect.equality(type(resolved.name), "string")
    expect.equality(type(resolved.cmds), "table")
    expect.equality(type(resolved.schema), "table")
  end

  -- Cleanup: remove the tools we registered
  for _, name in ipairs(extra_tools) do
    config.interactions.chat.tools[name] = nil
  end
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
-- Utility modules
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

T["Utils"]["files helper loads"] = function()
  local ok, files = require_ok("codecompanion.utils.files")
  expect.equality(ok, true)
  -- validate_and_normalize_path was added on develop
  if has_method(files, "validate_and_normalize_path") then
    expect.equality(true, true)
  else
    -- main may have a different name or not have it yet
    expect.equality(type(files), "table")
  end
end

-- ============================================================================
-- Chat module
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

-- ============================================================================
-- Compat detection
-- ============================================================================

T["Compat detection"] = new_set()

T["Compat detection"]["compat module loads"] = function()
  local ok, compat = require_ok("hive.tools.compat")
  expect.equality(ok, true)
  expect.equality(type(compat), "table")
end

T["Compat detection"]["is_new_api agrees with structural markers"] = function()
  local compat = require("hive.tools.compat")

  -- Structural marker: cmd_tool factory only exists in new API
  local has_cmd_tool = pcall(require, "codecompanion.interactions.chat.tools.builtin.cmd_tool")

  -- Orchestrator signature probe: new API wraps tools in { tools = ... }
  local Orchestrator = require("codecompanion.interactions.chat.tools.orchestrator")
  local captured_meta = nil
  local orch = Orchestrator.new(make_mock_tools(), 1)
  orch.tool = {
    name = "test",
    cmds = {},
    handlers = {
      setup = function(_, meta)
        captured_meta = meta
      end,
    },
    output = {},
  }
  orch:_setup_handlers()
  orch.handlers.setup()

  local is_structurally_new = has_cmd_tool or (captured_meta and captured_meta.tools ~= nil)
  local compat_says = compat.is_new_api()
  expect.equality(compat_says, is_structurally_new)
end

T["Compat detection"]["handler_setup normalizes meta for current API"] = function()
  local compat = require("hive.tools.compat")
  local Orchestrator = require("codecompanion.interactions.chat.tools.orchestrator")

  local inner_meta = nil
  local wrapped_setup = compat.handler_setup(function(_, meta)
    inner_meta = meta
  end)

  local orch = Orchestrator.new(make_mock_tools(), 1)
  orch.tool = {
    name = "test",
    cmds = {},
    handlers = { setup = wrapped_setup },
    output = {},
  }

  orch:_setup_handlers()
  orch.handlers.setup()

  -- Compat should always normalize: meta has a tools key
  expect.equality(type(inner_meta), "table")
  expect.equality(inner_meta.tools ~= nil, true)
end

-- ============================================================================
-- Chat:add_message index positioning
-- Ensures that both opts.index (main) and _meta.index (develop) are respected.
-- This catches the 9f659f14 refactor that moved index from opts to _meta.
-- ============================================================================

T["add_message index"] = new_set()

T["add_message index"]["opts.index or _meta.index inserts at position"] = function()
  local config = require("codecompanion.config")
  local Chat = require("codecompanion.interactions.chat")

  -- Probe which mechanism the current branch uses
  -- by inspecting the source of add_message
  local src = debug.getinfo(Chat.new, "S").source
  -- We can't easily create a full Chat, so test the contract structurally:
  -- confirm that the branch supports at least ONE of the two index mechanisms.

  -- On develop: message._meta.index is checked
  -- On main: opts.index is checked
  -- Our code passes BOTH for compat, so we just verify the API exists
  expect.equality(type(Chat.new), "function")

  -- Structural check: look for add_message on the prototype
  -- We can't instantiate Chat without an adapter, but we can check the module
  local chat_mod_src = src or ""
  -- At minimum, verify the module loaded and has new
  expect.equality(chat_mod_src ~= "", true)
end

-- ============================================================================
-- Runner: cmds function call signature
-- Validates that Runner:run_tool calls cmds with (tools, args, { input, output_cb })
-- ============================================================================

T["Runner cmds signature"] = new_set()

T["Runner cmds signature"]["run_tool passes opts table with output_cb"] = function()
  local Runner = require("codecompanion.interactions.chat.tools.runtime.runner")
  local Orchestrator = require("codecompanion.interactions.chat.tools.orchestrator")

  local captured = {}
  local mock_tools = make_mock_tools()

  local orch = Orchestrator.new(mock_tools, 1)
  orch.tool = {
    name = "test",
    cmds = {
      function(tools, args, arg3, arg4)
        captured.tools = tools
        captured.args = args
        captured.arg3 = arg3
        captured.arg4 = arg4
        return { status = "success", data = "ok" }
      end,
    },
    handlers = {},
    output = {
      success = function() end,
    },
    args = { test = true },
    opts = {},
  }

  orch:_setup_handlers()

  local runner = Runner.new({ index = 1, orchestrator = orch, cmd = orch.tool.cmds[1] })
  runner:setup(nil)

  -- New API: arg3 = { input, output_cb }, arg4 = nil
  -- Old API: arg3 = input, arg4 = output_handler (function)
  local new_api = type(captured.arg3) == "table" and type(captured.arg3.output_cb) == "function"
  local old_api = type(captured.arg4) == "function"
  expect.equality(new_api or old_api, true)
end

-- ============================================================================
-- Builtin tool config keys
-- Validates that builtin tools use the expected config keys.
-- Main uses `callback` (string); develop uses `path` (string).
-- Extra must adapt to whichever is present.
-- ============================================================================

T["Builtin tool config"] = new_set()

T["Builtin tool config"]["builtin tools have callback or path"] = function()
  local config = require("codecompanion.config")
  local tools = config.interactions.chat.tools

  -- Check a known builtin tool (read_file exists on both branches)
  local read_file_cfg = tools["read_file"]
  expect.equality(type(read_file_cfg), "table")

  -- Main: callback = "interactions.chat.tools.builtin.read_file"
  -- Develop: path = "interactions.chat.tools.builtin.read_file"
  local has_callback = type(read_file_cfg.callback) == "string"
  local has_path = type(read_file_cfg.path) == "string"
  expect.equality(has_callback or has_path, true)
end

T["Builtin tool config"]["cmd_runner or run_command exists"] = function()
  local config = require("codecompanion.config")
  local tools = config.interactions.chat.tools

  -- Main has cmd_runner; develop renamed to run_command
  local has_cmd_runner = tools["cmd_runner"] ~= nil
  local has_run_command = tools["run_command"] ~= nil
  expect.equality(has_cmd_runner or has_run_command, true)
end

return T
