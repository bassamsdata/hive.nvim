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

        package.loaded["hive.spinner"] = nil
        package.loaded["hive.state"] = {
          setup = function() end,
          instance = function()
            return _G._state_manager
          end,
          debug_log = function() end,
        }
        package.loaded["hive.utils.notify"] = function() end

        _G._state_manager = {
          on = function() end,
          get_view = function()
            return {
              parents = {},
              active_parent_bufnr = nil,
              inline = {},
            }
          end,
          get_parent_view = function()
            return {
              parents = {},
              active_parent_bufnr = nil,
              inline = {},
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

T["spinner"] = new_set()

T["spinner"]["winbar segment supports model_only format"] = function()
  local result = child.lua([[
    _G._state_manager = {
      on = function() end,
      get_view = function()
        return {
          parents = {
            [11] = {
              status = "streaming",
              model = "gpt-4.1-mini",
              adapter = "OpenAI",
              provider = "Venice",
              subagents = {},
            },
          },
          active_parent_bufnr = 11,
          inline = {},
        }
      end,
      get_parent_view = function()
        return {
          parents = {
            [11] = {
              status = "streaming",
              model = "gpt-4.1-mini",
              adapter = "OpenAI",
              provider = "Venice",
              subagents = {},
            },
          },
          active_parent_bufnr = 11,
          inline = {},
        }
      end,
    }

    local spinner = require("hive.spinner")
    spinner.setup({
      spinner = {
        frames = { "*" },
        interval = 80,
      },
      window = {
        enabled = false,
      },
      winbar = {
        enabled = true,
        format = "model_only",
      },
    })

    return spinner.get_winbar_segment(11)
  ]])

  expect.equality(result:find("gpt%-4%.1%-mini") ~= nil, true)
  expect.equality(result:find("OpenAI", 1, true) ~= nil, false)
  expect.equality(result:find("Venice", 1, true) ~= nil, false)
end

T["spinner"]["winbar segment supports model_adapter format"] = function()
  local result = child.lua([[
    _G._state_manager = {
      on = function() end,
      get_view = function()
        return {
          parents = {
            [17] = {
              status = "streaming",
              model = "claude-sonnet-4",
              adapter = "OpenRouter",
              provider = "Venice",
              subagents = {},
            },
          },
          active_parent_bufnr = 17,
          inline = {},
        }
      end,
      get_parent_view = function()
        return {
          parents = {
            [17] = {
              status = "streaming",
              model = "claude-sonnet-4",
              adapter = "OpenRouter",
              provider = "Venice",
              subagents = {},
            },
          },
          active_parent_bufnr = 17,
          inline = {},
        }
      end,
    }

    local spinner = require("hive.spinner")
    spinner.setup({
      spinner = {
        frames = { "@" },
        interval = 80,
      },
      window = {
        enabled = false,
      },
      winbar = {
        enabled = true,
        format = "model_adapter",
      },
    })

    return spinner.get_winbar_segment(17)
  ]])

  expect.equality(result:find("claude%-sonnet%-4") ~= nil, true)
  expect.equality(result:find("OpenRouter", 1, true) ~= nil, true)
  expect.equality(result:find("Venice", 1, true) ~= nil, true)
end

T["spinner"]["winbar segment is nil when winbar display is disabled"] = function()
  local result = child.lua([[
    _G._state_manager = {
      on = function() end,
      get_view = function()
        return {
          parents = {
            [23] = {
              status = "streaming",
              model = "gpt-4.1",
              adapter = "OpenAI",
              provider = "Venice",
              subagents = {},
            },
          },
          active_parent_bufnr = 23,
          inline = {},
        }
      end,
      get_parent_view = function()
        return {
          parents = {
            [23] = {
              status = "streaming",
              model = "gpt-4.1",
              adapter = "OpenAI",
              provider = "Venice",
              subagents = {},
            },
          },
          active_parent_bufnr = 23,
          inline = {},
        }
      end,
    }

    local spinner = require("hive.spinner")
    spinner.setup({
      spinner = {
        frames = { "." },
      },
      window = {
        enabled = false,
      },
      winbar = {
        enabled = false,
      },
    })

    return spinner.get_winbar_segment(23)
  ]])

  expect.equality(result == nil or result == vim.NIL, true)
end

return T
