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

        local function make_timer()
          return {
            stop = function() end,
            close = function() end,
            is_closing = function()
              return false
            end,
          }
        end

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
          interactions = {
            chat = {
              tools = {},
            },
          },
        }

        package.loaded["hive.agents.navigation"] = {
          refresh_winbar = function() end,
        }

        package.loaded["hive.agents"] = {
          activate = function() end,
        }

        package.loaded["hive.agents.hierarchy"] = {
          start_timer = function() end,
          set_status = function() end,
          get_parent = function()
            return 0
          end,
          tool_started = function() end,
          tool_finished = function() end,
        }

        package.loaded["hive.tools.subagent"] = {
          utils = {
            STATUS_ICONS = {},
            create_timeout_timer = function(_args)
              return make_timer()
            end,
            create_spinner_timer = function(_args)
              return make_timer()
            end,
            safe_close_timer = function(timer)
              if timer and not timer:is_closing() then
                timer:stop()
                timer:close()
              end
            end,
            get_elapsed_ms = function(_start)
              return 3000
            end,
            fire = function() end,
          },
          status = {
            render = function() end,
            clear = function() end,
            clear_after_delay = function() end,
          },
          lifecycle = {
            cleanup_listeners = function() end,
          },
        }

        package.loaded["hive.tools.subagent.models"] = {
          detect_suspicious_fast_completion = function(_args)
            return false, nil
          end,
        }

        package.loaded["hive.swarm.session"] = nil
        package.loaded["hive.swarm.orchestrator"] = nil
        package.loaded["hive.swarm.agent"] = nil
        package.loaded["hive.swarm.tools.manager"] = nil
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["swarm"] = new_set()

T["swarm"]["manager normalizes task ids and numeric dependency aliases"] = function()
  local result = child.lua([[
    _G._captured_swarm_tasks = nil

    package.loaded["hive.swarm.orchestrator"] = {
      SwarmOrchestrator = {
        new = function(_args)
          return {
            session = { tasks = {} },
            define_agent = function(self, _agent)
              return self, nil
            end,
            define_tasks = function(self, tasks)
              _G._captured_swarm_tasks = vim.deepcopy(tasks)
              return self
            end,
            start = function()
              return true, nil
            end,
            stop = function() end,
          }
        end,
      },
    }

    local manager = require("hive.swarm.tools.manager")
    local tool = manager.get_tool()
    local bufnr = vim.api.nvim_create_buf(false, true)

    local result = tool.cmds[1]({
      chat = { bufnr = bufnr },
    }, {
      command = "start",
      agents = {
        { name = "builder", category = "build", system_prompt = "Build", tools = {} },
        { name = "reviewer", category = "review", system_prompt = "Review", tools = {} },
      },
      tasks = {
        { content = "Build main feature", category = "build" },
        { id = "ship_review", content = "Review result", category = "review", dependencies = { "1" } },
      },
    }, {
      output_cb = function() end,
    })

    manager.clear_all()

    return {
      status = result and result.status or "ok",
      error = result and result.data or nil,
      captured = _G._captured_swarm_tasks ~= nil,
      first_id = _G._captured_swarm_tasks and _G._captured_swarm_tasks[1].id or nil,
      second_id = _G._captured_swarm_tasks and _G._captured_swarm_tasks[2].id or nil,
      second_dep = _G._captured_swarm_tasks and _G._captured_swarm_tasks[2].dependencies[1] or nil,
      schema_has_id = tool.schema["function"].parameters.properties.tasks.items.properties.id ~= nil,
    }
  ]])

  expect.equality(result.status, "ok")
  expect.equality(result.error == nil or result.error == vim.NIL, true)
  expect.equality(result.captured, true)
  expect.equality(result.first_id, "task_1")
  expect.equality(result.second_id, "ship_review")
  expect.equality(result.second_dep, "task_1")
  expect.equality(result.schema_has_id, true)
end

T["swarm"]["session work state keeps validator waiting until dependencies finish"] = function()
  local result = child.lua([[
    local session_mod = require("hive.swarm.session")
    session_mod.clear_all()

    local session = session_mod.SwarmSession.new({
      manager_bufnr = 1,
      manager_chat = { bufnr = 1 },
    })

    session:add_agent({
      name = "builder",
      category = "build",
      system_prompt = "Build",
      tools = {},
    })
    session:add_agent({
      name = "validator",
      category = "validation",
      system_prompt = "Validate",
      tools = {},
    })

    local tasks = assert(session:add_tasks({
      { id = "task_build_1", content = "Implement part 1", category = "build" },
      { id = "task_build_2", content = "Implement part 2", category = "build" },
      {
        id = "task_validate",
        content = "Validate results",
        category = "validation",
        dependencies = { "task_build_1", "task_build_2" },
      },
    }))

    session:start()

    local waiting_before = session:get_agent_work_state("validator")

    session:claim_task("builder", "build")
    session:complete_task("builder", "done 1")
    local waiting_mid = session:get_agent_work_state("validator")

    session:claim_task("builder", "build")
    session:complete_task("builder", "done 2")
    local after = session:get_agent_work_state("validator")

    return {
      created_ids = { tasks[1].id, tasks[2].id, tasks[3].id },
      waiting_before = waiting_before,
      waiting_mid = waiting_mid,
      after = after,
    }
  ]])

  expect.equality(result.created_ids, { "task_build_1", "task_build_2", "task_validate" })
  expect.equality(result.waiting_before, "waiting")
  expect.equality(result.waiting_mid, "waiting")
  expect.equality(result.after, "claimable")
end

T["swarm"]["reconcile wakes idle agents when work becomes claimable"] = function()
  local result = child.lua([[
    local session_mod = require("hive.swarm.session")
    session_mod.clear_all()
    local orchestrator_mod = require("hive.swarm.orchestrator")

    local session = session_mod.SwarmSession.new({
      manager_bufnr = 2,
      manager_chat = { bufnr = 2 },
    })

    session:add_agent({
      name = "validator",
      category = "validation",
      system_prompt = "Validate",
      tools = {},
    })

    assert(session:add_tasks({
      { id = "task_validate", content = "Validate", category = "validation" },
    }))

    session:start()
    session:set_agent_status("validator", "idle")

    local wake_message = nil
    local orchestrator = setmetatable({
      session = session,
      session_id = session.id,
      agents = {
        validator = {
          name = "validator",
          _resubmit = function(_, message)
            wake_message = message
          end,
        },
      },
    }, {
      __index = orchestrator_mod.SwarmOrchestrator,
    })

    orchestrator:reconcile("test")

    return {
      wake_message = wake_message,
    }
  ]])

  expect.equality(type(result.wake_message), "string")
  expect.equality(result.wake_message:find("claim_task", 1, true) ~= nil, true)
end

T["swarm"]["reconcile fails fast when unresolved work cannot make progress"] = function()
  local result = child.lua([[
    local session_mod = require("hive.swarm.session")
    session_mod.clear_all()
    local orchestrator_mod = require("hive.swarm.orchestrator")

    local session = session_mod.SwarmSession.new({
      manager_bufnr = 3,
      manager_chat = { bufnr = 3 },
    })

    session:add_agent({
      name = "builder",
      category = "build",
      system_prompt = "Build",
      tools = {},
    })

    assert(session:add_tasks({
      { id = "task_blocked", content = "Blocked task", category = "build" },
    }))

    session:start()
    session.tasks.task_blocked.status = session_mod.TASK_STATUS.BLOCKED
    session:set_agent_status("builder", "idle")

    local failure = nil
    local orchestrator = setmetatable({
      session = session,
      session_id = session.id,
      agents = {
        builder = {
          name = "builder",
          _resubmit = function() end,
        },
      },
      fail = function(_, message)
        failure = message
      end,
    }, {
      __index = orchestrator_mod.SwarmOrchestrator,
    })

    orchestrator:reconcile("deadlock")

    return failure
  ]])

  expect.equality(type(result), "string")
  expect.equality(result:find("Deadlock", 1, true) ~= nil, true)
end

T["swarm"]["agent goes idle instead of completing when only waiting work remains"] = function()
  local result = child.lua([[
    local session_mod = require("hive.swarm.session")
    package.loaded["hive.swarm.session"] = {
      SESSION_STATUS = session_mod.SESSION_STATUS,
      get = function(_session_id)
        return {
          status = session_mod.SESSION_STATUS.ACTIVE,
          has_stop_signal = function()
            return false
          end,
          get_agent_work_state = function()
            return "waiting"
          end,
          set_agent_status = function() end,
        }
      end,
    }

    local agent_mod = require("hive.swarm.agent")
    local agent = agent_mod.SwarmAgent.new({
      name = "validator",
      category = "validation",
      session_id = "swarm_test",
      system_prompt = "Validate",
      tools = {},
    })

    agent.bufnr = 55
    agent.chat = { status = "success" }
    agent.started_at = vim.uv.hrtime()

    local idle_reason = nil
    local completed = false
    local failed = nil

    agent.enter_idle = function(_, reason)
      idle_reason = reason
    end
    agent.complete = function()
      completed = true
    end
    agent.fail = function(_, err)
      failed = err
    end

    agent:on_chat_done()

    return {
      idle_reason = idle_reason,
      completed = completed,
      failed = failed,
    }
  ]])

  expect.equality(type(result.idle_reason), "string")
  expect.equality(result.completed, false)
  expect.equality(result.failed == nil or result.failed == vim.NIL, true)
end

return T
