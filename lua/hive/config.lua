local M = {}

---@class Hive.KeymapEntry
---@field modes table<string, string|string[]>
---@field desc string

---Build default keymap table with given prefix
---@param p string prefix character
---@return table<string, Hive.KeymapEntry|string>
local function _default_keymaps(p)
  return {
    prefix = p,
    -- stylua: ignore start 
    agent_switch     = { modes = { n = { p .. "o", p .. "A" } }, desc = "Switch agent" },
    agent_cycle      = { modes = { n = "<Tab>" },  desc               = "Cycle to next agent" },
    agent_manager    = { modes = { n = { "gA",     p .. "a" } }, desc = "Toggle agent manager" },
    next_subagent    = { modes = { n = p .. "s" }, desc               = "Next subagent" },
    prev_subagent    = { modes = { n = "[s" },     desc               = "Previous subagent" },
    parent_agent     = { modes = { n = p .. "p" }, desc               = "Parent agent" },
    list_subagents   = { modes = { n = { p .. "S", p .. "l" } }, desc = "List subagents" },
    todo_viewer      = { modes = { n = p .. "T" }, desc               = "View task list" },
    todo_split       = { modes = { n = p .. "t" }, desc               = "Toggle split task list" },
    toggle_ask_user  = { modes = { n = { "gH",     p .. "q" } }, desc = "Toggle ask_user form" },
    subagent_model   = { modes = { n = { "gm",     p .. "m" } }, desc = "Set subagent model" },
    prunable_viewer  = { modes = { n = { "gP",     p .. "P" } }, desc = "Show prunable context" },
    hive_keymap_help = { modes = { n = p .. "?" }, desc               = "Hive keymap reference" },
    -- stylua: ignore end
  }
end

---@class Hive.Config
---@field modules table<string, { enabled: boolean }>
---@field spinner table Spinner configuration
---@field adapters table<string, { enabled: boolean }> Adapter configurations
---@field tools table<string, { enabled: boolean, opts?: table }> Tool configurations
---@field agents Hive.AgentsConfig Agent system configuration
---@field skills Hive.SkillsConfig Skills system configuration
---@field sys_notify Hive.SysNotifyConfig System notification configuration
---@field context_lifecycle? ContextLifecycle.Config Context lifecycle management configuration
---@field context_pruning? table Context pruning configuration
---@field debug? Hive.DebugConfig Debug logging configuration
---@field twinchat? TwinchatConfig Twinchat configuration

---@class Hive.SysNotifyConfig
---@field enabled boolean Enable system notifications
---@field only_when_unfocused boolean Only show notifications when Neovim is unfocused
---@field notify_on table<string, boolean> Which events to notify on (e.g., completed
---@field title string Notification title
---@field fallback boolean Whether to fallback to vim.notify if system notifications fail

---@class Hive.AgentsConfig
---@field keymap? table<string, Hive.KeymapEntry|string> Keymap configuration. Keys are keymap names, values are { modes, desc } entries. 'prefix' is a string.
---@field definitions? table<string, Hive.Agent> Custom agent definitions
---@field load_from_dir? string Directory to load agents from markdown files
---@field load_cwd_agents? boolean Load agents from .codecompanion/agents under current working directory
---@field small_model? string Model for subagents. Format: "adapter/model" or "adapter/provider/model". If nil, inherits from parent chat. Can be overridden by vim.g.HIVE_SMALL_MODEL
---@field big_model? string Model for consultant agents. Format: "adapter/model" or "adapter/provider/model". If nil, inherits from parent chat. Can be overridden by vim.g.HIVE_BIG_MODEL
---@field model_prompts? table<string, table<string, string|fun(chat: table): string>> Per-agent model-specific system prompts. Outer key is agent name, inner key is model substring.

---@class Hive.SkillsConfig
---@field enabled boolean Enable skills support
---@field directories string[] Additional directories to scan for skills
---@field scan_to_git_root boolean Scan up to .git boundary
---@field recursive boolean Scan subdirectories recursively

---@class Hive.DebugConfig
---@field enabled boolean Write debug logs to file

---@class TwinchatConfig
---@field enabled boolean Enable twinchat feature
---@field threshold number Context percentage threshold (0-100) to trigger spawn
---@field min_messages number Minimum messages before monitoring
---@field cooldown_seconds number Seconds between twinchat spawns for same chat
---@field model_type "small"|"big" Model type for twin chats
---@field inherit_messages number Number of recent messages to inherit (0 = all, -1 = none)
---@field auto_prune boolean Auto-prune parent chat after spawning
---@field notify boolean Notify user when twin chat is spawned
---@field system_prompt string|fun(info: TwinchatThresholdInfo): string System prompt for twin chat
---@field prompt_template string|fun(info: TwinchatThresholdInfo): string Prompt template for twin chat

---@type Hive.Config
M.defaults = {
  modules = {
    spinner = { enabled = true },
    notify = { enabled = true },
    adapters = { enabled = true },
    tools = { enabled = true },
    agents = { enabled = true },
    skills = { enabled = true },
    context_pruning = { enabled = false },
    context_lifecycle = { enabled = true },
    twinchat = { enabled = false },
  },

  debug = {
    enabled = true,
  },

  spinner = {
    spinner = {
      frames = "moon",
      interval = 120,
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
    winbar = {
      enabled = true,
      format = "model_adapter",
    },
  },

  sys_notify = {
    enabled = true,
    only_when_unfocused = true,
    notify_on = {
      completed = true,
      error = true,
      cancelled = false,
      question = true,
      approval = true,
    },
    title = "Hive",
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
    team = { enabled = true },
    enter_plan_mode = { enabled = true },
    write_plan_file = { enabled = true },
    read_plan_file = { enabled = true },
    exit_plan_mode = { enabled = true },
    ask_user = { enabled = true },
    skill = { enabled = true },
    list_directory = { enabled = true },
    grep_search = { enabled = true },
    todowrite = { enabled = true },
    todoread = { enabled = true },
    cmd_runner = {
      enabled = true,
      opts = {
        timeout = 60, -- in seconds
        auto_allow_patterns = {},
        always_confirm_patterns = {},
        show_timer_after = 5, -- in seconds
        show_spinner = true,
      },
    },
    prune = { enabled = true },
    -- [[ Swarm Tools ]]
    swarm = { enabled = true },
    claim_task = { enabled = true },
    complete_task = { enabled = true },
    release_task = { enabled = true },
    lock_file = { enabled = true },
    unlock_file = { enabled = true },
    send_update = { enabled = true },
    send_to_peer = { enabled = true },
    read_messages = { enabled = true },
    get_swarm_status = { enabled = true },
    -- [[ Team Tools ]]
    complete_team_task = { enabled = true },
    block_team_task = { enabled = true },
    send_team_update = { enabled = true },
    get_team_status = { enabled = true },
    status = {
      scroll_to_show = true,
      scroll_cursor_distance = 10, -- lines from bottom to trigger scroll
    },
  },

  agents = {
    keymap = _default_keymaps("]"),

    -- Model for subagents/primary agents. Format: "adapter/model" or "adapter/provider/model"
    -- Examples:
    --   "openai/gpt-4o-mini"          -> adapter: openai, model: gpt-4o-mini
    --   "openrouter/openai/gpt-4o"    -> adapter: openrouter, model: openai/gpt-4o
    -- If nil, agents inherit adapter/model from parent chat.
    -- Can be overridden at runtime via vim.g.HIVE_SMALL_MODEL or vim.g.HIVE_BIG_MODEL
    -- Or interactively via :Hive model small/big <spec>
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

    -- Model-specific system prompts per agent.
    -- When the chat uses a model matching a substring key, the corresponding prompt
    -- completely replaces the agent's default system_prompt.
    -- Outer key = agent name, inner key = model name substring (case-insensitive).
    -- Value = string or function(chat) -> string.
    -- Example:
    --   model_prompts = {
    --     build = {
    --       ["gpt"] = "You are a coding agent optimized for OpenAI models...",
    --       ["qwen"] = function(chat) return "Custom prompt for Qwen..." end,
    --     },
    --   }
    -- The default (claude) prompt is the one defined in each agent's system_prompt field.
    model_prompts = {},

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
    protected_tools = { "prune", "task", "todowrite", "todoread", "consult", "ask_user", "swarm", "team" },
    min_tokens = 5000, -- Only inject prunable list when total prunable tokens ≥ this
    delta_tokens = 3000, -- Only re-inject when prunable tokens changed by ≥ this since last injection
  },

  context_lifecycle = {
    enabled = true,
    context_window_tokens = nil, -- nil = auto-detect from adapter/model, number = explicit override
    nudge_start = 50, -- Soft nudge to prune
    nudge_strong = 60, -- Strong nudge to prune
    compact_threshold = 75, -- Auto-compact at 75%
    reset_threshold = 90, -- Context reset at 90%
    min_messages = 4, -- Minimum messages before any layer activates
    notify = true, -- Notify user on compaction
    compaction = {
      recent_budget = 20000, -- Token budget for recent messages
      preserve_last_assistant = false, -- Keep last assistant message
      compaction_model = nil, -- nil = same adapter, "adapter/model" = override
      notify = true,
      max_compactions = 3, -- Warn after this many compactions
      compaction_prompt = nil, -- nil = default prompt
      summary_prefix = nil, -- nil = default prefix
    },
  },

  twinchat = {
    enabled = true,
    threshold = 75, -- Spawn twinchat at 75% context window
    min_messages = 4, -- Minimum messages before monitoring
    cooldown_seconds = 300, -- 5 minutes between spawns
    model_type = "small", -- Use small model for twin chats
    inherit_messages = 10, -- Inherit last 10 messages
    auto_prune = false, -- Don't auto-prune parent
    notify = true, -- Notify user on spawn
    system_prompt = nil, -- Use default
    prompt_template = nil, -- Use default
  },
}

---@type Hive.Config
M.config = vim.deepcopy(M.defaults)

---Merge user config with defaults
---@param user_opts table?
---@return Hive.Config
function M.setup(user_opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})

  local user_keymap = user_opts and user_opts.agents and user_opts.agents.keymap
  if user_keymap then
    if user_keymap.prefix and user_keymap.prefix ~= "]" then
      local new_defaults = _default_keymaps(user_keymap.prefix)
      M.config.agents.keymap = vim.tbl_deep_extend("force", new_defaults, user_keymap)
    end
    for name, entry in pairs(user_keymap) do
      if type(entry) == "table" and entry.modes and M.config.agents.keymap[name] then
        M.config.agents.keymap[name] = vim.tbl_deep_extend("force", M.config.agents.keymap[name] --[[@as table]], entry)
        M.config.agents.keymap[name].modes = entry.modes
      end
    end
  end

  return M.config
end

---Get current config
---@return Hive.Config
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

---Get the keymap prefix for chat keymaps
---@return string
function M.keymap_prefix()
  local agents = M.config.agents
  local km = agents and agents.keymap
  local prefix = km and km.prefix
  if type(prefix) == "string" then return prefix end
  return "]"
end

---Get resolved modes for a keymap name
---@param name string
---@return table|nil
function M.keymap_modes(name)
  local km = M.config.agents and M.config.agents.keymap and M.config.agents.keymap[name]
  if type(km) == "table" and km.modes then return km.modes end
  return nil
end

return M
