-- Twinchat - Automatic context continuation for CodeCompanion
-- Spawns a continuation chat when the context window reaches a threshold

local M = {}

-- Module state
local _initialized = false
local _config = {}

---Default configuration
local DEFAULT_CONFIG = {
  enabled = true,
  threshold = 75,
  min_messages = 5,
  cooldown_seconds = 300,
  model_type = "small",
  inherit_messages = 10,
  auto_prune = false,
  notify = true,
  system_prompt = nil, -- Use default
  prompt_template = nil, -- Use default
}

---Setup twinchat module
---@param config TwinchatConfig|nil
function M.setup(config)
  if _initialized then return end

  _config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, config or {})

  if not _config.enabled then return end

  -- Setup monitor
  local monitor = require("hive.twinchat.monitor")
  local spawner = require("hive.twinchat.spawner")

  -- Configure spawner
  spawner.setup({
    enabled = _config.enabled,
    model_type = _config.model_type,
    inherit_messages = _config.inherit_messages,
    auto_prune = _config.auto_prune,
    notify = _config.notify,
    system_prompt = _config.system_prompt,
    prompt_template = _config.prompt_template,
  })

  -- Configure monitor with callback
  monitor.setup({
    enabled = _config.enabled,
    threshold = _config.threshold,
    min_messages = _config.min_messages,
    cooldown_seconds = _config.cooldown_seconds,
    on_threshold_reached = function(bufnr, info)
      spawner.spawn(bufnr, info)
    end,
  })

  _initialized = true
end

---Stop twinchat monitoring
function M.stop()
  local monitor = require("hive.twinchat.monitor")
  monitor.stop()
end

---Manually check a chat for threshold
---@param bufnr number
function M.check_chat(bufnr)
  local monitor = require("hive.twinchat.monitor")
  monitor.check_chat(bufnr)
end

---Get context info for a chat
---@param bufnr number
---@return table|nil { percentage: number, estimated_tokens: number, context_window: number }
function M.get_context_info(bufnr)
  local monitor = require("hive.twinchat.monitor")
  return monitor.get_context_info(bufnr)
end

---Check if a chat has a twin
---@param bufnr number
---@return boolean
function M.has_twin(bufnr)
  local spawner = require("hive.twinchat.spawner")
  return spawner.has_twin(bufnr)
end

---Get twin chat buffer number
---@param bufnr number
---@return number|nil
function M.get_twin_bufnr(bufnr)
  local spawner = require("hive.twinchat.spawner")
  return spawner:get_twin_bufnr(bufnr)
end

---Reset threshold state for a chat (e.g., after manual pruning)
---@param bufnr number
function M.reset_threshold(bufnr)
  local monitor = require("hive.twinchat.monitor")
  monitor.reset_threshold(bufnr)
end

---Get current configuration
---@return TwinchatConfig
function M.get_config()
  return vim.deepcopy(_config)
end

return M
