-- Token estimation for chat messages
-- Provides token counting heuristics for context window management

local M = {}

-- Default characters per token (rough approximation)
-- Most tokenizers average ~4 characters per token for English text
local DEFAULT_CHARS_PER_TOKEN = 4

-- Known context window sizes for common models (in tokens)
-- Primary: high-confidence values from provider documentation
-- Fallback: approximate/generic values for prefix matching
local MODEL_PRIMARY = {
  -- OpenAI
  ["gpt-5.4"] = 256000,
  ["gpt-5.3"] = 256000,
  ["gpt-5.2"] = 256000,
  ["gpt-4.1"] = 30000,
  ["gpt-4o"] = 128000,
  ["gpt-4o-mini"] = 128000,
  ["gpt-oss-120b"] = 128000,
  ["gpt-oss-20b"] = 128000,
  -- Anthropic
  ["claude-opus-4.6"] = 200000,
  ["claude-sonnet-4.6"] = 200000,
  ["claude-opus-4.5"] = 200000,
  ["claude-sonnet-4.5"] = 200000,
  ["claude-haiku-4.5"] = 200000,
  ["claude-opus-4"] = 200000,
  ["claude-sonnet-4"] = 200000,
  ["claude-haiku-4"] = 200000,
  -- Google Gemini
  ["gemini-3.1-pro"] = 250000,
  ["gemini-3.1-flash-lite"] = 250000,
  ["gemini-3-flash"] = 250000,
  ["gemini-3-pro"] = 250000,
  -- DeepSeek
  ["deepseek-chat"] = 164000,
  ["deepseek-v3"] = 164000,
  ["deepseek-v3.1"] = 164000,
  ["deepseek-v3.2"] = 164000,
  ["deepseek-reasoner"] = 64000,
  ["deepseek-r1"] = 164000,
  -- Qwen / Alibaba
  ["qwen3.5-plus"] = 200000,
  ["qwen3.5"] = 256000,
  ["qwen3-max"] = 262144,
  ["qwen3-235b"] = 128000,
  ["qwen3-30b"] = 128000,
  ["qwen3-coder"] = 256000,
  ["qwen-plus"] = 1000000,
  ["qwen-turbo"] = 1000000,
  ["qwq"] = 131072,
  ["qwq-32b"] = 131072,
  -- Kimi / Moonshot AI
  ["kimi-k2.5"] = 256000,
  ["kimi-k2"] = 128000,
  -- MiniMax
  ["minimax-m2.7"] = 200000,
  ["minimax-m2.5"] = 196600,
  -- GLM / Zhipu AI
  ["glm-5.1"] = 200000,
  ["glm-5"] = 200000,
  -- Mistral
  ["mistral-large"] = 128000,
  ["mistral-medium"] = 32000,
  ["codestral"] = 256000,
  ["pixtral-large"] = 128000,
  -- xAI Grok
  ["grok-4"] = 256000,
  ["grok-3"] = 131072,
  ["grok-3-mini"] = 131072,
}

-- Fallback: family-level defaults used when no primary match is found.
-- These use prefix matching so "claude-sonnet" matches "claude-sonnet-4-20250514".
local MODEL_FALLBACK = {
  ["gpt-5"] = 256000,
  ["gpt-4"] = 128000,
  ["gpt-oss"] = 128000,
  ["claude-opus"] = 200000,
  ["claude-sonnet"] = 200000,
  ["claude-haiku"] = 200000,
  ["gemini"] = 250000,
  ["deepseek"] = 164000,
  ["qwen"] = 128000,
  ["kimi"] = 128000,
  ["minimax"] = 200000,
  ["glm"] = 200000,
  ["mistral"] = 128000,
  ["grok"] = 131072,
}

---Estimate token count from text content
---Uses simple heuristic: characters / 4
---@param content string|nil
---@return number
function M.estimate_tokens(content)
  if not content or content == "" then return 0 end

  local raw = #content / DEFAULT_CHARS_PER_TOKEN
  if raw < 10000 then
    return math.floor(raw)
  else
    local step = 10000
    return math.ceil(raw / step) * step
  end
end

---Estimate tokens for a message object
---Handles different message content formats (string, array of parts)
---@param msg table Message object with role and content
---@return number
function M.estimate_message_tokens(msg)
  if not msg then return 0 end

  local tokens = 0

  -- Role overhead (~4 tokens for role markers)
  tokens = tokens + 4

  -- Content
  if msg.content then
    if type(msg.content) == "string" then
      tokens = tokens + M.estimate_tokens(msg.content)
    elseif type(msg.content) == "table" then
      -- Multi-part content (e.g., images + text)
      for _, part in ipairs(msg.content) do
        if type(part) == "table" then
          if part.type == "text" and part.text then
            tokens = tokens + M.estimate_tokens(part.text)
          elseif part.type == "image_url" then
            -- Images: rough estimate based on detail level
            tokens = tokens + (part.detail == "low" and 85 or 1105)
          end
        end
      end
    end
  end

  -- Tool calls
  if msg.tools and msg.tools.calls then
    for _, call in ipairs(msg.tools.calls) do
      if call["function"] then
        tokens = tokens + M.estimate_tokens(call["function"].name or "")
        tokens = tokens + M.estimate_tokens(call["function"].arguments or "")
      end
    end
  end

  -- Reasoning content (for models that support it)
  if msg.reasoning then
    if msg.reasoning.content then tokens = tokens + M.estimate_tokens(msg.reasoning.content) end
  end

  return tokens
end

---Estimate total tokens for an array of messages
---@param messages table[] Array of message objects
---@return number
function M.estimate_total_tokens(messages)
  if not messages then return 0 end

  local total = 0
  for _, msg in ipairs(messages) do
    total = total + M.estimate_message_tokens(msg)
  end

  return total
end

---Get context window size for a model
---Priority: user override → adapter dynamic → lookup table → default
---@param adapter_name string|nil
---@param model_name string|nil
---@param chat table|nil Optional chat object for adapter-provided context window
---@param override number|nil User-configured context window override (takes top priority)
---@return number context_window_size
function M.get_context_window(adapter_name, model_name, chat, override)
  if override and override > 0 then return override end

  -- 1. Try adapter-provided context window (e.g. Copilot's limits.max_context_window_tokens)
  if chat then
    local ctx = M._get_adapter_context_window(chat)
    if ctx and ctx > 0 then return ctx end
  end

  if not model_name then return 128000 end

  local normalized = model_name:lower():gsub("^%s+", ""):gsub("%s+$", "")

  -- 1. Direct match in primary table
  if MODEL_PRIMARY[normalized] then return MODEL_PRIMARY[normalized] end

  -- 2. Prefix match in primary table (longest match wins)
  local best_match = nil
  local best_len = 0
  for pattern, size in pairs(MODEL_PRIMARY) do
    if normalized:find(pattern, 1, true) == 1 and #pattern > best_len then
      best_match = size
      best_len = #pattern
    end
  end
  if best_match then return best_match end

  -- 3. Direct match in fallback table
  if MODEL_FALLBACK[normalized] then return MODEL_FALLBACK[normalized] end

  -- 4. Prefix match in fallback table (longest match wins)
  best_match = nil
  best_len = 0
  for pattern, size in pairs(MODEL_FALLBACK) do
    if normalized:find(pattern, 1, true) == 1 and #pattern > best_len then
      best_match = size
      best_len = #pattern
    end
  end
  if best_match then return best_match end

  -- Default fallback
  return 128000
end

---Try to extract context window from the adapter's model info
---@param chat table
---@return number|nil
function M._get_adapter_context_window(chat)
  local adapter = chat.adapter
  if not adapter then return nil end

  -- Check adapter.model.info.limits (set by some adapters after model resolution)
  if adapter.model and adapter.model.info and adapter.model.info.limits then
    local ctx = adapter.model.info.limits.max_context_window_tokens
    if ctx then return ctx end
  end

  -- Check schema choices for the current model (Copilot stores limits here)
  if adapter.schema and adapter.schema.model then
    local model = adapter.schema.model.default
    if type(model) == "function" then model = pcall(model, adapter) or nil end
    local choices = adapter.schema.model.choices
    if model and type(choices) == "table" and choices[model] then
      local choice = choices[model]
      if choice.limits and choice.limits.max_context_window_tokens then
        return choice.limits.max_context_window_tokens
      end
    end
  end

  -- Check global metadata
  local metadata = _G.codecompanion_chat_metadata and _G.codecompanion_chat_metadata[chat.bufnr]
  if metadata and metadata.adapter and metadata.adapter.model_info then
    local info = metadata.adapter.model_info
    if info.limits and info.limits.max_context_window_tokens then return info.limits.max_context_window_tokens end
  end

  return nil
end

---Calculate context window utilization percentage
---@param messages table[] Array of message objects
---@param adapter_name string|nil
---@param model_name string|nil
---@param chat table|nil Optional chat object for adapter-provided context window
---@param context_window_override number|nil User-configured context window override
---@return number percentage (0-100)
---@return number estimated_tokens
---@return number context_window
function M.get_context_utilization(messages, adapter_name, model_name, chat, context_window_override)
  local estimated_tokens = M.estimate_total_tokens(messages)
  local context_window = M.get_context_window(adapter_name, model_name, chat, context_window_override)
  local percentage = (estimated_tokens / context_window) * 100

  return percentage, estimated_tokens, context_window
end

return M
