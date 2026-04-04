-- Threshold evaluation for context lifecycle management
-- Determines which layer should activate based on context utilization percentage

local tokens_util = require("hive.twinchat.tokens")

---@alias ContextLifecycle.Action "none"|"nudge"|"compact"|"reset"

---@class ContextLifecycle.ThresholdConfig
---@field nudge_start number Percentage to begin soft nudges (default 50)
---@field nudge_strong number Percentage for strong nudge (default 60)
---@field compact_threshold number Percentage to trigger compaction (default 75)
---@field reset_threshold number Percentage for context reset (default 90)
---@field min_messages number Minimum messages before any layer activates (default 6)
---@field context_window_tokens number|nil User override for context window size

---@class ContextLifecycle.Evaluation
---@field action ContextLifecycle.Action
---@field percentage number Current utilization percentage (0-100)
---@field estimated_tokens number
---@field context_window number
---@field urgency "none"|"low"|"medium"|"high"|"critical"

local DEFAULT_CONFIG = {
  nudge_start = 50,
  nudge_strong = 60,
  compact_threshold = 75,
  reset_threshold = 90,
  min_messages = 6,
}

---@class ThresholdEvaluator
---@field config ContextLifecycle.ThresholdConfig
local ThresholdEvaluator = {}
ThresholdEvaluator.__index = ThresholdEvaluator

---@param config? ContextLifecycle.ThresholdConfig
---@return ThresholdEvaluator
function ThresholdEvaluator.new(config)
  local self = setmetatable({}, ThresholdEvaluator)
  self.config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_CONFIG), config or {})
  return self
end

---Get adapter and model name from a chat object
---@param chat table
---@return string|nil adapter_name
---@return string|nil model_name
function ThresholdEvaluator:_get_adapter_info(chat)
  if not chat.adapter then return nil, nil end

  local adapter_name = chat.adapter.name
  local model_name = chat.adapter.schema and chat.adapter.schema.model and chat.adapter.schema.model.default
  if type(model_name) == "function" then model_name = model_name(chat.adapter) end

  return adapter_name, model_name
end

---Get real API token count from the chat if available
---Falls back to heuristic estimation
---@param chat table
---@return number|nil real_tokens Total tokens from API response
function ThresholdEvaluator:_get_api_tokens(chat)
  -- Primary: chat.ui.tokens (set by adapter's tokens handler from usage.total_tokens)
  if chat.ui and chat.ui.tokens and chat.ui.tokens > 0 then return chat.ui.tokens end

  -- Fallback: global metadata
  local metadata = _G.codecompanion_chat_metadata and _G.codecompanion_chat_metadata[chat.bufnr]
  if metadata and metadata.tokens and metadata.tokens > 0 then return metadata.tokens end

  return nil
end

---Evaluate context utilization and determine the appropriate action
---@param chat table The chat object
---@return ContextLifecycle.Evaluation
function ThresholdEvaluator:evaluate(chat)
  local messages = chat.messages or {}

  local adapter_name, model_name = self:_get_adapter_info(chat)
  local percentage, estimated_tokens, context_window =
    tokens_util.get_context_utilization(messages, adapter_name, model_name, chat, self.config.context_window_tokens)

  -- Prefer real API token count over heuristic when available
  local api_tokens = self:_get_api_tokens(chat)
  if api_tokens then
    estimated_tokens = api_tokens
    percentage = (estimated_tokens / context_window) * 100
  end

  -- Below minimum message count — no action
  if #messages < self.config.min_messages then
    return {
      action = "none",
      percentage = percentage,
      estimated_tokens = estimated_tokens,
      context_window = context_window,
      urgency = "none",
    }
  end

  local action, urgency = "none", "none"

  if percentage >= self.config.reset_threshold then
    action = "reset"
    urgency = "critical"
  elseif percentage >= self.config.compact_threshold then
    action = "compact"
    urgency = "high"
  elseif percentage >= self.config.nudge_strong then
    action = "nudge"
    urgency = "medium"
  elseif percentage >= self.config.nudge_start then
    action = "nudge"
    urgency = "low"
  end

  return {
    action = action,
    percentage = percentage,
    estimated_tokens = estimated_tokens,
    context_window = context_window,
    urgency = urgency,
  }
end

---Build a nudge message based on urgency level
---@param eval ContextLifecycle.Evaluation
---@return string|nil nudge_text nil if no nudge needed
function ThresholdEvaluator:build_nudge(eval)
  if eval.action ~= "nudge" then return nil end

  if eval.urgency == "medium" then
    return string.format(
      "⚠ Context window at %d%% (%dk/%dk tokens). Strongly recommend pruning large tool outputs from <prunable-tools> to maintain conversation quality.",
      math.floor(eval.percentage),
      math.floor(eval.estimated_tokens / 1000),
      math.floor(eval.context_window / 1000)
    )
  end

  -- Low urgency
  return string.format(
    "Context window at %d%%. Consider pruning tool outputs you no longer need from <prunable-tools>.",
    math.floor(eval.percentage)
  )
end

return ThresholdEvaluator
