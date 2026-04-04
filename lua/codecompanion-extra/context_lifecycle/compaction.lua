-- Compaction engine for context lifecycle management
-- Summarizes conversation history and rebuilds messages to reduce context usage
-- Inspired by Codex compaction: preserves system prompts, recent messages, and a handoff summary

local tokens_util = require("codecompanion-extra.twinchat.tokens")

local function _debug(msg)
  require("codecompanion-extra.debug").log("compaction", msg)
end

local COMPACTION_TAG = "compaction_summary"
local SUMMARY_MARKER = "compaction_summary_message"

---@class CompactionEngine.Config
---@field recent_budget number Token budget for preserving recent messages (default 20000)
---@field preserve_last_assistant boolean Keep the last assistant message (default true)
---@field compaction_model string|nil nil = same adapter, "adapter/model" = override
---@field notify boolean Notify user on compaction (default true)
---@field max_compactions number Max compactions before warning (default 3)
---@field compaction_prompt string|nil Custom compaction prompt (nil = default)
---@field summary_prefix string|nil Custom summary prefix (nil = default)

local DEFAULT_COMPACTION_PROMPT =
  [[You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for yourself (the same LLM) that will continue the task in this same conversation.

Include:
- Current progress and key decisions made so far
- Important context, constraints, or user preferences discovered
- What task/work is currently in progress and its state
- What remains to be done (clear next steps)
- Any critical data, file paths, code patterns, or references needed to continue
- The current working approach/strategy being used

Be concise and structured. Focus on enabling seamless continuation.
Do NOT include pleasantries or meta-commentary about compaction.]]

local DEFAULT_SUMMARY_PREFIX = [[<compaction_context>
The conversation history has been compacted to manage context window usage. Below is a structured summary of the work done so far. Use this to continue seamlessly without repeating completed work.

</compaction_context>]]

local DEFAULT_CONFIG = {
  recent_budget = 20000,
  preserve_last_assistant = true,
  compaction_model = nil,
  notify = true,
  max_compactions = 3,
  compaction_prompt = nil,
  summary_prefix = nil,
}

---@class CompactionEngine
---@field config CompactionEngine.Config
---@field _compaction_count table<number, number> bufnr → compaction count
local CompactionEngine = {}
CompactionEngine.__index = CompactionEngine

---@param config? CompactionEngine.Config
---@return CompactionEngine
function CompactionEngine.new(config)
  local self = setmetatable({}, CompactionEngine)
  self.config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_CONFIG), config or {})
  self._compaction_count = {}
  return self
end

---Estimate token count for text
---@param text string
---@return number
function CompactionEngine:_estimate_tokens(text)
  return tokens_util.estimate_tokens(text)
end

---Extract system messages from the conversation (always preserved)
---@param messages table[]
---@return table[] system_messages
function CompactionEngine:_extract_system_messages(messages)
  local system = {}
  for _, msg in ipairs(messages) do
    if msg.role == "system" then
      -- Skip previous compaction summaries (will be replaced)
      local is_compaction = msg._meta and msg._meta.tag == COMPACTION_TAG
      if not is_compaction then table.insert(system, vim.deepcopy(msg)) end
    end
  end
  return system
end

---Collect recent messages (newest first, up to token budget)
---@param messages table[]
---@param budget_override? number Override the configured recent_budget
---@return table[] recent_messages
function CompactionEngine:_collect_recent(messages, budget_override)
  local budget = budget_override or self.config.recent_budget
  local collected = {}
  local tokens_used = 0
  local found_assistant = false

  for i = #messages, 1, -1 do
    local msg = messages[i]

    -- Skip system messages (handled separately)
    if msg.role == "system" then goto continue end

    -- Skip previous compaction summaries
    if msg._meta and msg._meta.tag == COMPACTION_TAG then goto continue end
    if msg._meta and msg._meta.tag == SUMMARY_MARKER then goto continue end

    local msg_tokens = tokens_util.estimate_message_tokens(msg)

    if msg.role == "user" then
      if tokens_used + msg_tokens > budget then break end
      table.insert(collected, 1, vim.deepcopy(msg))
      tokens_used = tokens_used + msg_tokens
    elseif
      (msg.role == "llm" or msg.role == "assistant")
      and self.config.preserve_last_assistant
      and not found_assistant
    then
      if tokens_used + msg_tokens > budget then break end
      table.insert(collected, 1, vim.deepcopy(msg))
      tokens_used = tokens_used + msg_tokens
      found_assistant = true
    end

    ::continue::
  end

  _debug(string.format("collect_recent: %d messages, %d tokens used of %d budget", #collected, tokens_used, budget))
  return collected
end

---Build the compaction prompt to send to the LLM
---@param messages table[]
---@return string
function CompactionEngine:_build_compaction_prompt(messages)
  return self.config.compaction_prompt or DEFAULT_COMPACTION_PROMPT
end

---Get the summary prefix text
---@return string
function CompactionEngine:_get_summary_prefix()
  return self.config.summary_prefix or DEFAULT_SUMMARY_PREFIX
end

---Build the messages payload for the compaction LLM call
---Includes conversation history + compaction prompt, truncated to fit context window
---@param chat table The chat object
---@param context_window number|nil Context window size for truncation guard
---@return table[] messages_for_compaction
function CompactionEngine:build_compaction_payload(chat, context_window)
  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return {} end

  local messages = {}

  for _, msg in ipairs(chat.messages) do
    if msg.content and msg.content ~= "" and msg.role ~= "tool" then
      table.insert(messages, {
        role = msg.role,
        content = msg.content,
      })
    end
  end

  local compaction_prompt = self:_build_compaction_prompt(messages)
  table.insert(messages, {
    role = cc_config.constants.USER_ROLE,
    content = compaction_prompt,
  })

  -- Truncation guard: if payload exceeds context window budget, keep bookends
  local budget = math.floor((context_window or 128000) * 0.80)
  local payload_tokens = tokens_util.estimate_total_tokens(messages)

  if payload_tokens > budget then
    _debug(string.format("build_compaction_payload: truncating %d tokens to %d budget", payload_tokens, budget))
    messages = self:_truncate_for_compaction(messages, budget, cc_config)
  end

  return messages
end

---Truncate messages to fit within token budget, keeping bookends (system + recent + compaction prompt)
---@param messages table[]
---@param budget number Token budget
---@param cc_config table
---@return table[]
function CompactionEngine:_truncate_for_compaction(messages, budget, cc_config)
  local head = {}
  local tail = {}
  local head_tokens = 0

  -- Head: collect system messages from the start
  for i, msg in ipairs(messages) do
    if msg.role == "system" or msg.role == cc_config.constants.SYSTEM_ROLE then
      local t = tokens_util.estimate_message_tokens(msg)
      head_tokens = head_tokens + t
      table.insert(head, msg)
    else
      break
    end
  end

  -- The last message is always the compaction prompt — reserve it
  local prompt_msg = messages[#messages]
  local prompt_tokens = tokens_util.estimate_message_tokens(prompt_msg)

  -- Remaining budget for conversation messages (between head and prompt)
  local remaining = budget - head_tokens - prompt_tokens
  if remaining < 0 then remaining = math.floor(budget * 0.5) end

  -- Collect from the end (newest first, excluding prompt which is already reserved)
  local tail_tokens = 0
  for i = #messages - 1, #head + 1, -1 do
    local msg = messages[i]
    local t = tokens_util.estimate_message_tokens(msg)
    if tail_tokens + t > remaining then break end
    table.insert(tail, 1, msg)
    tail_tokens = tail_tokens + t
  end

  local result = {}
  for _, msg in ipairs(head) do
    table.insert(result, msg)
  end
  if #tail < (#messages - #head - 1) then
    table.insert(result, {
      role = cc_config.constants.USER_ROLE,
      content = "[Earlier conversation messages were truncated to fit context window for summarization]",
    })
  end
  for _, msg in ipairs(tail) do
    table.insert(result, msg)
  end
  table.insert(result, prompt_msg)

  _debug(string.format("_truncate_for_compaction: %d → %d messages", #messages, #result))
  return result
end

---Rebuild the chat messages after compaction
---@param chat table The chat object
---@param summary string The compaction summary from the LLM
---@return boolean success
function CompactionEngine:rebuild_messages(chat, summary)
  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return false end

  -- 1. Extract system messages (always preserved)
  local system_msgs = self:_extract_system_messages(chat.messages)

  -- 2. Collect recent user + last assistant messages
  local recent_msgs = self:_collect_recent(chat.messages)

  -- 3. Build the summary with prefix
  local full_summary = self:_get_summary_prefix() .. summary

  -- 4. Track compaction count
  local bufnr = chat.bufnr
  self._compaction_count[bufnr] = (self._compaction_count[bufnr] or 0) + 1
  local count = self._compaction_count[bufnr]

  _debug(
    string.format(
      "rebuild_messages: bufnr=%d compaction_count=%d system=%d recent=%d summary_tokens=~%d",
      bufnr,
      count,
      #system_msgs,
      #recent_msgs,
      self:_estimate_tokens(full_summary)
    )
  )

  -- 5. Replace messages in-place
  -- We clear and rebuild using the existing table reference
  local messages = chat.messages
  for i = #messages, 1, -1 do
    table.remove(messages, i)
  end

  -- Re-inject system prompts
  for _, sys_msg in ipairs(system_msgs) do
    table.insert(messages, sys_msg)
  end

  -- Add compaction summary as a system message
  table.insert(messages, {
    role = cc_config.constants.SYSTEM_ROLE,
    content = full_summary,
    opts = { visible = false },
    _meta = {
      tag = COMPACTION_TAG,
      estimated_tokens = self:_estimate_tokens(full_summary),
      compaction_number = count,
    },
  })

  -- Add recent messages
  for _, msg in ipairs(recent_msgs) do
    table.insert(messages, msg)
  end

  -- 6. Warn after multiple compactions
  if count >= self.config.max_compactions and self.config.notify then
    vim.schedule(function()
      vim.notify(
        string.format(
          "Context compacted %d times. Multiple compactions can reduce accuracy. Consider starting a new chat.",
          count
        ),
        vim.log.levels.WARN
      )
    end)
  end

  return true
end

---Rebuild messages with a custom recent budget (used for aggressive reset)
---@param chat table
---@param summary string
---@param budget number Token budget for recent messages
---@return boolean success
function CompactionEngine:rebuild_messages_with_budget(chat, summary, budget)
  local original_budget = self.config.recent_budget
  self.config.recent_budget = budget
  local success = self:rebuild_messages(chat, summary)
  self.config.recent_budget = original_budget
  return success
end

---Get the compaction count for a buffer
---@param bufnr number
---@return number
function CompactionEngine:get_compaction_count(bufnr)
  return self._compaction_count[bufnr] or 0
end

---Clear state for a buffer
---@param bufnr number
function CompactionEngine:clear_buffer(bufnr)
  self._compaction_count[bufnr] = nil
end

return CompactionEngine
