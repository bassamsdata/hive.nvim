-- Config module for codecompanion-extra
-- Handles configuration defaults and merging

local M = {}

---@class CodeCompanionExtra.Config
---@field modules table Module enable/disable settings
---@field spinner table Spinner configuration
---@field adapters table Adapter configurations
---@field tools table Tool configurations
---@field modes table Mode definitions

---@type CodeCompanionExtra.Config
M.defaults = {
  modules = {
    spinner = { enabled = true },
    adapters = { enabled = true },
    tools = { enabled = true },
    modes = { enabled = true },
  },

  spinner = {
    spinner = {
      frames = "binary",
      interval = 80,
    },
    display = {
      show_model = true,
      show_tool_name = false,
      show_tool_status = true,
      show_timestamps = true,
      completion_display_time = 3000,
    },
    window = {
      max_width_percent = 0.35,
      blend = 100,
      right_offset = 1,
      enabled = true,
    },
  },

  adapters = {
    groq = { enabled = true },
    cerebras = { enabled = true },
    openrouter = { enabled = true },
  },

  tools = {
    get_diagnostics = { enabled = true },
  },

  modes = {
    -- Single keymap for mode switching (toggles if 2 modes, select if more)
    -- Note: gm is often used for change_model, gM for clear_rules, so we use gO (mOde)
    keymap = {
      modes = { n = "gO" },
      index = 50,
      description = "[Mode] Switch mode",
    },

    definitions = {
      -- Plan mode: Read-only research and analysis
      plan = {
        description = "Research and analyze before coding (read-only)",
        tools = {
          "read_file",
          "grep_search",
          "file_search",
          "list_code_usages",
          "get_changed_files",
        },
        system_prompt = [[You are in PLAN mode. Your task is to research, analyze, and understand code before any modifications.

In this mode you should:
- Explore the codebase structure
- Read relevant files and understand their purpose
- Search for patterns, usages, and dependencies
- Analyze code flow and architecture
- Provide detailed explanations and recommendations

You do NOT have access to file modification tools. Focus on understanding and planning.
When you have a complete understanding, recommend switching to BUILD mode to implement changes.]],
        opts = {
          include_default_system_prompt = true,
          include_tools_system_prompt = true,
          auto_submit_errors = false,
          auto_submit_success = false,
        },
      },

      -- Build mode: Full autonomous coding agent
      build = {
        description = "Autonomous coding with full tool access",
        tools = {
          "read_file",
          "grep_search",
          "file_search",
          "list_code_usages",
          "get_changed_files",
          "insert_edit_into_file",
          "create_file",
          "delete_file",
          "cmd_runner",
          "get_diagnostics",
        },
        system_prompt = function(chat)
          local adapter_name = "unknown"
          if chat and chat.adapter then adapter_name = chat.adapter.formatted_name or chat.adapter.name or "unknown" end

          return [[You are in BUILD mode - an autonomous coding agent with full tool access.

CORE BEHAVIOR:
- You are a highly sophisticated automated coding agent
- Take action immediately - don't ask for permission to use tools
- Keep going until the task is fully complete
- After every file edit, use get_diagnostics to verify no syntax errors

TOOL USAGE:
- Read files before editing to understand current state
- Use insert_edit_into_file for modifications (preserve indentation)
- Use create_file for new files
- Use cmd_runner for shell commands (tests, builds, git)
- Use get_diagnostics after edits to catch errors
- Fix errors up to 3 attempts, then ask user for help

RULES:
- NEVER print code blocks for changes - use the edit tools directly
- NEVER print shell commands - use cmd_runner directly
- NEVER say tool names to users
- Always use file paths exactly as provided

You are using: ]] .. adapter_name
        end,
        opts = {
          include_default_system_prompt = false,
          include_tools_system_prompt = true,
          auto_submit_errors = true,
          auto_submit_success = true,
        },
      },
    },
  },
}

---@type CodeCompanionExtra.Config
M.config = vim.deepcopy(M.defaults)

---Merge user config with defaults
---@param user_opts table?
---@return CodeCompanionExtra.Config
function M.setup(user_opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})
  return M.config
end

---Get current config
---@return CodeCompanionExtra.Config
function M.get()
  return M.config
end

---Check if a module is enabled
---@param module_name string
---@return boolean
function M.is_module_enabled(module_name)
  local module_config = M.config.modules[module_name]
  if module_config == nil then return false end
  if type(module_config) == "boolean" then return module_config end
  return module_config.enabled ~= false
end

return M
