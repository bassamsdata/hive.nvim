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

        local function make_chat(bufnr)
          return {
            bufnr = bufnr,
            hidden = true,
            status = "ready",
            messages = {},
            submits = 0,
            stopped = false,
            tool_outputs = {},
            tool_registry = {
              in_use = {},
              add = function(self, name)
                self.in_use[name] = true
              end,
              add_tool_system_prompt = function() end,
            },
            add_message = function(self, message)
              table.insert(self.messages, vim.deepcopy(message))
            end,
            add_tool_output = function(self, _tool, output)
              table.insert(self.tool_outputs, output)
            end,
            submit = function(self)
              self.submits = self.submits + 1
            end,
            stop = function(self)
              self.stopped = true
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
        }

        package.loaded["hive.agents.navigation"] = {
          refresh_winbar = function() end,
        }

        package.loaded["hive.agents"] = {
          activate = function()
            return true
          end,
        }

        package.loaded["hive.agents.hierarchy"] = {
          create_session = function() end,
          start_timer = function() end,
          set_status = function() end,
          tool_started = function() end,
          tool_finished = function() end,
          get_parent = function()
            return 0
          end,
        }

        package.loaded["hive.tools.subagent"] = {
          utils = {
            create_timeout_timer = function()
              return make_timer()
            end,
            safe_close_timer = function(timer)
              if timer and not timer:is_closing() then
                timer:stop()
                timer:close()
              end
            end,
          },
          lifecycle = {
            create_child_chat = function(_args)
              local bufnr = vim.api.nvim_create_buf(false, true)
              return make_chat(bufnr)
            end,
            hide_child_restore_parent = function() end,
            create_hierarchy_session = function() end,
            setup_listeners = function()
              return 1
            end,
            cleanup_listeners = function() end,
          },
          status = {
            render = function() end,
            clear = function() end,
            clear_after_delay = function() end,
          },
        }

        package.loaded["hive.team.runtime"] = nil
        package.loaded["hive.team.state"] = nil
        package.loaded["hive.team.messages"] = nil
        package.loaded["hive.team.hooks"] = nil
        package.loaded["hive.team.tasks"] = nil
        package.loaded["hive.team.worker"] = nil
        package.loaded["hive.tools.team"] = nil
        package.loaded["hive.notify_controller"] = {
          instance = function()
            return {
              notify = function() end,
            }
          end,
        }
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["team"] = new_set()

T["team"]["runtime creates persistent teammates and assigns explicit tasks"] = function()
  local result = child.lua([[
    local runtime_mod = require("hive.team.runtime")
    runtime_mod.TeamRuntime.clear_all()

    local manager_bufnr = vim.api.nvim_create_buf(false, true)
    local team = runtime_mod.TeamRuntime.new({
      name = "delivery",
      manager_chat = { bufnr = manager_bufnr },
    })

    local member = assert(team:add_member({
      name = "builder",
      role = "implementer",
      system_prompt = "Build carefully",
      tools = { "read_file", "insert_edit_into_file" },
    }))

    local task = assert(team:assign_task({
      to = "builder",
      content = "Implement feature X",
      title = "Feature X",
    }))

    local teammate = team.teammates.builder
    local state_member = team.state.members.builder

    return {
      team_id = team.state.id,
      member_id = member.id,
      task_id = task.id,
      teammate_status = teammate.status,
      member_status = state_member.status,
      current_task = state_member.current_task_id,
      submit_count = teammate.chat.submits,
      last_message = teammate.chat.messages[#teammate.chat.messages].content,
    }
  ]])

  expect.equality(result.team_id, "team_1")
  expect.equality(result.member_id, "builder@team_1")
  expect.equality(result.task_id, "task_1")
  expect.equality(result.teammate_status, "running")
  expect.equality(result.member_status, "running")
  expect.equality(result.current_task, "task_1")
  expect.equality(result.submit_count, 1)
  expect.equality(result.last_message:find("Current task: task_1", 1, true) ~= nil, true)
end

T["team"]["worker tool completes the current team task explicitly"] = function()
  local result = child.lua([[
    local runtime_mod = require("hive.team.runtime")
    local worker = require("hive.team.worker")
    runtime_mod.TeamRuntime.clear_all()

    local manager_bufnr = vim.api.nvim_create_buf(false, true)
    local team = runtime_mod.TeamRuntime.new({
      name = "delivery",
      manager_chat = { bufnr = manager_bufnr },
    })

    assert(team:add_member({
      name = "builder",
      system_prompt = "Build carefully",
    }))

    assert(team:assign_task({
      to = "builder",
      content = "Implement feature X",
    }))

    local teammate = team.teammates.builder
    team.state:set_member_status("builder", "idle")
    teammate.status = "idle"

    local tool = worker.get("complete_team_task")
    local response = tool.cmds[1]({
      chat = { bufnr = teammate.bufnr, add_tool_output = function() end },
    }, {
      result = "Implemented feature X",
    }, {})

    local task = team.tasks:get("task_1")

    return {
      response = response,
      task_status = task.status,
      task_result = task.result,
      current_task = team.state.members.builder.current_task_id,
      leader_unread = team.mailbox:count_unread("leader"),
    }
  ]])

  expect.equality(result.response.status, "success")
  expect.equality(result.task_status, "completed")
  expect.equality(result.task_result, "Implemented feature X")
  expect.equality(result.current_task == nil or result.current_task == vim.NIL, true)
  expect.equality(result.leader_unread, 1)
end

T["team"]["queued leader messages wake idle teammates again"] = function()
  local result = child.lua([[
    local runtime_mod = require("hive.team.runtime")
    runtime_mod.TeamRuntime.clear_all()

    local manager_bufnr = vim.api.nvim_create_buf(false, true)
    local team = runtime_mod.TeamRuntime.new({
      name = "delivery",
      manager_chat = { bufnr = manager_bufnr },
    })

    assert(team:add_member({
      name = "validator",
      system_prompt = "Validate carefully",
    }))

    assert(team:assign_task({
      to = "validator",
      content = "Validate the current diff",
    }))

    local teammate = team.teammates.validator
    local first_submit = teammate.chat.submits

    local _, err = team:send_message({
      to = "validator",
      content = "Also check diagnostics after the diff review",
      priority = "urgent",
    })

    local unread_while_running = team.mailbox:count_unread("validator")

    team.state:set_member_status("validator", "idle")
    teammate.status = "idle"
    team:on_member_idle("validator")

    return {
      err = err,
      first_submit = first_submit,
      second_submit = teammate.chat.submits,
      unread_after_idle = team.mailbox:count_unread("validator"),
      current_task = team.state.members.validator.current_task_id,
      last_prompt = teammate.chat.messages[#teammate.chat.messages].content,
      unread_while_running = unread_while_running,
    }
  ]])

  expect.equality(result.err == nil or result.err == vim.NIL, true)
  expect.equality(result.first_submit, 1)
  expect.equality(result.unread_while_running, 1)
  expect.equality(result.second_submit, 2)
  expect.equality(result.unread_after_idle, 0)
  expect.equality(result.current_task, "task_1")
  expect.equality(result.last_prompt:find("Also check diagnostics", 1, true) ~= nil, true)
end

T["team"]["manager tool creates a separate active team"] = function()
  local result = child.lua([[
    local runtime_mod = require("hive.team.runtime")
    runtime_mod.TeamRuntime.clear_all()

    local tool = require("hive.tools.team")
    local bufnr = vim.api.nvim_create_buf(false, true)

    local response = tool.cmds[1]({
      chat = { bufnr = bufnr },
    }, {
      command = "create",
      name = "platform",
      members = {
        {
          name = "builder",
          system_prompt = "Build carefully",
          tools = { "read_file" },
        },
        {
          name = "validator",
          system_prompt = "Review carefully",
          tools = { "get_diagnostics" },
        },
      },
    }, {})

    local active = runtime_mod.TeamRuntime.get_active(bufnr)

    return {
      response = response,
      active_name = active and active.state.name or nil,
      member_count = active and vim.tbl_count(active.state.members) or 0,
    }
  ]])

  expect.equality(result.response.status, "success")
  expect.equality(result.active_name, "platform")
  expect.equality(result.member_count, 2)
end

T["team"]["task completed hook creates validator follow-up work"] = function()
  local result = child.lua([[
    local runtime_mod = require("hive.team.runtime")
    runtime_mod.TeamRuntime.clear_all()

    local manager_bufnr = vim.api.nvim_create_buf(false, true)
    local team = runtime_mod.TeamRuntime.new({
      name = "delivery",
      manager_chat = { bufnr = manager_bufnr },
    })

    assert(team:add_member({
      name = "builder",
      role = "implementer",
      system_prompt = "Build carefully",
    }))
    assert(team:add_member({
      name = "validator",
      role = "validator",
      system_prompt = "Validate carefully",
    }))

    assert(team:assign_task({
      to = "builder",
      content = "Implement feature X",
      title = "Feature X",
    }))

    local builder = team.teammates.builder
    team.state:set_member_status("builder", "idle")
    builder.status = "idle"

    assert(team:complete_current_task("builder", "Implemented feature X"))

    local tasks = team:list_tasks()
    local validation_task = tasks[2]
    local validator = team.teammates.validator

    return {
      task_count = #tasks,
      validation_kind = validation_task.kind,
      validation_role = validation_task.target_role,
      validation_source = validation_task.source_task_id,
      validator_current_task = team.state.members.validator.current_task_id,
      validator_submit_count = validator.chat.submits,
      leader_unread = team.mailbox:count_unread("leader"),
    }
  ]])

  expect.equality(result.task_count, 2)
  expect.equality(result.validation_kind, "validation")
  expect.equality(result.validation_role, "validator")
  expect.equality(result.validation_source, "task_1")
  expect.equality(result.validator_current_task, "task_2")
  expect.equality(result.validator_submit_count, 1)
  expect.equality(result.leader_unread, 1)
end

T["team"]["leader can inspect shared tasks and inbox through team tool"] = function()
  local result = child.lua([[
    local runtime_mod = require("hive.team.runtime")
    runtime_mod.TeamRuntime.clear_all()

    local tool = require("hive.tools.team")
    local bufnr = vim.api.nvim_create_buf(false, true)

    assert(tool.cmds[1]({
      chat = { bufnr = bufnr },
    }, {
      command = "create",
      name = "platform",
      members = {
        {
          name = "builder",
          role = "implementer",
          system_prompt = "Build carefully",
        },
        {
          name = "validator",
          role = "validator",
          system_prompt = "Review carefully",
        },
      },
    }, {}).status == "success")

    local team = runtime_mod.TeamRuntime.get_active(bufnr)
    assert(team:create_task({
      title = "Audit release",
      content = "Review the release notes",
      kind = "research",
      target_role = "validator",
    }))

    team:send_update("builder", "Build is ready for review", "urgent")

    local tasks_output = tool.cmds[1]({
      chat = { bufnr = bufnr },
    }, {
      command = "list_tasks",
    }, {})

    local inbox_output = tool.cmds[1]({
      chat = { bufnr = bufnr },
    }, {
      command = "read_inbox",
    }, {})

    return {
      tasks_output = tasks_output.data,
      inbox_output = inbox_output.data,
      leader_unread_after = team.mailbox:count_unread("leader"),
    }
  ]])

  expect.equality(result.tasks_output:find("Audit release", 1, true) ~= nil, true)
  expect.equality(result.tasks_output:find("role=validator", 1, true) ~= nil, true)
  expect.equality(result.inbox_output:find("Build is ready for review", 1, true) ~= nil, true)
  expect.equality(result.leader_unread_after, 0)
end

return T
