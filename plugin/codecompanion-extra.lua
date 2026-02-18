-- Plugin loader for codecompanion-extra
-- Enables standalone usage without codecompanion extension system

if vim.g.loaded_codecompanion_extra then return end
vim.g.loaded_codecompanion_extra = true

if vim.fn.has("nvim-0.11") ~= 1 then
  vim.notify("codecompanion-extra requires Neovim 0.11 or higher", vim.log.levels.ERROR)
  return
end

---@class CCExtraSubcommand
---@field impl fun(args: string[], opts: table) Implementation function
---@field complete? fun(subcmd_arg_lead: string): string[] Completion function

---@type table<string, CCExtraSubcommand>
local subcommands = {
  setup = {
    impl = function()
      local extra = require("codecompanion-extra")
      if not extra.is_initialized() then extra.setup() end
      vim.notify("codecompanion-extra initialized", vim.log.levels.INFO)
    end,
  },

  ---Switch or create agent on current/new chat
  ---Usage: :CCExtra agent [name] or :CCExtra agent! [name] (new chat)
  agent = {
    impl = function(args, opts)
      local extra = require("codecompanion-extra")
      if not extra.is_initialized() then extra.setup() end

      local agents = require("codecompanion-extra.agents")
      local agent_name = args[1] or ""
      local create_new = opts.bang

      -- If bang (!) is used, create a new chat with the agent
      if create_new then
        if agent_name == "" then
          local available = agents.list("agent")
          if #available == 0 then
            vim.notify("No agents defined", vim.log.levels.WARN)
            return
          end

          local items = {}
          for _, name in ipairs(available) do
            local agent = agents.get(name)
            table.insert(items, {
              name = name,
              description = agent and agent.description or name,
            })
          end
          table.sort(items, function(a, b)
            return a.name < b.name
          end)

          vim.ui.select(items, {
            prompt = "Create chat with agent:",
            format_item = function(item)
              return item.name .. " - " .. item.description
            end,
          }, function(choice)
            if choice then agents.create_chat(choice.name) end
          end)
          return
        end

        agents.create_chat(agent_name)
        return
      end

      -- Without bang, operate on current chat
      local ok, chat_module = pcall(require, "codecompanion.interactions.chat")
      if not ok then
        vim.notify("CodeCompanion not loaded", vim.log.levels.ERROR)
        return
      end

      local chat = chat_module.buf_get_chat(0)
      if not chat then
        vim.notify("No active chat buffer. Use :CCExtra agent! to create a new chat", vim.log.levels.WARN)
        return
      end

      if agent_name == "" then
        local available = agents.list("agent")

        if #available == 0 then
          vim.notify("No agents defined", vim.log.levels.WARN)
          return
        end

        local active = agents.active(chat.bufnr)
        local items = {}
        for _, name in ipairs(available) do
          local agent = agents.get(name)
          table.insert(items, {
            name = name,
            description = agent and agent.description or name,
          })
        end
        table.sort(items, function(a, b)
          return a.name < b.name
        end)

        vim.ui.select(items, {
          prompt = "Select Agent:",
          format_item = function(item)
            local prefix = ""
            if active == item.name then prefix = "● " end
            return prefix .. item.name .. " - " .. item.description
          end,
        }, function(choice)
          if choice then agents.activate(choice.name, chat) end
        end)
        return
      end

      if agent_name == "off" or agent_name == "none" then
        agents.deactivate(chat)
      else
        agents.activate(agent_name, chat)
      end
    end,
    complete = function()
      local extra = require("codecompanion-extra")
      if not extra.is_initialized() then extra.setup() end
      local agents = require("codecompanion-extra.agents")
      local completions = agents.list("agent")
      table.insert(completions, "off")
      return completions
    end,
  },

  ---List all available agents
  list = {
    impl = function()
      local extra = require("codecompanion-extra")
      if not extra.is_initialized() then extra.setup() end

      local agents = require("codecompanion-extra.agents")
      local available = agents.list()

      if #available == 0 then
        vim.notify("No agents defined", vim.log.levels.WARN)
        return
      end

      local lines = { "Available agents:" }
      table.sort(available)

      -- Try to get current chat's active agent
      local active
      local ok, chat_module = pcall(require, "codecompanion.interactions.chat")
      if ok then
        local chat = chat_module.buf_get_chat(0)
        if chat then active = agents.active(chat.bufnr) end
      end

      for _, name in ipairs(available) do
        local agent = agents.get(name)
        local prefix = (active == name) and "● " or "  "
        local type_indicator = agent and agent.type == "subagent" and " [subagent]" or ""
        local desc = agent and agent.description or ""
        table.insert(lines, prefix .. name .. type_indicator .. ": " .. desc)
      end

      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end,
  },

  ---Navigate to next subagent
  next = {
    impl = function()
      local extra = require("codecompanion-extra")
      if not extra.is_initialized() then extra.setup() end

      local navigation = require("codecompanion-extra.agents.navigation")
      navigation.next_subagent()
    end,
  },

  ---Navigate to previous subagent
  prev = {
    impl = function()
      local extra = require("codecompanion-extra")
      if not extra.is_initialized() then extra.setup() end

      local navigation = require("codecompanion-extra.agents.navigation")
      navigation.prev_subagent()
    end,
  },

  ---Navigate to parent agent
  parent = {
    impl = function()
      local extra = require("codecompanion-extra")
      if not extra.is_initialized() then extra.setup() end

      local navigation = require("codecompanion-extra.agents.navigation")
      navigation.parent()
    end,
  },

  ---Show subagents list for selection
  subagents = {
    impl = function()
      local extra = require("codecompanion-extra")
      if not extra.is_initialized() then extra.setup() end

      local ok, chat_module = pcall(require, "codecompanion.interactions.chat")
      if not ok then
        vim.notify("CodeCompanion not loaded", vim.log.levels.ERROR)
        return
      end

      local chat = chat_module.buf_get_chat(0)
      if not chat then
        vim.notify("No active chat buffer", vim.log.levels.WARN)
        return
      end

      local navigation = require("codecompanion-extra.agents.navigation")
      navigation.keymaps.list_subagents(chat)
    end,
  },

  ---Configure models for subagents and advisors
  ---Usage: :CCExtra model              (show current config)
  ---       :CCExtra model small <spec> (set small model)
  ---       :CCExtra model big <spec>   (set big model)
  ---       :CCExtra model clear        (clear overrides, inherit from parent)
  ---Model spec format: "adapter/model" or "adapter/provider/model"
  model = {
    impl = function(args)
      local extra = require("codecompanion-extra")
      if not extra.is_initialized() then extra.setup() end

      local config_module = require("codecompanion-extra.config")
      local models = require("codecompanion-extra.tools.subagent.models")
      local type_arg = args[1]

      -- No args: show current configuration
      if not type_arg then
        local small = models.get_model("small")
        local big = models.get_model("big")
        local config = config_module.get()

        local lines = { "Model Configuration:" }
        table.insert(lines, "")

        local small_source = vim.g.EXTRA_SMALL_MODEL and "vim.g"
          or (config.agents.small_model and "config" or "inherit")
        if small then
          table.insert(
            lines,
            string.format("  small (subagents): %s/%s [%s]", small.adapter, small.model, small_source)
          )
        else
          table.insert(lines, "  small (subagents): (inherits from parent chat)")
        end

        local big_source = vim.g.EXTRA_BIG_MODEL and "vim.g" or (config.agents.big_model and "config" or "inherit")
        if big then
          table.insert(lines, string.format("  big (advisors):    %s/%s [%s]", big.adapter, big.model, big_source))
        else
          table.insert(lines, "  big (advisors):    (inherits from parent chat)")
        end

        table.insert(lines, "")
        table.insert(lines, "Usage:")
        table.insert(lines, "  :CCExtra model small openai/gpt-4o-mini")
        table.insert(lines, "  :CCExtra model big openai/gpt-4o")
        table.insert(lines, "  :CCExtra model big openrouter/openai/gpt-4o")
        table.insert(lines, "  :CCExtra model clear")

        vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
        return
      end

      -- Clear overrides
      if type_arg == "clear" then
        vim.g.EXTRA_SMALL_MODEL = nil
        vim.g.EXTRA_BIG_MODEL = nil
        vim.notify("Model overrides cleared (will inherit from parent chat)", vim.log.levels.INFO)
        return
      end

      -- Set model
      if type_arg ~= "small" and type_arg ~= "big" then
        vim.notify("Usage: :CCExtra model <small|big|clear> [adapter/model]", vim.log.levels.ERROR)
        return
      end

      local model_spec = args[2]
      if not model_spec or model_spec == "" then
        -- Interactive: clear the override for this type
        local var_name = "EXTRA_" .. type_arg:upper() .. "_MODEL"
        vim.g[var_name] = nil
        vim.notify(
          string.format("%s model override cleared (will inherit from parent chat)", type_arg),
          vim.log.levels.INFO
        )
        return
      end

      -- Validate the spec parses correctly
      local parsed = models.parse_model_string(model_spec)
      if not parsed then
        vim.notify('Invalid model format. Use "adapter/model" or "adapter/provider/model"', vim.log.levels.ERROR)
        return
      end

      local var_name = "EXTRA_" .. type_arg:upper() .. "_MODEL"
      vim.g[var_name] = model_spec
      vim.notify(
        string.format("%s model set: %s (adapter=%s, model=%s)", type_arg, model_spec, parsed.adapter, parsed.model),
        vim.log.levels.INFO
      )
    end,
    complete = function(subcmd_arg_lead)
      local parts = vim.split(subcmd_arg_lead or "", "%s+")
      if #parts <= 1 then return { "small", "big", "clear" } end
      return {}
    end,
  },
}

---Main CCExtra command handler
---@param opts table Command options from nvim_create_user_command
local function ccextra_cmd(opts)
  local fargs = opts.fargs
  local subcommand_key = fargs[1]

  if not subcommand_key then
    local cmds = vim.tbl_keys(subcommands)
    table.sort(cmds)
    local lines = { "CCExtra subcommands:" }
    for _, cmd in ipairs(cmds) do
      table.insert(lines, "  " .. cmd)
    end
    table.insert(lines, "")
    table.insert(lines, "Usage: :CCExtra <subcommand> [args]")
    table.insert(lines, "       :CCExtra! agent [name]  - Create new chat with agent")
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return
  end

  local subcommand = subcommands[subcommand_key]
  if not subcommand then
    vim.notify(
      "Unknown subcommand: " .. subcommand_key .. "\nRun :CCExtra for available commands",
      vim.log.levels.ERROR
    )
    return
  end

  local args = { unpack(fargs, 2) }
  subcommand.impl(args, opts)
end

---Completion function for CCExtra command
---@param arg_lead string Current argument being typed
---@param cmd_line string Full command line
---@param cursor_pos number Cursor position
---@return string[] Completions
local function ccextra_complete(arg_lead, cmd_line, cursor_pos)
  local subcmd_key, subcmd_arg_lead = cmd_line:match("^CCExtra[!]?%s+(%S+)%s+(.*)$")
  if subcmd_key and subcmd_arg_lead then
    local subcommand = subcommands[subcmd_key]
    if subcommand and subcommand.complete then
      return vim.tbl_filter(function(item)
        return item:find(subcmd_arg_lead, 1, true) == 1
      end, subcommand.complete(subcmd_arg_lead))
    end
    return {}
  end

  subcmd_key = cmd_line:match("^CCExtra[!]?%s+(.*)$")
  if subcmd_key then
    local cmds = vim.tbl_keys(subcommands)
    return vim.tbl_filter(function(item)
      return item:find(subcmd_key, 1, true) == 1
    end, cmds)
  end

  return vim.tbl_keys(subcommands)
end

-- Main CCExtra command
vim.api.nvim_create_user_command("CCExtra", ccextra_cmd, {
  bang = true,
  nargs = "*",
  complete = ccextra_complete,
  desc = "CodeCompanion Extra - agent system and utilities",
})
