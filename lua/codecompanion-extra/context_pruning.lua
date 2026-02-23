local api = vim.api

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
local PruningManager = {}
PruningManager.__index = PruningManager

---@param config? table
---@return ContextPruningManager
function PruningManager.new(config)
  local self = setmetatable({}, PruningManager)
  self._pruned_ids = {}
  self._config = vim.tbl_deep_extend("force", {
    protected_tools = { "prune", "task", "todowrite", "todoread", "consult", "ask_user" },
  }, config or {})
  self._protected_set = {}
  for _, name in ipairs(self._config.protected_tools) do
    self._protected_set[name] = true
  end
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
---LLM tool_call messages have tools.calls = [{id, function: {name, arguments}}]
---@param messages table[]
---@return table<string, { name: string, args: table? }>
function PruningManager:_build_call_id_map(messages)
  local map = {}
  for _, msg in ipairs(messages) do
    if msg.tools and msg.tools.calls then
      for _, call in ipairs(msg.tools.calls) do
        if call.id and call["function"] and call["function"].name then
          map[call.id] = {
            name = call["function"].name,
            args = type(call["function"].arguments) == "table" and call["function"].arguments or nil,
          }
        end
      end
    end
  end
  return map
end

---Extract a description from tool call arguments
---@param tool_name string
---@param args table?
---@return string
function PruningManager:_extract_description(tool_name, args)
  if args then
    local filepath = args.filepath or args.path or args.file
    if filepath then return tool_name .. ", " .. filepath end
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
  for _, msg in ipairs(messages) do
    if msg.role == "tool" and msg.tools and msg.tools.call_id then
      local call_id = msg.tools.call_id
      local call_info = call_id_map[call_id]

      if call_info and not pruned_set[call_id] and not self:_is_protected(call_info.name) then
        local description = self:_extract_description(call_info.name, call_info.args)
        local token_estimate = self:_estimate_tokens(msg.content)

        table.insert(entries, {
          numeric_id = numeric_id,
          call_id = call_id,
          tool_name = call_info.name,
          description = description,
          token_estimate = token_estimate,
        })
      end
      numeric_id = numeric_id + 1
    end
  end

  return entries
end

---Build the <prunable-tools> XML string
---@param messages table[]
---@param bufnr number
---@return string
function PruningManager:build_prunable_list(messages, bufnr)
  local entries = self:scan_messages(messages, bufnr)
  if #entries == 0 then return "" end

  local lines = {}
  for _, entry in ipairs(entries) do
    table.insert(lines, string.format("%d: %s (~%d tokens)", entry.numeric_id, entry.description, entry.token_estimate))
  end

  return string.format(
    [[<prunable-tools>
The following tool outputs are in your context and eligible for pruning. Reference by numeric ID.
%s
</prunable-tools>]],
    table.concat(lines, "\n")
  )
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

---Find or create the prunable-context tagged message and update it
---@param chat table The chat object
function PruningManager:update_prunable_message(chat)
  local messages = chat.messages
  local bufnr = chat.bufnr
  local prunable_list = self:build_prunable_list(messages, bufnr)

  for i, msg in ipairs(messages) do
    if msg._meta and msg._meta.tag == PRUNABLE_TAG then
      if prunable_list ~= "" then
        msg.content = prunable_list
      else
        table.remove(messages, i)
      end
      return
    end
  end

  if prunable_list ~= "" then
    local ok, cc_config = pcall(require, "codecompanion.config")
    if not ok then return end

    chat:add_message({
      role = cc_config.constants.SYSTEM_ROLE,
      content = prunable_list,
    }, {
      visible = false,
      _meta = { tag = PRUNABLE_TAG },
    })
  end
end

---Clear state for a buffer
---@param bufnr number
function PruningManager:clear_buffer(bufnr)
  self._pruned_ids[bufnr] = nil
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
