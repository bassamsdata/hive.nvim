local compat = require("hive.tools.compat")
local confirm = require("hive.confirm")
local log = require("codecompanion.utils.log")

local fmt = string.format
local empty_dict = vim.empty_dict

local function get_chat(tools)
  if not tools or not tools.chat then return nil, "No chat context available" end
  return tools.chat, nil
end

local function build_tool(args)
  return {
    name = args.name,
    cmds = {
      compat.cmds(function(tools, tool_args, opts)
        return args.handler(tools, tool_args, opts or {})
      end),
    },
    schema = {
      type = "function",
      ["function"] = {
        name = args.name,
        description = args.description,
        parameters = args.parameters,
      },
    },
    handlers = {
      on_exit = compat.handler_on_exit(function()
        log:trace("[Plan Tool] %s on_exit", args.name)
      end),
    },
    output = {
      cmd_string = compat.output_cmd_string(function(self)
        return fmt("󱂬 %s", args.name)
      end),
      success = compat.output_success(function(self, stdout, meta)
        local chat = meta.tools.chat
        local output = vim.iter(stdout):flatten():join("\n")
        chat:add_tool_output(self, output, output)
      end),
      error = compat.output_error(function(self, stderr, meta)
        local chat = meta.tools.chat
        local output = vim.iter(stderr):flatten():join("\n")
        chat:add_tool_output(self, output, output)
      end),
    },
  }
end

local function refresh_chat_prompt(chat)
  local ok_agents, agents = pcall(require, "hive.agents")
  if ok_agents and agents and agents.refresh_active_agent then agents.refresh_active_agent(chat) end
end

local enter_plan_mode = build_tool({
  name = "enter_plan_mode",
  description = "Enter plan mode for the current chat and create a project-local plan file for the workflow.",
  parameters = {
    type = "object",
    properties = empty_dict(),
    additionalProperties = false,
  },
  handler = function(tools, _args, _opts)
    local chat, err = get_chat(tools)
    if err then return { status = "error", data = err } end
    if not chat then return { status = "error", data = "No chat context available" } end

    local plan = require("hive.plan")
    local state, enter_err = plan.enter(chat)
    if enter_err then return { status = "error", data = enter_err } end
    if not state then return { status = "error", data = "Failed to enter plan mode" } end

    refresh_chat_prompt(chat)

    return {
      status = "success",
      data = fmt(
        "Entered plan mode. Plan file created at `%s`. Stay in the current workflow, explore the codebase, write your plan with `write_plan_file`, then call `exit_plan_mode` for approval.",
        state.file_path
      ),
    }
  end,
})

local write_plan_file = build_tool({
  name = "write_plan_file",
  description = "Write the current implementation plan to the active chat's project-local plan file.",
  parameters = {
    type = "object",
    properties = {
      content = {
        type = "string",
        description = "Full plan content to save to disk",
      },
    },
    required = { "content" },
    additionalProperties = false,
  },
  handler = function(tools, args, _opts)
    local chat, err = get_chat(tools)
    if err then return { status = "error", data = err } end
    if not chat then return { status = "error", data = "No chat context available" } end

    local content = args.content
    if type(content) ~= "string" then return { status = "error", data = "Missing required parameter: content" } end

    local plan = require("hive.plan")
    local result, write_err = plan.write(chat.bufnr, content)
    if write_err then return { status = "error", data = write_err } end
    if not result then return { status = "error", data = "Failed to write plan file" } end

    return {
      status = "success",
      data = fmt("Plan file updated at `%s` (%d bytes).", result.file_path, result.bytes),
    }
  end,
})

local read_plan_file = build_tool({
  name = "read_plan_file",
  description = "Read the current contents of the active chat's project-local plan file.",
  parameters = {
    type = "object",
    properties = empty_dict(),
    additionalProperties = false,
  },
  handler = function(tools, _args, _opts)
    local chat, err = get_chat(tools)
    if err then return { status = "error", data = err } end
    if not chat then return { status = "error", data = "No chat context available" } end

    local plan = require("hive.plan")
    local content, file_path, read_err = plan.read(chat.bufnr)
    if read_err then return { status = "error", data = read_err } end
    if not file_path then return { status = "error", data = "Plan file path unavailable" } end

    return {
      status = "success",
      data = fmt("Plan file: `%s`\n\n%s", file_path, content ~= "" and content or "(empty)"),
    }
  end,
})

local exit_plan_mode = build_tool({
  name = "exit_plan_mode",
  description = "Submit the saved plan for approval and, if approved, leave plan mode and resume the current implementation workflow.",
  parameters = {
    type = "object",
    properties = {
      summary = {
        type = "string",
        description = "Optional short summary of the plan for the approval prompt",
      },
    },
    additionalProperties = false,
  },
  handler = function(tools, args, opts)
    local chat, err = get_chat(tools)
    if err then return { status = "error", data = err } end
    if not chat then return { status = "error", data = "No chat context available" } end

    local output_handler = opts.output_cb
    if not output_handler then
      return {
        status = "error",
        data = "exit_plan_mode requires async output handling",
      }
    end

    local plan = require("hive.plan")
    local content, file_path, read_err = plan.read(chat.bufnr)
    if read_err then
      output_handler({ status = "error", data = read_err })
      return nil
    end
    if not file_path then
      output_handler({ status = "error", data = "Plan file path unavailable" })
      return nil
    end

    if vim.trim(content or "") == "" then
      output_handler({
        status = "error",
        data = "Plan file is empty. Write your plan to disk before exiting plan mode.",
      })
      return nil
    end

    vim.schedule(function()
      local summary = args.summary and vim.trim(args.summary) ~= "" and args.summary
        or "Review the saved implementation plan"
      local message = fmt(
        "Approve exiting plan mode?\n\nPlan file: %s\n\nSummary: %s\n\nThe full plan is saved on disk and will remain available after approval.",
        file_path,
        summary
      )

      confirm({
        title = "Plan Approval",
        msg = message,
        choices = { "Approve", "Reject" },
        on_choice = function(idx)
          if idx ~= 1 then
            output_handler({
              status = "error",
              data = fmt("Plan was not approved. Review `%s`, refine it, and try again.", file_path),
            })
            return
          end

          local result, exit_err = plan.exit(chat, { approved = true })
          if exit_err then
            output_handler({ status = "error", data = exit_err })
            return
          end
          if not result then
            output_handler({ status = "error", data = "Failed to exit plan mode" })
            return
          end

          refresh_chat_prompt(chat)

          output_handler({
            status = "success",
            data = fmt(
              "Plan approved. Exited plan mode and restored the current workflow. Plan file remains at `%s`.\n\nApproved plan:\n%s",
              result.file_path,
              result.content ~= "" and result.content or "(empty)"
            ),
          })
        end,
      })
    end)

    return nil
  end,
})

local _tools = {
  enter_plan_mode = enter_plan_mode,
  write_plan_file = write_plan_file,
  read_plan_file = read_plan_file,
  exit_plan_mode = exit_plan_mode,
}

local M = {}

---@param name string
---@return table|nil
function M.get(name)
  return _tools[name]
end

---@return table<string, table>
function M.get_all()
  return vim.deepcopy(_tools)
end

return M
