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

        package.loaded["hive.agents.navigation"] = {
          refresh_winbar = function() end,
        }

        package.loaded["hive.agents.hierarchy"] = nil
        require("hive.agents.hierarchy").clear()
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["hierarchy"] = new_set()

T["hierarchy"]["tracks parent child sibling root and tree relationships"] = function()
  local summary = child.lua([[
    local hierarchy = require("hive.agents.hierarchy")
    hierarchy.clear()

    hierarchy.create_session({
      bufnr = 1,
      agent_name = "build",
      agent_type = "agent",
      description = "Root chat",
    })

    hierarchy.create_session({
      bufnr = 2,
      parent_bufnr = 1,
      agent_name = "explorer",
      agent_type = "subagent",
      description = "Explore files",
      hidden = true,
    })

    hierarchy.create_session({
      bufnr = 3,
      parent_bufnr = 1,
      agent_name = "analyzer",
      agent_type = "subagent",
      description = "Analyze diagnostics",
      hidden = true,
    })

    return {
      children = hierarchy.get_children(1),
      parent_of_two = hierarchy.get_parent(2),
      siblings_of_two = hierarchy.get_siblings(2),
      root_of_three = hierarchy.get_root(3),
      tree_of_root = hierarchy.get_tree(1),
      has_children = hierarchy.has_children(1),
      is_child_two = hierarchy.is_child(2),
    }
  ]])

  expect.equality(summary.children, { 2, 3 })
  expect.equality(summary.parent_of_two, 1)
  expect.equality(summary.siblings_of_two, { 3 })
  expect.equality(summary.root_of_three, 1)
  expect.equality(summary.tree_of_root, { 1, 2, 3 })
  expect.equality(summary.has_children, true)
  expect.equality(summary.is_child_two, true)
end

T["hierarchy"]["tracks tool execution and status summaries"] = function()
  local summary = child.lua([[
    local hierarchy = require("hive.agents.hierarchy")
    hierarchy.clear()

    hierarchy.create_session({
      bufnr = 10,
      agent_name = "explorer",
      agent_type = "subagent",
      description = "Scan repository",
    })

    hierarchy.start_timer(10)
    hierarchy.tool_started(10, "tool_2", "grep_search")
    hierarchy.tool_finished(10, "tool_2", false, "Search failed")
    hierarchy.tool_started(10, "tool_1", "read_file")
    hierarchy.tool_finished(10, "tool_1", true, "Read init.lua")
    hierarchy.set_status(10, "completed", "Done")

    local tool_summary = hierarchy.get_tool_summary(10)
    local executions = hierarchy.get_tool_execution_list(10)
    local status_text = hierarchy.build_status_text(10)

    return {
      summary = tool_summary,
      first_execution = executions[1],
      second_execution = executions[2],
      status_text = status_text,
    }
  ]])

  expect.equality(summary.summary.total, 2)
  expect.equality(summary.summary.completed, 1)
  expect.equality(summary.summary.failed, 1)
  expect.equality(summary.first_execution.id, "tool_1")
  expect.equality(summary.second_execution.id, "tool_2")
  expect.equality(summary.status_text:find("Completed", 1, true) ~= nil, true)
end

T["hierarchy"]["removing a child updates parent and session state"] = function()
  local summary = child.lua([[
    local hierarchy = require("hive.agents.hierarchy")
    hierarchy.clear()

    hierarchy.create_session({
      bufnr = 21,
      agent_name = "build",
      agent_type = "agent",
      description = "Parent",
    })

    hierarchy.create_session({
      bufnr = 22,
      parent_bufnr = 21,
      agent_name = "general",
      agent_type = "subagent",
      description = "Child",
    })

    hierarchy.remove(22)

    return {
      children = hierarchy.get_children(21),
      child_session = hierarchy.get_session(22),
      has_children = hierarchy.has_children(21),
      all_done = hierarchy.all_children_done(21),
    }
  ]])

  expect.equality(summary.children, {})
  expect.equality(summary.child_session == nil or summary.child_session == vim.NIL, true)
  expect.equality(summary.has_children, false)
  expect.equality(summary.all_done, true)
end

return T
