-- Context window monitor for twinchat spawning
-- Watches chat messages and triggers twinchat when context threshold is reached

local api = vim.api
local log = require("codecompanion.utils.log")
local tokens = require("codecompanion-extra.twinchat.tokens")

local M = {}

-- Singleton monitor instance
local _monitor_instance = nil

---@class TwinchatMonitor
---@field config TwinchatMonitorConfig
---@field tracked_chats table<number, TwinchatChatTracker> bufnr -> tracker
---@field aug_id number|nil Autocommand group ID
local TwinchatMonitor = {}
TwinchatMonitor.__index = TwinchatMonitor

---@class TwinchatMonitorConfig
---@field enabled boolean
---@field threshold number Percentage (0-100) at which to spawn twinchat
---@field min_messages number Minimum messages before monitoring starts
---@field cooldown_seconds number Seconds between twinchat spawns for same chat
---@field on_threshold_reached fun(bufnr: number, info: TwinchatThresholdInfo)|nil Callback when threshold reached

---@class TwinchatChatTracker
---@field bufnr number
---@field last_spawn_time number|nil os.time() of last twinchat spawn
---@field message_count number Last known message count
---@field last_token_estimate number Last estimated token count
---@field threshold_triggered boolean Whether threshold has been triggered for this chat

---@class TwinchatThresholdInfo
---@field percentage number
---@field estimated_tokens number
---@field context_window number
---@field adapter_name string|nil
---@field model_name string|nil
---@field message_count number

---Create a new monitor instance
---@param config TwinchatMonitorConfig|nil
---@return TwinchatMonitor
function TwinchatMonitor.new(config)
  local self = setmetatable({}, TwinchatMonitor)

  self.config = vim.tbl_deep_extend("force", {
    enabled = true,
    threshold = 75,
    min_messages = 5,
    cooldown_seconds = 300, -- 5 minutes
    on_threshold_reached = nil,
  }, config or {})

  self.tracked_chats = {}
  self.aug_id = nil

  return self
end

---Start monitoring all chats
function TwinchatMonitor:start()
  if self.aug_id then return end -- Already running

  self.aug_id = api.nvim_create_augroup("TwinchatMonitor", { clear = true })

  -- Monitor when messages are added to chats
  api.nvim_create_autocmd("User", {
    group = self.aug_id,
    pattern = "CodeCompanionChatSubmitted",
    callback = function(event)
      if not self.config.enabled then return end

      local bufnr = event.data and event.data.bufnr
      if not bufnr then return end

      -- Skip if context lifecycle manager is active (it handles thresholds)
      local cl_ok, context_lifecycle = pcall(require, "codecompanion-extra.context_lifecycle")
      if cl_ok and context_lifecycle.instance and context_lifecycle.instance() then return end

      self:check_chat(bufnr)
    end,
  })

  -- Clean up when chats are closed
  api.nvim_create_autocmd("User", {
    group = self.aug_id,
    pattern = "CodeCompanionChatClosed",
    callback = function(event)
      local bufnr = event.data and event.data.bufnr
      if bufnr and self.tracked_chats[bufnr] then self.tracked_chats[bufnr] = nil end
    end,
  })

  log:debug("[TwinchatMonitor] Started monitoring")
end

---Stop monitoring
function TwinchatMonitor:stop()
  if self.aug_id then
    pcall(api.nvim_del_augroup_by_id, self.aug_id)
    self.aug_id = nil
  end

  self.tracked_chats = {}
  log:debug("[TwinchatMonitor] Stopped monitoring")
end

---Check a specific chat for threshold
---@param bufnr number
function TwinchatMonitor:check_chat(bufnr)
  local ok, chat = pcall(require("codecompanion").buf_get_chat, bufnr)
  if not ok or not chat then return end

  -- Get or create tracker
  local tracker = self.tracked_chats[bufnr]
  if not tracker then
    tracker = {
      bufnr = bufnr,
      last_spawn_time = nil,
      message_count = 0,
      last_token_estimate = 0,
      threshold_triggered = false,
    }
    self.tracked_chats[bufnr] = tracker
  end

  -- Update message count
  local messages = chat.messages or {}
  tracker.message_count = #messages

  -- Skip if not enough messages
  if #messages < self.config.min_messages then return end

  -- Get adapter/model info
  local adapter_name, model_name = nil, nil
  if chat.adapter then
    adapter_name = chat.adapter.name
    model_name = chat.adapter.schema and chat.adapter.schema.model and chat.adapter.schema.model.default
    if type(model_name) == "function" then model_name = model_name(chat.adapter) end
  end

  -- Calculate context utilization
  local percentage, estimated_tokens, context_window =
    tokens.get_context_utilization(messages, adapter_name, model_name, chat)

  tracker.last_token_estimate = estimated_tokens

  -- Check if threshold reached
  if percentage >= self.config.threshold then
    -- Check cooldown
    local now = os.time()
    if tracker.last_spawn_time then
      local elapsed = now - tracker.last_spawn_time
      if elapsed < self.config.cooldown_seconds then
        log:debug(
          "[TwinchatMonitor] Threshold reached but in cooldown (%ds remaining)",
          self.config.cooldown_seconds - elapsed
        )
        return
      end
    end

    -- Mark as triggered
    tracker.threshold_triggered = true
    tracker.last_spawn_time = now

    -- Emit event
    local info = {
      percentage = percentage,
      estimated_tokens = estimated_tokens,
      context_window = context_window,
      adapter_name = adapter_name,
      model_name = model_name,
      message_count = #messages,
    }

    log:info(
      "[TwinchatMonitor] Threshold reached: %.1f%% (%d / %d tokens)",
      percentage,
      estimated_tokens,
      context_window
    )

    -- Call callback if set
    if self.config.on_threshold_reached then self.config.on_threshold_reached(bufnr, info) end

    -- Emit user event
    api.nvim_exec_autocmds("User", {
      pattern = "TwinchatThresholdReached",
      data = info,
    })
  end
end

---Reset threshold state for a chat (e.g., after pruning)
---@param bufnr number
function TwinchatMonitor:reset_threshold(bufnr)
  local tracker = self.tracked_chats[bufnr]
  if tracker then
    tracker.threshold_triggered = false
    tracker.last_spawn_time = nil
  end
end

---Get current context info for a chat
---@param bufnr number
---@return TwinchatThresholdInfo|nil
function TwinchatMonitor:get_context_info(bufnr)
  local ok, chat = pcall(require("codecompanion").buf_get_chat, bufnr)
  if not ok or not chat then return nil end

  local messages = chat.messages or {}

  -- Get adapter/model info
  local adapter_name, model_name = nil, nil
  if chat.adapter then
    adapter_name = chat.adapter.name
    model_name = chat.adapter.schema and chat.adapter.schema.model and chat.adapter.schema.model.default
    if type(model_name) == "function" then model_name = model_name(chat.adapter) end
  end

  local percentage, estimated_tokens, context_window =
    tokens.get_context_utilization(messages, adapter_name, model_name, chat)

  return {
    percentage = percentage,
    estimated_tokens = estimated_tokens,
    context_window = context_window,
    adapter_name = adapter_name,
    model_name = model_name,
    message_count = #messages,
  }
end

-- ============================================================================
-- Module API
-- ============================================================================

---Get or create the singleton monitor instance
---@param config TwinchatMonitorConfig|nil
---@return TwinchatMonitor
function M.get_monitor(config)
  if not _monitor_instance then _monitor_instance = TwinchatMonitor.new(config) end
  return _monitor_instance
end

---Setup the monitor with config
---@param config TwinchatMonitorConfig|nil
function M.setup(config)
  local monitor = M.get_monitor(config)
  monitor:start()
end

---Stop the monitor
function M.stop()
  if _monitor_instance then _monitor_instance:stop() end
end

---Check a specific chat
---@param bufnr number
function M.check_chat(bufnr)
  if _monitor_instance then _monitor_instance:check_chat(bufnr) end
end

---Reset threshold for a chat
---@param bufnr number
function M.reset_threshold(bufnr)
  if _monitor_instance then _monitor_instance:reset_threshold(bufnr) end
end

---Get context info for a chat
---@param bufnr number
---@return TwinchatThresholdInfo|nil
function M.get_context_info(bufnr)
  if _monitor_instance then return _monitor_instance:get_context_info(bufnr) end
  return nil
end

return M
