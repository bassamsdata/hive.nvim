local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "scripts/minimal_init.lua" })
      child.lua([[
        vim.opt.rtp:prepend(".")
      ]])
    end,
    post_case = function()
      child.stop()
    end,
  },
})

T["discovery"] = MiniTest.new_set()
T["parser"] = MiniTest.new_set()
T["integration"] = MiniTest.new_set()

T["discovery"]["module loads successfully"] = function()
  local result = child.lua([[
    local discovery = require("hive.skills.discovery")
    return discovery ~= nil
  ]])
  MiniTest.expect.equality(result, true)
end

T["discovery"]["discovers skills from array of directories"] = function()
  local result = child.lua([[
    local discovery = require("hive.skills.discovery")
    
    local test_dirs = {}
    table.insert(test_dirs, "/tmp/.codecompanion/skills")
    
    local skills = discovery.discover(test_dirs)
    return type(skills) == "table"
  ]])
  MiniTest.expect.equality(result, true)
end

T["parser"]["parses SKILL.md with valid name"] = function()
  local result = child.lua([[
    local parser = require("hive.skills.parser")
    
    local valid_names = {
      "neovim-help",
      "my-skill-123",
      "test-skill",
    }
    
    local all_valid = true
    for _, name in ipairs(valid_names) do
      local valid, _ = parser.validate_name(name)
      if not valid then
        all_valid = false
      end
    end
    return all_valid
  ]])
  MiniTest.expect.equality(result, true)
end

T["parser"]["rejects invalid skill names"] = function()
  local result = child.lua([[
    local parser = require("hive.skills.parser")
    
    local invalid_names = {
      "Neovim 0.12 Documentation (help) Extractor",
      "My Skill",
      "skill_with_underscores",
      "-starts-with-dash",
      "ends-with-dash-",
      "double--dash",
    }
    
    local all_invalid = true
    for _, name in ipairs(invalid_names) do
      local valid, _ = parser.validate_name(name)
      if valid then
        all_invalid = false
      end
    end
    return all_invalid
  ]])
  MiniTest.expect.equality(result, true)
end

T["integration"]["setup initializes with config"] = function()
  local result = child.lua([[
    local skills = require("hive.skills")
    
    skills.setup({ 
      enabled = true,
      scan_to_git_root = false
    })
    
    return skills.count() >= 0
  ]])
  MiniTest.expect.equality(result, true)
end

T["integration"]["get_skill returns nil for nonexistent skill"] = function()
  local result = child.lua([[
    local skills = require("hive.skills")
    skills.setup({ enabled = true, scan_to_git_root = false })
    
    local skill = skills.get_skill("nonexistent-skill-xyz")
    return skill == nil
  ]])
  MiniTest.expect.equality(result, true)
end

return T
