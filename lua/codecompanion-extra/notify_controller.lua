-- Notification controller for CodeCompanion Extra
-- Decides when to show OS notifications based on focus and config

local sys_notify = require("codecompanion-extra.utils.sys_notify")

local api = vim.api

local DEFAULT_CONFIG = {
  enabled = false,
  only_when_unfocused = true,
  notify_on = {
    completed = true,
    error = true,
    cancelled = false,
  },
  title = "CodeCompanion Extra",
  fallback = true,
}

---@class CCExtra.NotifyController
---@field config table
---@field is_focused boolean
---@field aug number|nil
local NotifyController = {}
NotifyController.__index = NotifyController

---@param config? table
---@return CCExtra.NotifyController
function NotifyController.new(config)
  local self = setmetatable({}, NotifyController)
  self.config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_CONFIG), config or {})
  self.is_focused = true
  self.aug = nil
  return self
end

function NotifyController:setup_focus_tracking()
  if self.aug then return end
  self.aug = api.nvim_create_augroup("CCExtraNotifyFocus", { clear = true })

  api.nvim_create_autocmd("FocusGained", {
    group = self.aug,
    callback = function()
      self.is_focused = true
    end,
  })

  api.nvim_create_autocmd("FocusLost", {
    group = self.aug,
    callback = function()
      self.is_focused = false
    end,
  })
end

---@param status "completed"|"error"|"cancelled"
---@param message string
function NotifyController:notify(status, message)
  if not self.config.enabled then return end
  if self.config.only_when_unfocused and self.is_focused then return end
  if not self.config.notify_on[status] then return end
  sys_notify.smart_notify(self.config.title, message, self.config.fallback)
end

---@param state_manager table
function NotifyController:attach_state(state_manager)
  if not state_manager then return end
  state_manager:on("request_completed", function(bufnr, parent)
    local status = parent.status or "completed"
    local label = parent.adapter or parent.model or ("Chat#" .. tostring(bufnr))
    local message = string.format("%s: %s", label, status)
    self:notify(status, message)
  end)
end

local M = {}
local _instance = nil

---@param config? table
function M.setup(config)
  if _instance then return end
  _instance = NotifyController.new(config)
  _instance:setup_focus_tracking()
end

---@return CCExtra.NotifyController|nil
function M.instance()
  return _instance
end

return M
