-- Tests for twinchat module
local MiniTest = require("mini.test")
local T = MiniTest.new_set()

local tokens = require("hive.twinchat.tokens")

T["tokens"] = MiniTest.new_set()

T["tokens"]["estimate_tokens"] = MiniTest.new_set()

T["tokens"]["estimate_tokens"]["returns 0 for nil content"] = function()
  MiniTest.expect.equality(0, tokens.estimate_tokens(nil))
end

T["tokens"]["estimate_tokens"]["returns 0 for empty string"] = function()
  MiniTest.expect.equality(0, tokens.estimate_tokens(""))
end

T["tokens"]["estimate_tokens"]["estimates tokens for short text"] = function()
  -- 100 characters / 4 = 25 tokens
  local text = string.rep("a", 100)
  MiniTest.expect.equality(25, tokens.estimate_tokens(text))
end

T["tokens"]["estimate_tokens"]["estimates tokens for medium text"] = function()
  -- 1000 characters / 4 = 250 tokens
  local text = string.rep("a", 1000)
  MiniTest.expect.equality(250, tokens.estimate_tokens(text))
end

T["tokens"]["estimate_tokens"]["rounds large values"] = function()
  -- 50000 characters / 4 = 12500 tokens -> rounded to 20000
  local text = string.rep("a", 50000)
  MiniTest.expect.equality(20000, tokens.estimate_tokens(text))
end

T["tokens"]["estimate_message_tokens"] = MiniTest.new_set()

T["tokens"]["estimate_message_tokens"]["handles simple message"] = function()
  local msg = {
    role = "user",
    content = "Hello world", -- 11 chars / 4 = 2.75 -> 2 tokens + 4 role overhead = 6
  }
  MiniTest.expect.equality(6, tokens.estimate_message_tokens(msg))
end

T["tokens"]["estimate_message_tokens"]["handles message with tool calls"] = function()
  local msg = {
    role = "llm",
    content = "Done",
    tools = {
      calls = {
        {
          id = "call_123",
          ["function"] = {
            name = "read_file",
            arguments = '{"filepath": "/test.lua"}',
          },
        },
      },
    },
  }
  local result = tokens.estimate_message_tokens(msg)
  MiniTest.expect.equality(true, result > 0)
end

T["tokens"]["estimate_message_tokens"]["handles reasoning content"] = function()
  local msg = {
    role = "llm",
    content = "Answer",
    reasoning = {
      content = "Thinking through this problem...", -- ~35 chars / 4 = ~9 tokens
    },
  }
  local result = tokens.estimate_message_tokens(msg)
  MiniTest.expect.equality(true, result > 10)
end

T["tokens"]["estimate_total_tokens"] = MiniTest.new_set()

T["tokens"]["estimate_total_tokens"]["sums multiple messages"] = function()
  local messages = {
    { role = "user", content = "Hello" }, -- ~5 tokens
    { role = "llm", content = "Hi there!" }, -- ~6 tokens
  }
  local total = tokens.estimate_total_tokens(messages)
  MiniTest.expect.equality(true, total > 0)
end

T["tokens"]["estimate_total_tokens"]["returns 0 for empty array"] = function()
  MiniTest.expect.equality(0, tokens.estimate_total_tokens({}))
end

T["tokens"]["estimate_total_tokens"]["returns 0 for nil"] = function()
  MiniTest.expect.equality(0, tokens.estimate_total_tokens(nil))
end

T["tokens"]["get_context_window"] = MiniTest.new_set()

T["tokens"]["get_context_window"]["returns known context window for gpt-4o"] = function()
  MiniTest.expect.equality(128000, tokens.get_context_window("openai", "gpt-4o"))
end

T["tokens"]["get_context_window"]["returns known context window for claude"] = function()
  MiniTest.expect.equality(200000, tokens.get_context_window("anthropic", "claude-sonnet-4"))
end

T["tokens"]["get_context_window"]["matches model prefix"] = function()
  MiniTest.expect.equality(128000, tokens.get_context_window("openai", "gpt-4o-2024-05-13"))
end

T["tokens"]["get_context_window"]["returns default for unknown model"] = function()
  MiniTest.expect.equality(128000, tokens.get_context_window("unknown", "unknown-model"))
end

T["tokens"]["get_context_window"]["handles nil model name"] = function()
  MiniTest.expect.equality(128000, tokens.get_context_window(nil, nil))
end

T["tokens"]["get_context_utilization"] = MiniTest.new_set()

T["tokens"]["get_context_utilization"]["calculates percentage correctly"] = function()
  local messages = {
    { role = "user", content = string.rep("a", 50000) }, -- ~12500 tokens
  }
  local percentage, estimated_tokens, context_window = tokens.get_context_utilization(messages, "openai", "gpt-4o")

  MiniTest.expect.equality(128000, context_window)
  MiniTest.expect.equality(true, estimated_tokens > 0)
  MiniTest.expect.equality(true, percentage > 0)
end

T["tokens"]["get_context_utilization"]["handles empty messages"] = function()
  local percentage, estimated_tokens, context_window = tokens.get_context_utilization({}, "openai", "gpt-4o")

  MiniTest.expect.equality(0, percentage)
  MiniTest.expect.equality(0, estimated_tokens)
  MiniTest.expect.equality(128000, context_window)
end

return T
