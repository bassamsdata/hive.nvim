local M = {}

---@class CodeCompanionExtra.Config
---@field modules table<string, { enabled: boolean }>
---@field spinner table Spinner configuration
---@field adapters table<string, { enabled: boolean }> Adapter configurations
---@field tools table<string, { enabled: boolean, opts?: table }> Tool configurations
---@field agents CodeCompanionExtra.AgentsConfig Agent system configuration
---@field skills CodeCompanionExtra.SkillsConfig Skills system configuration
---@field sys_notify CodeCompanionExtra.SysNotifyConfig System notification configuration
---@field context_pruning? table Context pruning configuration

---@class CodeCompanionExtra.SysNotifyConfig
---@field enabled boolean Enable system notifications
---@field only_when_unfocused boolean Only show notifications when Neovim is unfocused
---@field notify_on table<string, boolean> Which events to notify on (e.g., completed
---@field title string Notification title
---@field fallback boolean Whether to fallback to vim.notify if system notifications fail

---@class CodeCompanionExtra.AgentsConfig
---@field keymap? { switch?: table<string, string|string[]> } Keymap configuration
---@field definitions? table<string, CodeCompanionExtra.Agent> Custom agent definitions
---@field load_from_dir? string Directory to load agents from markdown files
---@field load_cwd_agents? boolean Load agents from .codecompanion/agents under current working directory
---@field small_model? string Model for subagents. Format: "adapter/model" or "adapter/provider/model". If nil, inherits from parent chat. Can be overridden by vim.g.EXTRA_SMALL_MODEL
---@field big_model? string Model for consultant agents. Format: "adapter/model" or "adapter/provider/model". If nil, inherits from parent chat. Can be overridden by vim.g.EXTRA_BIG_MODEL

---@class CodeCompanionExtra.SkillsConfig
---@field enabled boolean Enable skills support
---@field directories string[] Additional directories to scan for skills
---@field scan_to_git_root boolean Scan up to .git boundary
---@field recursive boolean Scan subdirectories recursively

---@type CodeCompanionExtra.Config
M.defaults = {
  modules = {
    spinner = { enabled = true },
    notify = { enabled = true },
    adapters = { enabled = true },
    tools = { enabled = true },
    agents = { enabled = true },
    skills = { enabled = true },
    context_pruning = { enabled = true },
  },

  spinner = {
    spinner = {
      frames = "moon",
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

  sys_notify = {
    enabled = true,
    only_when_unfocused = true,
    notify_on = {
      completed = true,
      error = true,
      cancelled = false,
    },
    title = "CC Extra",
    fallback = true,
  },

  adapters = {
    groq = { enabled = true },
    cerebras = { enabled = true },
    openrouter = { enabled = true },
  },

  tools = {
    get_diagnostics = { enabled = true },
    task = { enabled = true },
    consult = { enabled = true },
    ask_user = { enabled = true },
    skill = { enabled = true },
    list_directory = { enabled = true },
    todowrite = { enabled = true },
    todoread = { enabled = true },
    cmd_runner = {
      enabled = true,
      opts = {
        timeout = 60,
        auto_allow_patterns = {},
        always_confirm_patterns = {},
        show_timer_after = 5,
        show_spinner = true,
      },
    },
    status = {
      scroll_to_show = true,
      scroll_cursor_distance = 10,
    },
  },

  agents = {
    -- Keymap for agent switching (toggles if 2 agents, select if more)
    -- Cycle keymap cycles through agents in sorted order (wraps around)
    keymap = {
      switch = { n = { "gO", "sa", "]a" } },
      cycle = { n = { "<Tab>" } },
      -- Navigation keymaps are registered automatically:

      -- ]s - next subagent
      -- [s - prev subagent
      -- ]p - parent agent
      -- ]S - list subagents
    },

    -- Model for subagents/primary agents. Format: "adapter/model" or "adapter/provider/model"
    -- Examples:
    --   "openai/gpt-4o-mini"          -> adapter: openai, model: gpt-4o-mini
    --   "openrouter/openai/gpt-4o"    -> adapter: openrouter, model: openai/gpt-4o
    -- If nil, agents inherit adapter/model from parent chat.
    -- Can be overridden at runtime via vim.g.EXTRA_SMALL_MODEL or vim.g.EXTRA_BIG_MODEL
    -- Or interactively via :CCExtra model small/big <spec>
    small_model = nil,
    big_model = nil,

    -- Model patterns that trigger a confirmation dialog before spawning subagents.
    -- Prevents accidental high-cost usage when parent chat uses an expensive model.
    -- Patterns are glob-like: * matches any chars, ? matches single char.
    -- Formats:
    --   "adapter/model*" - match specific adapter (e.g., "copilot/gpt*")
    --   "model*" - match any adapter with this model (e.g., "claude-opus*")
    --   "*/model*" - explicitly match any adapter
    confirm_expensive_models = { "claude-opus*" },

    -- Override built-in agents or add custom ones
    -- Built-in agents: build, plan (primary), explorer, general, analyzer (subagents)
    definitions = {},

    load_from_dir = nil,
    load_cwd_agents = true,
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

  context_pruning = {
    protected_tools = { "prune", "task", "todowrite", "todoread", "consult", "ask_user" },
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
