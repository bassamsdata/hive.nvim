local MiniTest = require("mini.test")
local T = MiniTest.new_set()

local snapshot = require("hive.session.snapshot")
local store = require("hive.session.store")

local root_dir = store.root_dir()

local function cleanup_session(id)
  pcall(store.delete, id)
end

T["snapshot"] = MiniTest.new_set()

T["snapshot"]["captures durable chat state"] = function()
  local chat = {
    adapter = {
      type = "http",
      name = "openrouter",
      schema = {
        model = { default = "anthropic/claude-sonnet-4" },
      },
    },
    settings = {
      model = "anthropic/claude-sonnet-4",
      temperature = 0,
    },
    title = "Session Title",
    cycle = 3,
    header_line = 9,
    intro_message = "Intro",
    _last_role = "llm",
    messages = {
      { role = "system", content = "system" },
      { role = "user", content = "hello" },
      { role = "llm", content = "world" },
    },
    context_items = {
      { id = "<tool>read_file</tool>", source = "tool", opts = { visible = true } },
    },
    tool_registry = {
      flags = { ignore_tool_system_prompt = true },
      groups = { files = { "read_file" } },
      in_use = { read_file = true },
      schemas = { ["<tool>read_file</tool>"] = { name = "read_file" } },
    },
    builder = {
      state = {
        last_role = "llm",
        block_index = 2,
      },
    },
    ui = {
      tokens = 42,
      window_opts = { layout = "vertical" },
    },
    bufnr = 11,
    buffer_context = {
      bufnr = 5,
      path = "/tmp/example.lua",
    },
  }

  local original_api = vim.api
  vim.api = setmetatable({
    nvim_buf_get_lines = function(bufnr, start, finish, strict)
      return {
        "## User --------------------------------------------------",
        "hello",
        "",
        "Searched files for `**/twinchat*`, no results",
      }
    end,
  }, { __index = original_api })

  package.loaded["hive.agents"] = {
    active = function(bufnr)
      return bufnr == 11 and "build" or nil
    end,
  }

  package.loaded["hive.agents.hierarchy"] = {
    get_session = function(bufnr)
      if bufnr ~= 11 then return nil end
      return {
        description = "Implement feature",
        hidden = false,
        agent_type = "agent",
      }
    end,
  }

  local data = snapshot.capture(chat, {
    draft = "unfinished prompt",
    saved_at = 123,
    session_id = "example-session",
  })

  MiniTest.expect.equality(2, data.version)
  MiniTest.expect.equality("example-session", data.session.id)
  MiniTest.expect.equality(123, data.session.saved_at)
  MiniTest.expect.equality("openrouter", data.adapter.name)
  MiniTest.expect.equality("anthropic/claude-sonnet-4", data.adapter.model)
  MiniTest.expect.equality("Session Title", data.chat.title)
  MiniTest.expect.equality(3, data.chat.cycle)
  MiniTest.expect.equality(9, data.chat.header_line)
  MiniTest.expect.equality("unfinished prompt", data.draft)
  MiniTest.expect.equality(true, #data.messages == 3)
  MiniTest.expect.equality(true, data.tool_registry.in_use.read_file)
  MiniTest.expect.equality(42, data.ui.tokens)
  MiniTest.expect.equality("/tmp/example.lua", data.metadata.source_path)
  MiniTest.expect.equality("build", data.chat.agent.name)
  MiniTest.expect.equality("Implement feature", data.hierarchy.description)
  MiniTest.expect.equality(2, data.chat.builder_state.block_index)
  MiniTest.expect.equality("Searched files for `**/twinchat*`, no results", data.chat.buffer_lines[4])

  vim.api = original_api
  package.loaded["hive.agents"] = nil
  package.loaded["hive.agents.hierarchy"] = nil
end

T["snapshot"]["removes non serializable values"] = function()
  local original_api = vim.api
  vim.api = setmetatable({
    nvim_buf_get_lines = function()
      return { "## User --------------------------------------------------", "hello" }
    end,
  }, { __index = original_api })

  local chat = {
    adapter = {
      type = "http",
      name = "openrouter",
      schema = {
        model = { default = "test-model" },
      },
    },
    bufnr = 7,
    messages = {
      {
        role = "user",
        content = "hello",
        callback = function()
        end,
      },
    },
    tool_registry = {
      flags = {},
      groups = {},
      in_use = {},
      schemas = {},
    },
    ui = {},
  }

  local data = snapshot.capture(chat)
  MiniTest.expect.equality(nil, data.messages[1].callback)

  vim.api = original_api
end

T["store"] = MiniTest.new_set({
  hooks = {
    post_case = function()
      vim.fn.mkdir(root_dir, "p")
      local files = vim.fn.globpath(root_dir, "*.json", false, true)
      for _, filepath in ipairs(files) do
        vim.fn.delete(filepath)
      end
    end,
  },
})

T["store"]["writes reads lists and deletes sessions"] = function()
  local session_id = "session-store-test"
  local data = {
    session = {
      id = session_id,
      saved_at = 321,
      summary = "Stored session",
    },
    chat = {
      title = "Stored Title",
    },
    adapter = {
      name = "openrouter",
      model = "anthropic/claude-sonnet-4",
    },
  }

  local filepath = store.write(session_id, data)
  MiniTest.expect.equality(1, vim.fn.filereadable(filepath))

  local restored, err = store.read(session_id)
  MiniTest.expect.equality(nil, err)
  if restored == nil then error("Expected restored session") end
  MiniTest.expect.equality("Stored session", restored.session.summary)

  local sessions = vim.tbl_filter(function(session)
    return session.id == session_id
  end, store.list())
  MiniTest.expect.equality(1, #sessions)
  MiniTest.expect.equality(session_id, sessions[1].id)

  MiniTest.expect.equality(true, store.delete(session_id))
  MiniTest.expect.equality(0, vim.fn.filereadable(filepath))

  cleanup_session(session_id)
end

return T
