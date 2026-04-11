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
        vim.fn.delete(vim.fs.joinpath(vim.fn.getcwd(), ".hive"), "rf")

        package.loaded["hive.plan"] = nil
        package.loaded["hive.agents"] = {
          active = function()
            return "build"
          end,
          activate = function()
            return true
          end,
        }
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["plan"] = new_set()

T["plan"]["state writes reads and exits"] = function()
  local result = child.lua([[
    local plan = require("hive.plan")
    local chat = { bufnr = 201 }

    local state = assert(plan.enter(chat))
    local write = assert(plan.write(chat.bufnr, "# Saved plan\n"))
    local content, file_path = assert(plan.read(chat.bufnr))
    local exited = assert(plan.exit(chat, { approved = true }))

    return {
      state_path = state.file_path,
      write_path = write.file_path,
      read_path = file_path,
      content = content,
      approved = exited.approved,
      inactive = plan.is_active(chat.bufnr),
    }
  ]])

  expect.equality(result.state_path:find("/.hive/plans/chat%-201%.md$") ~= nil, true)
  expect.equality(result.write_path, result.state_path)
  expect.equality(result.read_path, result.state_path)
  expect.equality(result.content, "# Saved plan\n")
  expect.equality(result.approved, true)
  expect.equality(result.inactive, false)
end

return T
