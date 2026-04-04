local MiniTest = require("mini.test")

local expect = MiniTest.expect
local child = MiniTest.new_child_neovim()
local new_set = MiniTest.new_set

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "scripts/minimal_init.lua" })
      child.lua([[
        vim.opt.rtp:prepend(".")

        package.loaded["codecompanion.utils.log"] = {
          debug = function() end,
          info = function() end,
          warn = function() end,
          error = function() end,
          trace = function() end,
        }

        package.loaded["codecompanion.config"] = {
          constants = {
            SYSTEM_ROLE = "system",
            USER_ROLE = "user",
            LLM_ROLE = "llm",
          },
        }

        package.loaded["codecompanion.interactions.chat.tools.builtin.cmd_tool"] = {}
        package.loaded["hive.agents.navigation"] = {
          refresh_winbar = function() end,
        }

        package.loaded["hive.tools.compat"] = nil
        package.loaded["hive.tools.task"] = nil
        package.loaded["hive.tools.consult"] = nil
        package.loaded["hive.tools.subagent.models"] = nil
        package.loaded["hive.tools.subagent.messages"] = nil
        package.loaded["hive.tools.subagent.lifecycle"] = nil
        package.loaded["hive.agents.hierarchy"] = nil

        local config = require("hive.config")
        config.setup({
          agents = {
            small_model = nil,
            big_model = nil,
            confirm_expensive_models = {},
          },
          tools = {
            status = {
              scroll_to_show = false,
              scroll_cursor_distance = 5,
            },
          },
        })
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["subagent"] = new_set()
T["tools"] = new_set()

T["subagent"]["lifecycle uses explicit small model override when configured"] = function()
  local params = child.lua([[
    local lifecycle = require("hive.tools.subagent.lifecycle")
    vim.g.HIVE_SMALL_MODEL = "openai/gpt-4o-mini"

    local output = lifecycle.get_adapter_params({
      parent_chat = {
        adapter = {
          name = "parent_adapter",
          schema = { model = { default = "parent-model" } },
        },
      },
      model_type = "small",
    })

    vim.g.HIVE_SMALL_MODEL = nil
    return output
  ]])

  expect.equality(params, {
    adapter = "openai",
    model = "gpt-4o-mini",
  })
end

T["subagent"]["lifecycle inherits parent adapter when no override exists"] = function()
  local params = child.lua([[
    local lifecycle = require("hive.tools.subagent.lifecycle")
    vim.g.HIVE_SMALL_MODEL = nil

    return lifecycle.get_adapter_params({
      parent_chat = {
        adapter = {
          name = "copilot",
          schema = {
            model = {
              default = function()
                return "claude-sonnet"
              end,
            },
          },
        },
      },
      model_type = "small",
    })
  ]])

  expect.equality(params, {
    adapter = "copilot",
    model = "claude-sonnet",
  })
end

T["subagent"]["message extraction includes llm output tool summary and duration"] = function()
  local summary = child.lua([[
    local hierarchy = require("hive.agents.hierarchy")
    local messages = require("hive.tools.subagent.messages")
    hierarchy.clear()

    hierarchy.create_session({
      bufnr = 42,
      agent_name = "explorer",
      agent_type = "subagent",
      description = "Scan files",
    })

    hierarchy.start_timer(42)
    hierarchy.tool_started(42, "tool_1", "read_file")
    hierarchy.tool_finished(42, "tool_1", true, "Read lua/hive/agents/init.lua")
    hierarchy.set_status(42, "completed", "done")

    local child_chat = {
      messages = {
        [1] = { role = "system", content = "system" },
        [3] = { role = "llm", content = "Final answer from subagent" },
      },
    }

    local result, tool_count = messages.extract_result_with_tools({
      child_chat = child_chat,
      child_bufnr = 42,
    })

    return {
      result = result,
      tool_count = tool_count,
    }
  ]])

  expect.equality(summary.tool_count, 1)
  expect.equality(summary.result:find("Final answer from subagent", 1, true) ~= nil, true)
  expect.equality(summary.result:find("Tools executed:", 1, true) ~= nil, true)
  expect.equality(summary.result:find("read_file", 1, true) ~= nil, true)
  expect.equality(summary.result:find("Completed in", 1, true) ~= nil, true)
end

T["tools"]["task schema enum stays aligned with task subagent registry"] = function()
  local enums = child.lua([[
    local registry = require("hive.agents.registry")
    local task = require("hive.tools.task")

    local expected = registry.get_task_subagent_names()
    local actual = task.schema["function"].parameters.properties.tasks.items.properties.subagent_type.enum

    return {
      expected = expected,
      actual = actual,
    }
  ]])

  table.sort(enums.actual)
  table.sort(enums.expected)
  expect.equality(enums.actual, enums.expected)
end

T["tools"]["consult schema enum stays aligned with advisor registry"] = function()
  local enums = child.lua([[
    local registry = require("hive.agents.registry")
    local consult = require("hive.tools.consult")

    local expected = registry.get_advisor_names()
    local actual = consult.schema["function"].parameters.properties.advisor_type.enum

    return {
      expected = expected,
      actual = actual,
    }
  ]])

  table.sort(enums.actual)
  table.sort(enums.expected)
  expect.equality(enums.actual, enums.expected)
end

T["tools"]["swarm worker no-arg schemas encode empty properties as objects"] = function()
  local result = child.lua([[
    local worker = require("hive.swarm.tools.worker")

    local read_messages = worker.get("read_messages")
    local get_swarm_status = worker.get("get_swarm_status")

    return {
      read_messages = vim.json.decode(vim.json.encode(read_messages.schema["function"].parameters)),
      get_swarm_status = vim.json.decode(vim.json.encode(get_swarm_status.schema["function"].parameters)),
    }
  ]])

  expect.equality(result.read_messages, {
    type = "object",
    properties = {},
  })
  expect.equality(result.get_swarm_status, {
    type = "object",
    properties = {},
  })
end

T["tools"]["task cmds reports error for empty task list"] = function()
  local result = child.lua([[
    local task = require("hive.tools.task")
    local callback_result = nil

    task.cmds[1]({
      chat = { bufnr = 1 },
    }, {
      tasks = {},
    }, {
      output_cb = function(res)
        callback_result = res
      end,
    })

    return callback_result
  ]])

  expect.equality(result.status, "error")
  expect.equality(result.data:find("No tasks provided", 1, true) ~= nil, true)
end

T["tools"]["consult cmds rejects non advisor subagent types"] = function()
  local result = child.lua([[
    local consult = require("hive.tools.consult")
    local callback_result = nil

    consult.cmds[1]({
      chat = { bufnr = 1 },
    }, {
      advisor_type = "explorer",
      question = "Can you review this?",
      description = "Need advice",
    }, {
      output_cb = function(res)
        callback_result = res
      end,
    })

    return callback_result
  ]])

  expect.equality(result.status, "error")
  expect.equality(result.data:find("not an advisor", 1, true) ~= nil, true)
end

T["tools"]["task cmds executes mocked subagents and returns consolidated result"] = function()
  local result = child.lua([=[
    package.loaded["hive.tools.task"] = nil
    package.loaded["hive.tools.subagent"] = nil
    package.loaded["hive.tools.subagent.models"] = nil

    local hierarchy = require("hive.agents.hierarchy")
    hierarchy.clear()

    local function make_timer()
      return {
        stop = function() end,
        close = function() end,
        is_closing = function()
          return false
        end,
      }
    end

    local next_bufnr = 500
    local lifecycle = {}

    lifecycle.spawn_child = function(_args)
      next_bufnr = next_bufnr + 1
      local child_chat = {
        bufnr = next_bufnr,
        status = "success",
        stop = function() end,
      }
      return child_chat, next_bufnr
    end

    lifecycle.setup_listeners = function(args)
      if args.callbacks.on_tool_started then
        args.callbacks.on_tool_started({ data = { bufnr = args.child_bufnr, tool = "read_file" } }, "read_file")
      end
      if args.callbacks.on_tool_finished then
        args.callbacks.on_tool_finished({ data = { bufnr = args.child_bufnr, name = "read_file" } }, "read_file")
      end
      if args.callbacks.on_done then args.callbacks.on_done({ data = { bufnr = args.child_bufnr } }) end
      return args.child_bufnr + 1000
    end

    lifecycle.cleanup_listeners = function() end

    package.loaded["hive.tools.subagent"] = {
      utils = {
        SPINNER_FRAMES = { "-" },
        STATUS_ICONS = {
          pending = ".",
          running = ">",
          completed = "✓",
          failed = "✗",
          cancelled = "x",
          timer = "t",
          tools = "u",
        },
        IDLE_TIMEOUT_MS = 120000,
        capitalize = function(name)
          return name:sub(1, 1):upper() .. name:sub(2)
        end,
        format_duration = function(_ms)
          return "1.0s"
        end,
        get_elapsed_ms = function(_start)
          return 1000
        end,
        create_spinner_timer = function(_args)
          return make_timer()
        end,
        create_timeout_timer = function(_args)
          return make_timer()
        end,
        safe_close_timer = function(timer)
          if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
          end
        end,
        fire = function() end,
        truncate = function(text, _max)
          return text
        end,
      },
      status = {
        render = function() end,
        clear = function() end,
        clear_after_delay = function() end,
      },
      lifecycle = lifecycle,
      messages = {
        extract_result_with_tools = function(args)
          return "Result from " .. tostring(args.child_bufnr), 1
        end,
      },
    }

    package.loaded["hive.tools.subagent.models"] = {
      detect_suspicious_fast_completion = function(_args)
        return false, nil
      end,
    }

    local task = require("hive.tools.task")
    local callback_result = nil

    task.cmds[1]({
      chat = { bufnr = 77 },
    }, {
      tasks = {
        { subagent_type = "explorer", description = "Scan files", prompt = "Find key files" },
        { subagent_type = "analyzer", description = "Check diagnostics", prompt = "Find issues" },
      },
    }, {
      output_cb = function(res)
        callback_result = res
      end,
    })

    return callback_result
  ]=])

  expect.equality(result.status, "success")
  expect.equality(result.data:find('<subagent_result agent="explorer"', 1, true) ~= nil, true)
  expect.equality(result.data:find('<subagent_result agent="analyzer"', 1, true) ~= nil, true)
  expect.equality(result.data:find("2 succeeded", 1, true) ~= nil, true)
end

T["tools"]["consult cmds executes mocked advisor and returns consultation result"] = function()
  local result = child.lua([=[
    package.loaded["hive.tools.consult"] = nil
    package.loaded["hive.tools.subagent"] = nil
    package.loaded["hive.tools.subagent.models"] = nil

    local hierarchy = require("hive.agents.hierarchy")
    hierarchy.clear()

    local function make_timer()
      return {
        stop = function() end,
        close = function() end,
        is_closing = function()
          return false
        end,
      }
    end

    local lifecycle = {}
    lifecycle.spawn_child = function(_args)
      local child_chat = {
        bufnr = 901,
        status = "success",
        stop = function() end,
      }
      return child_chat, 901
    end

    lifecycle.setup_listeners = function(args)
      if args.callbacks.on_tool_started then
        args.callbacks.on_tool_started({ data = { bufnr = args.child_bufnr, tool = "read_file" } }, "read_file")
      end
      if args.callbacks.on_tool_finished then
        args.callbacks.on_tool_finished({ data = { bufnr = args.child_bufnr, name = "read_file" } }, "read_file")
      end
      if args.callbacks.on_done then args.callbacks.on_done({ data = { bufnr = args.child_bufnr } }) end
      return 1901
    end

    lifecycle.cleanup_listeners = function() end

    package.loaded["hive.tools.subagent"] = {
      utils = {
        SPINNER_FRAMES = { "-" },
        STATUS_ICONS = {
          pending = ".",
          running = ">",
          completed = "✓",
          failed = "✗",
          cancelled = "x",
          timer = "t",
          tools = "u",
        },
        IDLE_TIMEOUT_MS = 120000,
        capitalize = function(name)
          return name:sub(1, 1):upper() .. name:sub(2)
        end,
        format_duration = function(_ms)
          return "2.0s"
        end,
        get_elapsed_ms = function(_start)
          return 2000
        end,
        create_spinner_timer = function(_args)
          return make_timer()
        end,
        create_timeout_timer = function(_args)
          return make_timer()
        end,
        safe_close_timer = function(timer)
          if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
          end
        end,
        fire = function() end,
        truncate = function(text, _max)
          return text
        end,
      },
      status = {
        render = function() end,
        clear = function() end,
        clear_after_delay = function() end,
      },
      lifecycle = lifecycle,
      messages = {
        extract_result = function(_chat, _fallback)
          return "Advisor recommendation"
        end,
      },
    }

    package.loaded["hive.tools.subagent.models"] = {
      detect_suspicious_fast_completion = function(_args)
        return false, nil
      end,
    }

    local consult = require("hive.tools.consult")
    local callback_result = nil

    consult.cmds[1]({
      chat = { bufnr = 88 },
    }, {
      advisor_type = "sage",
      question = "Should we refactor this module?",
      description = "Architecture review",
    }, {
      output_cb = function(res)
        callback_result = res
      end,
    })

    return callback_result
  ]=])

  expect.equality(result.status, "success")
  expect.equality(result.data:find('<consultation_result id="consult_', 1, true) ~= nil, true)
  expect.equality(result.data:find('advisor="sage"', 1, true) ~= nil, true)
  expect.equality(result.data:find("Advisor recommendation", 1, true) ~= nil, true)
end

return T
