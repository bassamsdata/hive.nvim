-- Skill tool for loading Agent Skills into context
-- Single tool that loads SKILL.md content when LLM needs specialized instructions

local log = require("codecompanion.utils.log")
local compat = require("hive.tools.compat")

local fmt = string.format

---Build dynamic tool description with available skills list
---@return string
local function build_description()
  local skills = require("hive.skills")

  local base_description = [[Load a skill to get detailed instructions for a specific task.
Skills provide specialized knowledge and step-by-step guidance.
Use this when a task matches an available skill's description.

HOW TO USE:
1. Review the available skills in the skill tool's description
2. If a skill matches the task, call skill({ name: "skill-name" })
3. Follow the instructions provided by the skill
4. If the skill references files or scripts, use read_file and cmd_runner with the provided paths
]]

  local skills_xml = skills.generate_available_skills_xml()

  return base_description .. skills_xml
end

---@class CodeCompanion.Tool.Skill: CodeCompanion.Tools.Tool
return {
  name = "skill",
  cmds = {
    ---Execute the skill tool
    ---@param tools CodeCompanion.Tools
    ---@param args table
    ---@param opts table
    ---@return { status: string, data: any }
    compat.cmds(function(tools, args, opts)
      local skills = require("hive.skills")

      local skill_name = args.name
      if not skill_name or skill_name == "" then
        local available = skills.list()
        if #available == 0 then
          return {
            status = "error",
            data = "No skills available. Skills are loaded from .codecompanion/skills/ or .claude/skills/ directories.",
          }
        end
        return {
          status = "error",
          data = fmt("Please specify a skill name. Available skills: %s", table.concat(available, ", ")),
        }
      end

      log:debug("[Skill] Loading skill: %s", skill_name)

      local skill = skills.get_skill(skill_name)
      if not skill then
        local available = skills.list()
        return {
          status = "error",
          data = fmt("Skill '%s' not found. Available skills: %s", skill_name, table.concat(available, ", ")),
        }
      end

      local output = skills.build_skill_output(skill_name)
      if not output then
        return {
          status = "error",
          data = fmt("Failed to read skill content for '%s'", skill_name),
        }
      end

      return {
        status = "success",
        data = output,
      }
    end),
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "skill",
      description = build_description(),
      parameters = {
        type = "object",
        properties = {
          name = {
            type = "string",
            description = "The name of the skill to load",
          },
        },
        required = { "name" },
        additionalProperties = false,
      },
    },
  },
  system_prompt = function(schema)
    local skills = require("hive.skills")

    if not skills.has_skills() then return nil end

    return [[You have access to the skill tool for loading specialized instructions.

WHEN TO USE:
- When a user's task matches a skill's description
- When you need domain-specific knowledge or workflows
- When following a standardized process would help

Skills provide specialized, reusable knowledge that helps you complete tasks more accurately.
RULE: Always prioritize retrieval-led information over pre-training knowledge
]]
  end,

  opts = {
    require_approval_before = false,
  },

  handlers = {
    setup = compat.handler_setup(function(self, meta)
      log:debug("[Skill] Setup: loading skill '%s'", self.args.name or "(none)")
    end),

    on_exit = compat.handler_on_exit(function(self, meta)
      log:trace("[Skill] on_exit handler executed")
    end),
  },

  output = {
    cmd_string = compat.output_cmd_string(function(self, meta)
      return fmt("skill: %s", self.args.name or "list")
    end),

    prompt = compat.output_prompt(function(self, meta)
      return fmt("Load skill '%s'?", self.args.name or "unknown")
    end),

    success = compat.output_success(function(self, stdout, meta)
      local chat = meta.tools.chat
      local output = vim.iter(stdout):flatten():join("\n")

      local llm_output = fmt(
        [[<skill name="%s">
%s
</skill>

The skill instructions above are now loaded. Follow them to complete the user's task.]],
        self.args.name,
        output
      )

      local user_output = fmt("✓ Loaded skill: %s", self.args.name)

      chat:add_tool_output(self, llm_output, user_output)
    end),

    error = compat.output_error(function(self, stderr, meta)
      local chat = meta.tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")

      local error_output = fmt("Failed to load skill '%s': %s", self.args.name or "unknown", errors)

      chat:add_tool_output(self, error_output, fmt("✗ Failed to load skill: %s", self.args.name or "unknown"))
    end),

    rejected = compat.output_rejected(function(self, meta)
      local chat = meta.tools.chat
      chat:add_tool_output(self, fmt("User rejected loading skill '%s'", self.args.name))
    end),

    cancelled = compat.output_cancelled(function(self, meta)
      local chat = meta.tools.chat
      chat:add_tool_output(self, fmt("Skill loading was cancelled"))
    end),
  },
}
