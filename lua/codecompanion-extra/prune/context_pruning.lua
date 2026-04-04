local api = vim.api

local function _debug(msg)
  require("codecompanion-extra.debug").log("prune", msg)
end

local PRUNABLE_TAG = "prunable_context"
local PRUNED_PLACEHOLDER = "[Output pruned to save context - information superseded or no longer needed]"

---@class ContextPruning.ToolEntry
---@field numeric_id number Position in the prunable list (0-indexed)
---@field call_id string The tool call ID
---@field tool_name string Name of the tool
---@field description string Human-readable description
---@field token_estimate number Rough token count

---@class ContextPruningManager
---@field _pruned_ids table<number, table<string, boolean>> bufnr → set of pruned call_ids
---@field _config table
---@field _protected_set table<string, boolean> set of protected tool names
---@field _last_injected_tokens table<number, number> bufnr → total prunable tokens at last injection
local PruningManager = {}
PruningManager.__index = PruningManager

---@param config? table
---@return ContextPruningManager
function PruningManager.new(config)
  local self = setmetatable({}, PruningManager)
  self._pruned_ids = {}
  self._config = vim.tbl_deep_extend("force", {
    protected_tools = { "prune", "task", "todowrite", "todoread", "consult", "ask_user" },
    min_tokens = 5000,
    delta_tokens = 3000,
  }, config or {})
  self._protected_set = {}
  for _, name in ipairs(self._config.protected_tools) do
    self._protected_set[name] = true
  end
  self._last_injected_tokens = {}
  return self
end

---Estimate token count from text content
---@param content string
---@return number
function PruningManager:_estimate_tokens(content)
  if not content or content == "" then return 0 end

  local raw = #content / 4
  if raw < 10000 then
    return math.floor(raw)
  else
    local step = 10000
    return math.ceil(raw / step) * step
  end
end

---Build a call_id → { name, args } lookup from messages
---LLM tool_call messages have tools.calls = [{id, call_id?, function: {name, arguments}}]
---OpenAI Responses API uses separate `id` (item id) and `call_id` (function call id)
---@param messages table[]
---@return table<string, { name: string, args: table? }>
function PruningManager:_build_call_id_map(messages)
  local map = {}
  local call_count = 0
  for _, msg in ipairs(messages) do
    if msg.tools and msg.tools.calls then
      for _, call in ipairs(msg.tools.calls) do
        if call["function"] and call["function"].name then
          local raw_args = call["function"].arguments
          local parsed_args
          if type(raw_args) == "table" then
            parsed_args = raw_args
          elseif type(raw_args) == "string" and raw_args ~= "" then
            local ok, decoded = pcall(vim.json.decode, raw_args)
            if ok and type(decoded) == "table" then parsed_args = decoded end
          end
          local entry = {
            name = call["function"].name,
            args = parsed_args,
          }
          if call.id then map[call.id] = entry end
          -- OpenAI Responses API: call_id is the actual function call identifier
          if call.call_id and call.call_id ~= call.id then map[call.call_id] = entry end
          call_count = call_count + 1
          _debug(
            string.format(
              "  call_id_map: name=%s id=%s call_id=%s",
              call["function"].name,
              call.id or "nil",
              call.call_id or "nil"
            )
          )
        end
      end
    end
  end
  _debug(string.format("build_call_id_map: %d calls mapped from %d messages", call_count, #messages))
  return map
end

---Extract a description from tool call arguments
---Includes parent/filename for file-related tools so the LLM can identify what it read
---@param tool_name string
---@param args table?
---@return string
function PruningManager:_extract_description(tool_name, args)
  if args then
    local filepath = args.filepath or args.path or args.file
    if filepath then
      local parent = vim.fs.basename(vim.fs.dirname(filepath))
      local base = vim.fs.basename(filepath)
      local short = parent and base and (parent .. "/" .. base) or base or filepath
      return tool_name .. ", " .. short
    end
    local query = args.query or args.cmd or args.command or args.name
    if query then return tool_name .. ", " .. tostring(query) end
  end
  return tool_name
end

---Check if a tool is protected from pruning
---@param tool_name string
---@return boolean
function PruningManager:_is_protected(tool_name)
  return self._protected_set[tool_name] or false
end

---Get the pruned IDs set for a buffer
---@param bufnr number
---@return table<string, boolean>
function PruningManager:_get_pruned_set(bufnr)
  if not self._pruned_ids[bufnr] then self._pruned_ids[bufnr] = {} end
  return self._pruned_ids[bufnr]
end

---Scan chat messages and return ordered list of prunable tool entries
---@param messages table[]
---@param bufnr number
---@return ContextPruning.ToolEntry[]
function PruningManager:scan_messages(messages, bufnr)
  local call_id_map = self:_build_call_id_map(messages)
  local pruned_set = self:_get_pruned_set(bufnr)
  local entries = {}

  local numeric_id = 0
  local skipped_no_call_info = 0
  local skipped_pruned = 0
  local skipped_protected = 0
  for _, msg in ipairs(messages) do
    if msg.role == "tool" and msg.tools and msg.tools.call_id then
      local call_id = msg.tools.call_id
      local call_info = call_id_map[call_id]

      if not call_info then
        skipped_no_call_info = skipped_no_call_info + 1
        _debug(string.format("  scan: tool msg call_id=%s -> NO match in call_id_map", call_id))
      elseif pruned_set[call_id] then
        skipped_pruned = skipped_pruned + 1
      elseif self:_is_protected(call_info.name) then
        skipped_protected = skipped_protected + 1
      else
        local description = self:_extract_description(call_info.name, call_info.args)
        local token_estimate = self:_estimate_tokens(msg.content)

        table.insert(entries, {
          numeric_id = numeric_id,
          call_id = call_id,
          tool_name = call_info.name,
          description = description,
          token_estimate = token_estimate,
        })
        numeric_id = numeric_id + 1
      end
    end
  end

  _debug(
    string.format(
      "scan_messages: bufnr=%d entries=%d skipped_no_match=%d skipped_pruned=%d skipped_protected=%d",
      bufnr,
      #entries,
      skipped_no_call_info,
      skipped_pruned,
      skipped_protected
    )
  )
  return entries
end

---Build the <prunable-tools> XML string
---@param messages table[]
---@param bufnr number
---@param eval? ContextLifecycle.Evaluation Optional evaluation for nudge injection
---@return string
function PruningManager:build_prunable_list(messages, bufnr, eval)
  local entries = self:scan_messages(messages, bufnr)
  if #entries == 0 then return "" end

  local lines = {}
  for _, entry in ipairs(entries) do
    table.insert(lines, string.format("%d: %s (~%d tokens)", entry.numeric_id, entry.description, entry.token_estimate))
  end

  local utilization = ""
  if eval and eval.context_window and eval.context_window > 0 then
    utilization = string.format(
      "\nContext: %dk / %dk tokens (%d%% used)",
      math.floor(eval.estimated_tokens / 1000),
      math.floor(eval.context_window / 1000),
      math.floor(eval.percentage)
    )
  end

  local nudge = ""
  if eval and eval.urgency == "medium" then
    nudge = string.format(
      "\n⚠ Context window at %d%% (%dk/%dk tokens). Strongly recommend pruning large tool outputs to maintain conversation quality.",
      math.floor(eval.percentage),
      math.floor(eval.estimated_tokens / 1000),
      math.floor(eval.context_window / 1000)
    )
  elseif eval and eval.urgency == "low" then
    nudge = string.format(
      "\nContext is at %d%%. Consider pruning tool outputs you no longer need.",
      math.floor(eval.percentage)
    )
  end

  return string.format(
    [[<prunable-tools>
The following tool outputs are in your context and eligible for pruning. Reference by numeric ID.
%s
</prunable-tools>]],
    table.concat(lines, "\n")
  ) .. utilization .. nudge
end

---Execute pruning: map numeric IDs to call_ids, mutate messages in-place
---@param chat table The chat object
---@param numeric_ids number[] Array of numeric IDs from the prunable list
---@return { pruned: number, tokens_saved: number, skipped: string[] }
function PruningManager:prune(chat, numeric_ids)
  local messages = chat.messages
  local bufnr = chat.bufnr
  if not messages or not bufnr then return { pruned = 0, tokens_saved = 0, skipped = { "Invalid chat object" } } end
  local entries = self:scan_messages(messages, bufnr)
  local pruned_set = self:_get_pruned_set(bufnr)

  local id_to_entry = {}
  for _, entry in ipairs(entries) do
    id_to_entry[entry.numeric_id] = entry
  end

  local pruned_count = 0
  local tokens_saved = 0
  local skipped = {}

  for _, nid in ipairs(numeric_ids) do
    local entry = id_to_entry[nid]
    if not entry then
      table.insert(skipped, string.format("ID %d: not found in prunable list", nid))
    else
      pruned_set[entry.call_id] = true
      tokens_saved = tokens_saved + entry.token_estimate

      for _, msg in ipairs(messages) do
        if msg.role == "tool" and msg.tools and msg.tools.call_id == entry.call_id then
          msg.content = PRUNED_PLACEHOLDER
          break
        end
      end

      pruned_count = pruned_count + 1
    end
  end

  return {
    pruned = pruned_count,
    tokens_saved = tokens_saved,
    skipped = skipped,
  }
end

---Find a safe insertion point before the last contiguous assistant+tool block.
---Walks backward past tool messages, then past the preceding LLM message
---that triggered them (to avoid splitting an LLM{tool_calls}→tool sequence).
---Returns #messages + 1 when the tail has no tool messages (i.e. append).
---@param messages table[]
---@return number
local function _tool_tail_start(messages)
  local i = #messages
  while i >= 1 and messages[i].role == "tool" do
    i = i - 1
  end
  -- If the message just before the tool run is an LLM/assistant with tool_calls,
  -- step past it so we don't inject between it and its tool responses.
  if i >= 1 and messages[i].tools and messages[i].tools.calls then i = i - 1 end
  return i + 1
end

---Find or create the prunable-context tagged message and update it.
---Removes stale message only if near the tail (within last TAIL_WINDOW messages)
---to avoid breaking cache prefix for messages deep in history.
---Inserts before the last tool-message run so adapters (Copilot) that inspect
---messages[#messages].role still see "tool" at the tail during agentic loops.
---@param chat table The chat object
---@param eval? ContextLifecycle.Evaluation Optional evaluation for nudge injection
---@param opts? { force?: boolean } force=true bypasses thresholds (used after prune execution)
function PruningManager:update_prunable_message(chat, eval, opts)
  opts = opts or {}
  local messages = chat.messages
  local bufnr = chat.bufnr
  _debug(string.format("update_prunable_message: bufnr=%s msg_count=%d", tostring(bufnr), #messages))

  local entries = self:scan_messages(messages, bufnr)
  local total_tokens = 0
  for _, entry in ipairs(entries) do
    total_tokens = total_tokens + entry.token_estimate
  end

  local last_tokens = self._last_injected_tokens[bufnr] or 0
  local delta = math.abs(total_tokens - last_tokens)
  local below_min = total_tokens < self._config.min_tokens
  local below_delta = delta < self._config.delta_tokens

  if not opts.force and below_min then
    _debug(string.format("  skip: total_tokens=%d < min=%d", total_tokens, self._config.min_tokens))
    return
  end

  if not opts.force and last_tokens > 0 and below_delta then
    _debug(string.format("  skip: delta=%d < threshold=%d", delta, self._config.delta_tokens))
    return
  end

  local prunable_list = self:build_prunable_list(messages, bufnr, eval)

  local TAIL_WINDOW = 15
  local search_start = math.max(1, #messages - TAIL_WINDOW)
  for i = #messages, search_start, -1 do
    if messages[i]._meta and messages[i]._meta.tag == PRUNABLE_TAG then
      table.remove(messages, i)
      break
    end
  end

  if prunable_list ~= "" then
    local ok, cc_config = pcall(require, "codecompanion.config")
    if not ok then return end

    local insert_at = _tool_tail_start(messages)
    chat:add_message({
      role = cc_config.constants.USER_ROLE,
      content = prunable_list,
    }, {
      visible = false,
      _meta = { tag = PRUNABLE_TAG, index = insert_at },
    })
    self._last_injected_tokens[bufnr] = total_tokens
  end
end

---Clear state for a buffer
---@param bufnr number
function PruningManager:clear_buffer(bufnr)
  self._pruned_ids[bufnr] = nil
  self._last_injected_tokens[bufnr] = nil
end

---Setup autocmd listeners for context injection
function PruningManager:setup_events()
  local group = api.nvim_create_augroup("CCExtraContextPruning", { clear = true })

  api.nvim_create_autocmd("User", {
    pattern = { "CodeCompanionChatDone", "CodeCompanionToolsFinished" },
    group = group,
    callback = function(event)
      local bufnr = event.data and event.data.bufnr
      if not bufnr then return end
      _debug(string.format("event: %s bufnr=%d", event.match, bufnr))

      -- Skip if context lifecycle manager is active (it handles prunable updates with nudges)
      local cl_ok, context_lifecycle = pcall(require, "codecompanion-extra.context_lifecycle")
      if cl_ok and context_lifecycle.instance and context_lifecycle.instance() then return end

      local h_ok, hierarchy = pcall(require, "codecompanion-extra.agents.hierarchy")
      if h_ok and hierarchy.get_session then
        local session = hierarchy.get_session(bufnr)
        if session and session.agent_type == "subagent" then return end
      end

      local ok, codecompanion = pcall(require, "codecompanion")
      if not ok then return end

      local chat_ok, chat = pcall(codecompanion.buf_get_chat, bufnr)
      if not chat_ok or not chat or not chat.messages then return end

      self:update_prunable_message(chat)
    end,
  })

  api.nvim_create_autocmd("User", {
    pattern = "CodeCompanionChatClosed",
    group = group,
    callback = function(event)
      local bufnr = event.data and event.data.bufnr
      if bufnr then self:clear_buffer(bufnr) end
    end,
  })
end

local M = {}
local _instance = nil

---Setup the context pruning manager
---@param config? table
function M.setup(config)
  _instance = PruningManager.new(config)
  _instance:setup_events()
end

---Get the singleton instance
---@return ContextPruningManager|nil
function M.instance()
  return _instance
end

return M
