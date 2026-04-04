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

        local function tool(description)
          return {
            schema = {
              ["function"] = {
                description = description,
              },
            },
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
              keymaps = {},
              tools = {
                opts = {
                  auto_submit_errors = false,
                  auto_submit_success = false,
                },
                groups = {},
              },
            },
          },
        }

        package.loaded["codecompanion"] = {
          buf_get_chat = function(bufnr)
            return _G._chat_by_buf and _G._chat_by_buf[bufnr]
          end,
        }

        package.loaded["hive.tools.todo"] = {
          clear_todos = function() end,
          setup_keymap = function() end,
          get_todowrite = function()
            return tool("Write todos")
          end,
          get_todoread = function()
            return tool("Read todos")
          end,
        }

        package.loaded["hive.tools.task"] = tool("Task tool")
        package.loaded["hive.tools.ask_user"] = tool("Ask user tool")
        package.loaded["hive.tools.consult"] = tool("Consult tool")
        package.loaded["hive.tools.list_directory"] = tool("List directory tool")
        package.loaded["hive.tools.cmd_runner"] = tool("Command runner tool")
        package.loaded["hive.tools.subagent.model_picker"] = {
          setup = function() end,
        }
        package.loaded["hive.agent_manager"] = {
          toggle = function() end,
        }
        package.loaded["hive.skills"] = {
          has_skills = function()
            return false
          end,
        }
        package.loaded["hive.tools"] = {
          get = function()
            return nil
          end,
        }

        package.loaded["hive.agents.markdown"] = {
          default_dir = function()
            return ""
          end,
          load_from_dir = function()
            return {}
          end,
        }

        package.loaded["hive.agents.prompts"] = {
          get = function(agent_name, chat)
            local adapter_name = chat and chat.adapter and chat.adapter.name or "unknown"
            local model_name = chat and chat.adapter and chat.adapter.schema and chat.adapter.schema.model
                and chat.adapter.schema.model.default
              or ""
            return string.format("PROMPT:%s|Adapter:%s/%s", agent_name, adapter_name, model_name)
          end,
        }

        package.loaded["hive.agents.navigation"] = {
          setup = function() end,
          setup_winbar = function() end,
          flash_model_info = function() end,
          refresh_winbar = function() end,
        }

        _G._chat_by_buf = {}

        _G.new_chat = function(bufnr, model_name)
          local chat = {
            bufnr = bufnr,
            adapter = {
              name = "test_adapter",
              formatted_name = "test_adapter",
              schema = {
                model = {
                  default = model_name or "model-a",
                },
              },
            },
            messages = {
              {
                role = "system",
                content = "default system prompt",
                _meta = { tag = "system_prompt_from_config", index = 1 },
                opts = { visible = false },
              },
            },
            context_items = {},
            context = {
              clear_rendered = function() end,
              render = function() end,
            },
          }

          function chat:remove_tagged_message(tag)
            self.messages = vim
              .iter(self.messages)
              :filter(function(msg)
                return not (msg._meta and msg._meta.tag == tag)
              end)
              :totable()
          end

          function chat:add_message(data, opts)
            opts = opts or {}
            local message = {
              role = data.role,
              content = data.content,
              opts = { visible = opts.visible ~= false },
            }

            if opts.context then message.context = opts.context end
            if opts._meta then message._meta = vim.deepcopy(opts._meta) end

            local index = opts.index or (message._meta and message._meta.index)
            if index then
              table.insert(self.messages, index, message)
            else
              table.insert(self.messages, message)
            end
          end

          function chat:set_system_prompt()
            self:add_message({
              role = "system",
              content = "restored system prompt",
            }, {
              visible = false,
              _meta = { tag = "system_prompt_from_config", index = 1 },
            })
          end

          chat.tool_registry = {
            in_use = {},
            schemas = {},
            groups = {},
            add_single_tool = function() end,
          }

          function chat.tool_registry:add_group(group_name, opts)
            local tools_config = opts and opts.config or {}
            local group_config = tools_config.groups and tools_config.groups[group_name]
            if not group_config then return nil end

            self.groups[group_name] = vim.deepcopy(group_config.tools or {})
            table.insert(chat.context_items, { id = "<group>" .. group_name .. "</group>" })

            for _, tool_name in ipairs(group_config.tools or {}) do
              self.in_use[tool_name] = true
              self.schemas["<tool>" .. tool_name .. "</tool>"] = { name = tool_name }
            end

            return self
          end

          function chat.tool_registry:remove_group(group_name)
            local tools = self.groups[group_name]
            if not tools then return end

            for _, tool_name in ipairs(tools) do
              self.in_use[tool_name] = nil
              self.schemas["<tool>" .. tool_name .. "</tool>"] = nil
            end
            self.groups[group_name] = nil

            chat.context_items = vim.iter(chat.context_items):filter(function(item)
              if item.id == "<group>" .. group_name .. "</group>" then return false end
              return true
            end):totable()
          end

          function chat.tool_registry:add(tool_name)
            self.in_use[tool_name] = true
            self.schemas["<tool>" .. tool_name .. "</tool>"] = { name = tool_name }
            table.insert(chat.context_items, { id = "<tool>" .. tool_name .. "</tool>" })
          end

          function chat.tool_registry:add_tool_system_prompt()
            chat:remove_tagged_message("tool_system_prompt")
            chat:add_message({
              role = "system",
              content = "tool system prompt",
            }, {
              visible = false,
              _meta = { tag = "tool_system_prompt", index = 2 },
            })
          end

          _G._chat_by_buf[bufnr] = chat
          return chat
        end

        package.loaded["hive.agents"] = nil
        package.loaded["hive.agents.registry"] = nil
        package.loaded["hive.agents.hierarchy"] = nil

        local agents = require("hive.agents")
        agents.setup({
          load_default_agents = false,
          load_cwd_agents = false,
          keymap = {},
        })

        require("hive.agents.hierarchy").clear()
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["agents"] = new_set()

T["agents"]["activate applies plan agent prompt, tools, and session"] = function()
  local summary = child.lua([[
    local agents = require("hive.agents")
    local hierarchy = require("hive.agents.hierarchy")

    local chat = _G.new_chat(101, "model-a")
    local ok = agents.activate("plan", chat, { silent = true })

    local tags = {}
    local prompt_content = ""
    for _, msg in ipairs(chat.messages) do
      if msg._meta and msg._meta.tag then
        tags[msg._meta.tag] = (tags[msg._meta.tag] or 0) + 1
      end
      if msg._meta and msg._meta.tag == "agent_system_prompt" then prompt_content = msg.content end
    end

    local has_group = false
    for _, item in ipairs(chat.context_items) do
      if item.id == "<group>agent_plan</group>" then
        has_group = true
        break
      end
    end

    local session = hierarchy.get_session(chat.bufnr)

    return {
      ok = ok,
      active = agents.active(chat.bufnr),
      agent_prompt_count = tags.agent_system_prompt or 0,
      has_default_prompt = (tags.system_prompt_from_config or 0) > 0,
      has_group = has_group,
      has_task_tool = chat.tool_registry.in_use.task == true,
      session_agent = session and session.agent_name or "",
      session_type = session and session.agent_type or "",
      prompt_content = prompt_content,
    }
  ]])

  expect.equality(summary.ok, true)
  expect.equality(summary.active, "plan")
  expect.equality(summary.agent_prompt_count, 1)
  expect.equality(summary.has_default_prompt, false)
  expect.equality(summary.has_group, true)
  expect.equality(summary.has_task_tool, true)
  expect.equality(summary.session_agent, "plan")
  expect.equality(summary.session_type, "agent")
  expect.equality(summary.prompt_content:find("PROMPT:plan|Adapter:test_adapter/model-a", 1, true) ~= nil, true)
end

T["agents"]["cycle switches between build and plan in sorted order"] = function()
  local summary = child.lua([[
    local agents = require("hive.agents")
    local chat = _G.new_chat(102, "model-a")

    agents.activate("build", chat, { silent = true })
    agents._cycle_agent(chat)
    local first = agents.active(chat.bufnr)
    agents._cycle_agent(chat)
    local second = agents.active(chat.bufnr)

    return {
      first = first,
      second = second,
    }
  ]])

  expect.equality(summary.first, "plan")
  expect.equality(summary.second, "build")
end

T["agents"]["switching from plan to build adds reminder and cleans old group"] = function()
  local summary = child.lua([[
    local agents = require("hive.agents")
    local chat = _G.new_chat(103, "model-a")

    agents.activate("plan", chat, { silent = true })
    agents.activate("build", chat, { silent = true })

    local reminder = ""
    local agent_prompt_count = 0
    local last_prompt_agent = ""
    for _, msg in ipairs(chat.messages) do
      if msg._meta and msg._meta.tag == "agent_change_reminder" then reminder = msg.content end
      if msg._meta and msg._meta.tag == "agent_system_prompt" then
        agent_prompt_count = agent_prompt_count + 1
        last_prompt_agent = msg._meta.agent or ""
      end
    end

    local has_plan_group = false
    local has_build_group = false
    for _, item in ipairs(chat.context_items) do
      if item.id == "<group>agent_plan</group>" then has_plan_group = true end
      if item.id == "<group>agent_build</group>" then has_build_group = true end
    end

    return {
      active = agents.active(chat.bufnr),
      reminder = reminder,
      agent_prompt_count = agent_prompt_count,
      last_prompt_agent = last_prompt_agent,
      has_plan_group = has_plan_group,
      has_build_group = has_build_group,
      has_cmd_runner = chat.tool_registry.in_use.cmd_runner == true,
    }
  ]])

  expect.equality(summary.active, "build")
  expect.equality(summary.agent_prompt_count, 1)
  expect.equality(summary.last_prompt_agent, "build")
  expect.equality(summary.has_plan_group, false)
  expect.equality(summary.has_build_group, true)
  expect.equality(summary.has_cmd_runner, true)
  expect.equality(summary.reminder:find("changed from plan to build", 1, true) ~= nil, true)
end

T["agents"]["model change event refreshes prompt without duplicates"] = function()
  local summary = child.lua([[
    local agents = require("hive.agents")
    local chat = _G.new_chat(104, "model-a")

    agents.activate("build", chat, { silent = true })

    local before = ""
    for _, msg in ipairs(chat.messages) do
      if msg._meta and msg._meta.tag == "agent_system_prompt" then before = msg.content end
    end

    chat.adapter.schema.model.default = "model-b"
    vim.api.nvim_exec_autocmds("User", {
      pattern = "CodeCompanionChatModel",
      data = { bufnr = chat.bufnr },
    })

    local after = ""
    local count = 0
    for _, msg in ipairs(chat.messages) do
      if msg._meta and msg._meta.tag == "agent_system_prompt" then
        count = count + 1
        after = msg.content
      end
    end

    return {
      before = before,
      after = after,
      count = count,
    }
  ]])

  expect.equality(summary.count, 1)
  expect.equality(summary.before == summary.after, false)
  expect.equality(summary.after:find("PROMPT:build|Adapter:test_adapter/model-b", 1, true) ~= nil, true)
end

return T
