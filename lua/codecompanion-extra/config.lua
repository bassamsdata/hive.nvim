local M = {}

---@class CodeCompanionExtra.Config
---@field modules table<string, { enabled: boolean }>
---@field spinner table Spinner configuration
---@field adapters table<string, { enabled: boolean }> Adapter configurations
---@field tools table<string, { enabled: boolean, opts?: table }> Tool configurations
---@field agents CodeCompanionExtra.AgentsConfig Agent system configuration
---@field skills CodeCompanionExtra.SkillsConfig Skills system configuration

---@class CodeCompanionExtra.AgentsConfig
---@field keymap? { switch?: table<string, string> } Keymap configuration
---@field definitions? table<string, CodeCompanionExtra.Agent> Custom agent definitions
---@field load_from_dir? string Directory to load agents from markdown files
---@field small_model? string Model for subagents in format "adapter/model" or "adapter/provider/model". If nil, inherits from parent chat. Can be overridden by vim.g.codecompanion_small_model

---@class CodeCompanionExtra.SkillsConfig
---@field enabled boolean Enable skills support
---@field directories string[] Additional directories to scan for skills
---@field scan_to_git_root boolean Scan up to .git boundary
---@field recursive boolean Scan subdirectories recursively

---@type CodeCompanionExtra.Config
M.defaults = {
  modules = {
    spinner = { enabled = true },
    adapters = { enabled = true },
    tools = { enabled = true },
    agents = { enabled = true },
    skills = { enabled = true },
    list_directory = { enabled = true },
  },

  spinner = {
    spinner = {
      frames = "slide_bar",
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
    task = { enabled = true },
    ask_user = { enabled = true },
    skill = { enabled = true },
  },

  agents = {
    -- Keymap for agent switching (toggles if 2 agents, select if more)
    keymap = {
      switch = { n = "gO" },
      -- Navigation keymaps are registered automatically:
      -- ]s - next subagent
      -- [s - prev subagent
      -- [p - parent agent
      -- gs - list subagents
    },

    -- Model for subagents. Format: "adapter/model" or "adapter/provider/model"
    -- Examples:
    --   "openai/gpt-4o-mini"          -> adapter: openai, model: gpt-4o-mini
    --   "openrouter/openai/gpt-4o"    -> adapter: openrouter, model: openai/gpt-4o
    -- If nil, subagents inherit adapter/model from parent chat.
    -- Can be overridden at runtime via vim.g.codecompanion_small_model
    small_model = nil,

    -- Override built-in agents or add custom ones
    -- Built-in agents: build, plan (primary), explorer, general, analyzer (subagents)
    definitions = {},

    -- Load agents from markdown directory
    load_from_dir = nil,
  },

  skills = {
    -- Enable skills support
    enabled = true,
    -- Additional directories to scan for skills
    -- Default scans: .codecompanion/skills/, .claude/skills/ (project & user level)
    directories = {},
    -- Scan from cwd up to .git boundary for skills
    scan_to_git_root = true,
    -- Scan subdirectories recursively (opt-in)
    recursive = false,
  },
}

---@type CodeCompanionExtra.Config
M.config = vim.deepcopy(M.defaults)

---Parse model string in format "adapter/model" or "adapter/provider/model"
---@param model_str string|nil The model string to parse
---@return { adapter: string, model: string }|nil Parsed adapter and model, or nil if invalid
function M.parse_model_string(model_str)
  if not model_str or model_str == "" then return nil end

  local parts = vim.split(model_str, "/", { plain = true })
  if #parts == 2 then
    -- Format: "openai/gpt-4o-mini" -> adapter: openai, model: gpt-4o-mini
    return { adapter = parts[1], model = parts[2] }
  elseif #parts >= 3 then
    -- Format: "openrouter/openai/gpt-4o" -> adapter: openrouter, model: openai/gpt-4o
    return { adapter = parts[1], model = table.concat(vim.list_slice(parts, 2), "/") }
  end

  return nil
end

---Get the small model configuration for subagents
---Priority: vim.g.codecompanion_small_model > config.agents.small_model > nil (inherit from parent)
---@return { adapter: string, model: string }|nil
function M.get_small_model()
  -- Check vim.g override first
  local global_override = vim.g.codecompanion_small_model
  if global_override then return M.parse_model_string(global_override) end

  -- Check config
  local config_model = M.config.agents and M.config.agents.small_model
  if config_model then return M.parse_model_string(config_model) end

  return nil
end

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
