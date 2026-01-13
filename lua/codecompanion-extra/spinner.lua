--[[
===============================================================================
    File:       codecompanion-extra/spinner.lua
    Author:     Bassam Data (https://github.com/bassamsdata)
-------------------------------------------------------------------------------
    Description:
      Visual feedback spinner for CodeCompanion requests and tool execution.
      Shows real-time status with customizable animations.

    FEATURES:
      • 15+ built-in spinner presets
      • Shows adapter, provider, and model information
      • Tool execution tracking
      • Customizable display and timing
-------------------------------------------------------------------------------
    Attribution:
      If you use or distribute this code, please credit:
      Bassam Data (https://github.com/bassamsdata)
===============================================================================
--]]


---TODO:
---1. enhance bug when the timer turns into minutes, the seconds, lose the highilights.
---2. add final timer when complete/cancel/error meaning this is total time of full request.
---3. move to set_ectmark since it has eol_right_align position for notifications.
---4. we need to detect when the chat is cleared completly to stop the spoinner. in case something goes wrrong with the chat.
---5. we need also to manually allow to stop it.

-- ============================================================================
-- CONSTANTS AND CONFIGURATION DEFAULTS
-- ============================================================================
local CONSTANTS = {
  MAX_WIDTH_PERCENT = 0.35,
  WINDOW_BLEND = 100,
  ZINDEX = 1000,
  RIGHT_OFFSET = 1,

  COMPLETION_DISPLAY_TIME = 3000,
  SPINNER_INTERVAL = 80,

  STATUS = {
    SENDING = "Sending",
    STREAMING = "Streaming",
    TOOL_RUNNING = "Executing Tool",
    PROCESSING = "Processing",
    COMPLETED = "Completed ",
    ERROR = " Error ",
    CANCELLED = "Cancelled ",
  },

  -- stylua: ignore start 
  SPINNER_FRAMES = {
    corner        = { "◜", "◝", "◞", "◟" },
    braille       = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    building      = { "⣼", "⣹", "⢻", "⠿", "⡟", "⣏", "⣧", "⣶" },
    simple_pounce = { ".  ", ".. ", "...", " ..", "  .", "   " },
    star          = { "✶", "✸", "✹", "✺", "✹", "✷" },
    binary        = { "010010", "001100", "100101", "111010", "111101", "010111", "101011", "111000", "110011", "110101" },
    line          = { "-", "\\", "|", "/" },
    dots_bounce   = { "⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈" },
    arrow         = { "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" },
    scramble      = { "abc", "ghi", "def", "jkl", "pqr", "mno", "stu", "yz!", "vwx" },
    box           = { "◰", "◳", "◲", "◱" },
    pulse         = { "○", "◔", "◑", "◕", "●", "◕", "◑", "◔" },
    pipe          = { "┤", "┘", "┴", "└", "├", "┌", "┬", "┐" },
    snake         = { "⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈" },
    moon          = { "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" },
    minimal       = { ".", "..", "..." },
    bars          = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃", "▂" },
    bounce        = {
      "⠁", "⠁", "⠉", "⠙", "⠚", "⠒", "⠂", "⠂", "⠒", "⠲", "⠴", "⠤", "⠄", "⠄", "⠤", "⠠",
      "⠠", "⠤", "⠦", "⠖", "⠒", "⠐", "⠐", "⠒", "⠓", "⠋", "⠉", "⠈", "⠈",
    },
  },
  -- stylua: ignore end

  HIGHLIGHT_LINKS = {
    SpinnerActive = "DiagnosticInfo",
    SpinnerDim = "Comment",
    SpinnerSuccess = "DiagnosticOk",
    SpinnerError = "DiagnosticError",
    SpinnerInfo = "Special",
    SpinnerLabel = "Comment",
    SpinnerProvider = "DiagnosticHint",
  },

  DEBUG_ENABLED = true,
  DEBUG_LOG_FILE = vim.fn.stdpath("cache") .. "/spinner_debug.log",
}

local DEFAULT_CONFIG = {
  spinner = {
    frames = CONSTANTS.SPINNER_FRAMES.binary,
    interval = CONSTANTS.SPINNER_INTERVAL,
  },
  display = {
    show_model = true,
    show_tool_name = false,
    show_tool_status = true,
    show_timestamps = true,
    completion_display_time = CONSTANTS.COMPLETION_DISPLAY_TIME,
  },
  window = {
    max_width_percent = CONSTANTS.MAX_WIDTH_PERCENT,
    blend = CONSTANTS.WINDOW_BLEND,
    right_offset = CONSTANTS.RIGHT_OFFSET,
    enabled = true,
  },
}

-- ============================================================================
-- SPINNER CLASS
-- ============================================================================
-- State machine states: idle, sending, streaming, tool_running, completed, error, cancelled
--
-- Valid transitions:
--   idle -> sending (on request_started)
--   sending -> streaming (on request_streaming)
--   streaming -> completed/error/cancelled (on request_finished)
--   streaming -> tool_running (on tool_started)
--   tool_running -> streaming (on tool_finished, if request still active)
--   tool_running -> completed (on tool_finished, if request done)
--   completed/error/cancelled -> idle (after display timeout)
--   any -> sending (on new request_started - resets everything)
-- ============================================================================

---@class Spinner
---@field config table
---@field ns_id integer
---@field state table
---@field _setup_highlights function
---@field _debug_log function
local Spinner = {}

Spinner.__index = Spinner

---Create a new Spinner instance
---@param config? table
---@return Spinner
function Spinner.new(config)
  local self = setmetatable({}, Spinner)
  self.config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_CONFIG), config or {})
  self:_validate_spinner_frames()
  self.ns_id = vim.api.nvim_create_namespace("spinner_info")

  self.state = {
    status = "idle",

    request_id = nil,
    request_started = nil,

    adapter = nil,
    model = nil,
    provider = nil,
    interaction_type = nil,

    current_tool = nil,
    active_tools = {},

    win = nil,
    buf = nil,
    frame = 1,

    animation_timer = nil,
    completion_timer = nil,
  }

  return self
end

---Validate and normalize spinner frames configuration
---@private
function Spinner:_validate_spinner_frames()
  local frames = self.config.spinner.frames

  -- Allow string preset names
  if type(frames) == "string" then
    local preset = CONSTANTS.SPINNER_FRAMES[frames]
    if preset then
      self.config.spinner.frames = preset
      return
    else
      vim.notify(string.format("Spinner: Unknown preset '%s', using default", frames), vim.log.levels.WARN)
      self.config.spinner.frames = CONSTANTS.SPINNER_FRAMES.braille
      return
    end
  end

  -- Allow function that returns frames
  if type(frames) == "function" then
    frames = frames()
    self.config.spinner.frames = frames
  end

  -- Validate frames is a non-empty table
  if type(frames) ~= "table" or vim.tbl_isempty(frames) then
    vim.notify("Spinner: Invalid frames config, using default", vim.log.levels.WARN)
    self.config.spinner.frames = CONSTANTS.SPINNER_FRAMES.braille
  end
end

-- ============================================================================
-- DEBUG LOGGING
-- ============================================================================

---Log debug message to file
---@param message string
---@private
function Spinner:_debug_log(message)
  if not CONSTANTS.DEBUG_ENABLED then return end

  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local log_line = string.format("[%s] %s\n", timestamp, message)

  local file = io.open(CONSTANTS.DEBUG_LOG_FILE, "a")
  if file then
    file:write(log_line)
    file:close()
  end
end

---Log current state for debugging
---@param context string Context/location of the log
---@private
function Spinner:_debug_state(context)
  if not CONSTANTS.DEBUG_ENABLED then return end

  local state_summary = string.format(
    "State[%s]: status=%s, request_id=%s, current_tool=%s, active_tools=%d",
    context,
    self.state.status,
    tostring(self.state.request_id),
    tostring(self.state.current_tool),
    vim.tbl_count(self.state.active_tools)
  )
  self:_debug_log(state_summary)
end

-- ============================================================================
-- HIGHLIGHT SETUP
-- ============================================================================

---Setup highlight groups
---@private
function Spinner:_setup_highlights()
  for group_name, link_to in pairs(CONSTANTS.HIGHLIGHT_LINKS) do
    vim.api.nvim_set_hl(0, group_name, { link = link_to, default = true })
  end
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

---Format elapsed time
---@param seconds number
---@return string
---@private
function Spinner:_format_time(seconds)
  if seconds < 60 then return string.format("%.1fs", seconds) end
  local minutes = math.floor(seconds / 60)
  local secs = seconds % 60
  return string.format("%dm %.1fs", minutes, secs)
end

---Get elapsed time since request started
---@return string
---@private
function Spinner:_get_elapsed_time()
  if not self.state.request_started then return "0.0s" end
  local elapsed = (vim.uv.now() - self.state.request_started) / 1000
  return self:_format_time(elapsed)
end

---Format adapter info for display
---@return string
---@private
function Spinner:_format_adapter_info()
  local parts = {}
  if self.state.adapter then table.insert(parts, self.state.adapter) end
  if self.state.provider then table.insert(parts, string.format("(%s)", self.state.provider)) end
  if self.state.model and self.state.model ~= self.state.adapter then table.insert(parts, self.state.model) end
  return table.concat(parts, " - ")
end

-- ============================================================================
-- TIMER MANAGEMENT
-- ============================================================================

---Cancel completion timer
---@private
function Spinner:_cancel_completion_timer()
  if self.state.completion_timer then
    if not self.state.completion_timer:is_closing() then
      self.state.completion_timer:stop()
      self.state.completion_timer:close()
    end
    self.state.completion_timer = nil
  end
end

---Cancel animation timer
---@private
function Spinner:_cancel_animation_timer()
  if self.state.animation_timer then
    if not self.state.animation_timer:is_closing() then
      self.state.animation_timer:stop()
      self.state.animation_timer:close()
    end
    self.state.animation_timer = nil
  end
end

---Cancel all timers
---@private
function Spinner:_cancel_all_timers()
  self:_cancel_completion_timer()
  self:_cancel_animation_timer()
end

-- ============================================================================
-- WINDOW MANAGEMENT
-- ============================================================================

---Close the spinner window
---@private
function Spinner:_close_window()
  if self.state.win and vim.api.nvim_win_is_valid(self.state.win) then vim.api.nvim_win_close(self.state.win, true) end
  self.state.win = nil
  self.state.buf = nil
end

---Check if window is valid
---@return boolean
---@private
function Spinner:_is_window_valid()
  return self.state.win
    and self.state.buf
    and vim.api.nvim_win_is_valid(self.state.win)
    and vim.api.nvim_buf_is_valid(self.state.buf)
end

-- ============================================================================
-- DISPLAY BUILDING
-- ============================================================================

---Build display content lines
---@return string[]
---@private
function Spinner:_build_display_content()
  local lines = {}
  local spinner_char = self.config.spinner.frames[self.state.frame]

  -- Line 1: Adapter/Model/Provider info (ALWAYS show if available)
  local adapter_info = self:_format_adapter_info()
  if adapter_info ~= "" and self.config.display.show_model then table.insert(lines, adapter_info) end

  -- Line 2: Status with spinner or completion icon
  local status_text = ""

  if self.state.status == "sending" then
    status_text = CONSTANTS.STATUS.SENDING .. " " .. spinner_char
  elseif self.state.status == "streaming" then
    status_text = CONSTANTS.STATUS.STREAMING .. " " .. spinner_char
  elseif self.state.status == "tool_running" then
    -- Show tool name inline with status if configured
    if self.config.display.show_tool_status then
      status_text = CONSTANTS.STATUS.TOOL_RUNNING
      if self.config.display.show_tool_name and self.state.current_tool then
        status_text = status_text .. ": " .. self.state.current_tool
      end
      status_text = status_text .. " " .. spinner_char
    else
      status_text = CONSTANTS.STATUS.PROCESSING .. " " .. spinner_char
    end
  elseif self.state.status == "completed" then
    status_text = CONSTANTS.STATUS.COMPLETED
  elseif self.state.status == "error" then
    status_text = CONSTANTS.STATUS.ERROR
  elseif self.state.status == "cancelled" then
    status_text = CONSTANTS.STATUS.CANCELLED
  else
    status_text = CONSTANTS.STATUS.PROCESSING .. " " .. spinner_char
  end

  -- Add timestamp
  if self.config.display.show_timestamps then status_text = status_text .. " " .. self:_get_elapsed_time() end

  table.insert(lines, status_text)

  return lines
end

---Calculate content width
---@param lines string[]
---@return number
---@private
function Spinner:_calculate_content_width(lines)
  local max_width = 0
  for _, line in ipairs(lines) do
    local width = vim.fn.strdisplaywidth(line)
    if width > max_width then max_width = width end
  end
  return max_width
end

-- ============================================================================
-- WINDOW CREATION AND UPDATE
-- ============================================================================

---Create the floating window
---@private
function Spinner:_create_window()
  if not self.config.window.enabled then return end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

  local content_lines = self:_build_display_content()
  local height = #content_lines
  local content_width = self:_calculate_content_width(content_lines)
  local max_allowed_width = math.floor(vim.o.columns * self.config.window.max_width_percent)
  local width = math.min(content_width, max_allowed_width)

  local row = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0) - height
  local col = vim.o.columns - width - self.config.window.right_offset

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    border = "none",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    focusable = false,
    zindex = CONSTANTS.ZINDEX,
  })
  vim.api.nvim_set_option_value("winblend", self.config.window.blend, { win = win })

  self.state.buf = buf
  self.state.win = win

  self:_debug_log(string.format("Created window: width=%d, height=%d", width, height))
end

---Update the display content and window
---@private
function Spinner:_update_display()
  if not self:_is_window_valid() then return end

  local lines = self:_build_display_content()

  vim.api.nvim_buf_set_lines(self.state.buf, 0, -1, false, lines)

  -- Update window size
  local content_width = self:_calculate_content_width(lines)
  local max_allowed_width = math.floor(vim.o.columns * self.config.window.max_width_percent)
  local width = math.min(content_width, max_allowed_width)
  local height = #lines

  local row = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0) - height
  local col = vim.o.columns - width - self.config.window.right_offset

  vim.api.nvim_win_set_config(self.state.win, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
  })

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(self.state.buf, self.ns_id, 0, -1)

  for line_idx, line in ipairs(lines) do
    local hl_group = "SpinnerActive"

    if line_idx == 1 and #lines > 1 then
      -- First line is adapter info
      hl_group = "SpinnerInfo"
    elseif self.state.status == "completed" then
      hl_group = "SpinnerSuccess"
    elseif self.state.status == "error" then
      hl_group = "SpinnerError"
    end

    vim.api.nvim_buf_set_extmark(self.state.buf, self.ns_id, line_idx - 1, 0, {
      end_col = #line,
      hl_group = hl_group,
      priority = vim.highlight.priorities.user + 1,
    })

    -- Highlight provider in parentheses with different color
    local provider_pattern = "%([^)]+%)"
    local provider_start, provider_end = string.find(line, provider_pattern)
    if provider_start then
      vim.api.nvim_buf_set_extmark(self.state.buf, self.ns_id, line_idx - 1, provider_start - 1, {
        end_col = provider_end,
        hl_group = "SpinnerProvider",
        priority = vim.highlight.priorities.user + 3,
      })
    end

    -- Highlight time if present
    local time_match = string.match(line, "[0-9.]+[smh]+")
    if time_match then
      local time_start = string.find(line, "[0-9.]+[smh]+")
      local time_end = time_start + #time_match - 1
      vim.api.nvim_buf_set_extmark(self.state.buf, self.ns_id, line_idx - 1, time_start - 1, {
        end_col = time_end,
        hl_group = "SpinnerLabel",
        priority = vim.highlight.priorities.user + 2,
      })
    end
  end
end

-- ============================================================================
-- ANIMATION
-- ============================================================================

---Start the spinner animation
---@private
function Spinner:_start_animation()
  if self.state.animation_timer then
    return -- Already running
  end

  self.state.animation_timer = vim.uv.new_timer()
  self.state.animation_timer:start(
    0,
    self.config.spinner.interval,
    vim.schedule_wrap(function()
      if self.state.status == "idle" or self.state.status == "completed" or self.state.status == "error" then
        self:_stop_animation()
        return
      end
      self.state.frame = (self.state.frame % #self.config.spinner.frames) + 1
      self:_update_display()
    end)
  )
end

---Stop the spinner animation
---@private
function Spinner:_stop_animation()
  self:_cancel_animation_timer()
end

-- ============================================================================
-- STATE TRANSITIONS
-- ============================================================================

---Reset to idle state
---@private
function Spinner:_reset_to_idle()
  self:_debug_log("Resetting to idle")
  self:_cancel_all_timers()
  self:_close_window()

  self.state.status = "idle"
  self.state.request_id = nil
  self.state.request_started = nil
  self.state.adapter = nil
  self.state.model = nil
  self.state.provider = nil
  self.state.interaction_type = nil
  self.state.current_tool = nil
  self.state.active_tools = {}
  self.state.frame = 1
end

---Ensure UI is visible and animating
---@private
function Spinner:_ensure_ui_visible()
  if not self:_is_window_valid() then self:_create_window() end
  self:_update_display()
  if self.state.status ~= "idle" and self.state.status ~= "completed" and self.state.status ~= "error" then
    self:_start_animation()
  end
end

---Schedule cleanup after completion
---@private
function Spinner:_schedule_cleanup()
  self:_cancel_completion_timer()

  local display_time = self.config.display.completion_display_time

  self.state.completion_timer = vim.uv.new_timer()
  self.state.completion_timer:start(
    display_time,
    0,
    vim.schedule_wrap(function()
      -- Only reset if we're still in a completion state
      if self.state.status == "completed" or self.state.status == "error" or self.state.status == "cancelled" then
        self:_reset_to_idle()
      end
    end)
  )
end

---Show completion status
---@param final_status string "completed"|"error"|"cancelled"
---@private
function Spinner:_show_completion(final_status)
  self:_debug_log(string.format("Showing completion: %s", final_status))

  self.state.status = final_status
  self:_stop_animation()
  self:_update_display()
  self:_schedule_cleanup()

  self:_debug_state("After completion")
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

---Handle RequestStarted event
---@param opts table Event data
function Spinner:handle_request_started(opts)
  self:_debug_log("Request started: " .. vim.inspect(opts))

  -- Cancel any pending cleanup from previous request
  self:_cancel_all_timers()
  self:_close_window()

  -- Set up new request state
  self.state.status = "sending"
  self.state.request_id = opts and opts.id or nil
  self.state.request_started = vim.uv.now()
  self.state.frame = 1
  self.state.current_tool = nil
  self.state.active_tools = {}

  -- Extract adapter info
  if opts and opts.adapter then
    self.state.adapter = opts.adapter.formatted_name or opts.adapter.name or nil
    self.state.model = opts.adapter.model or nil
    self.state.provider = opts.adapter.provider or nil
  end

  if opts and opts.interaction then self.state.interaction_type = opts.interaction end

  self:_debug_state("After request_started")
  self:_ensure_ui_visible()
end

---Handle RequestStreaming event
---@param opts table Event data
function Spinner:handle_request_streaming(opts)
  self:_debug_log("Request streaming")

  -- Only transition if we are in a valid pre-streaming state
  if self.state.status == "sending" or self.state.status == "idle" then self.state.status = "streaming" end

  -- Update provider if it becomes available during streaming
  if opts and opts.adapter and opts.adapter.provider and not self.state.provider then
    self.state.provider = opts.adapter.provider
  end

  -- Preserve existing request context, just update status
  self:_debug_state("After request_streaming")
  self:_ensure_ui_visible()
end

---Handle RequestFinished event
---@param opts table Event data
function Spinner:handle_request_finished(opts)
  local finish_status = opts and opts.status or "unknown"
  local finish_request_id = opts and opts.id

  self:_debug_log(
    string.format(
      "Request finished: status=%s, request_id=%s, current_id=%s",
      finish_status,
      tostring(finish_request_id),
      tostring(self.state.request_id)
    )
  )

  -- If tools are still running, do not show completion yet
  -- The tool_finished handler will trigger completion when all tools are done
  if self.state.current_tool or not vim.tbl_isempty(self.state.active_tools) then
    self:_debug_log("Tools still active, deferring completion")
    return
  end

  -- Determine final status
  local final_status
  if finish_status == "success" then
    final_status = "completed"
  elseif finish_status == "error" then
    final_status = "error"
  else
    final_status = "cancelled"
  end

  self:_show_completion(final_status)
  self:_debug_state("After request_finished")
end

---Handle ToolStarted event
---@param opts table Event data
function Spinner:handle_tool_started(opts)
  local tool_name = opts and opts.name or "unknown"
  self:_debug_log(string.format("Tool started: %s", tool_name))

  -- Track active tool
  self.state.active_tools[tool_name] = true
  self.state.current_tool = tool_name
  self.state.status = "tool_running"

  self:_debug_state("After tool_started")
  self:_ensure_ui_visible()
end

---Handle ToolFinished event
---@param opts table Event data
function Spinner:handle_tool_finished(opts)
  local tool_name = opts and opts.name or "unknown"
  self:_debug_log(string.format("Tool finished: %s", tool_name))

  -- Remove from active tools
  self.state.active_tools[tool_name] = nil

  -- Update current_tool to another active tool, or nil if none
  local remaining_tools = vim.tbl_keys(self.state.active_tools)
  if #remaining_tools > 0 then
    self.state.current_tool = remaining_tools[1]
    self.state.status = "tool_running"
  else
    self.state.current_tool = nil
    -- Check if the main request is still active
    if self.state.request_id and self.state.status ~= "completed" then
      self.state.status = "streaming"
    else
      -- No active tools and no active request - show completion
      self:_show_completion("completed")
    end
  end

  self:_debug_state("After tool_finished")
  self:_ensure_ui_visible()
end

-- ============================================================================
-- MODULE LEVEL - SINGLETON INSTANCE AND PUBLIC API
-- ============================================================================

local M = {}
local _spinner_instance = nil

---Setup the spinner with configuration
---@param user_config? table Configuration to merge with defaults
function M.setup(user_config)
  if _spinner_instance then
    vim.notify("Spinner already initialized, recreating with new config", vim.log.levels.INFO)
  end

  -- Always create new instance (simpler, no need for backward compat)
  _spinner_instance = Spinner.new(user_config)
  _spinner_instance:_setup_highlights()

  -- Setup highlight refresh on colorscheme change
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("SpinnerHighlights", { clear = true }),
    callback = function()
      if _spinner_instance then _spinner_instance:_setup_highlights() end
    end,
  })

  -- Setup event handlers
  local group = vim.api.nvim_create_augroup("CodeCompanionSpinner", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    pattern = {
      "CodeCompanionRequestStarted",
      "CodeCompanionRequestFinished",
      "CodeCompanionRequestStreaming",
    },
    group = group,
    callback = function(args)
      if not _spinner_instance then return end
      if args.match == "CodeCompanionRequestStarted" then
        _spinner_instance:handle_request_started(args.data)
      elseif args.match == "CodeCompanionRequestStreaming" then
        _spinner_instance:handle_request_streaming(args.data)
      elseif args.match == "CodeCompanionRequestFinished" then
        _spinner_instance:handle_request_finished(args.data)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = {
      "CodeCompanionToolStarted",
      "CodeCompanionToolFinished",
    },
    group = group,
    callback = function(args)
      if not _spinner_instance then return end
      if args.match == "CodeCompanionToolStarted" then
        _spinner_instance:handle_tool_started(args.data)
      elseif args.match == "CodeCompanionToolFinished" then
        _spinner_instance:handle_tool_finished(args.data)
      end
    end,
  })

  if _spinner_instance then
    _spinner_instance:_debug_log("Spinner configured: " .. vim.inspect(_spinner_instance.config))
  end
end

---Stop the spinner (manual control)
function M.stop()
  if _spinner_instance then _spinner_instance:_reset_to_idle() end
end

---Get current state (for debugging)
---@return table
function M.get_state()
  if _spinner_instance then return vim.deepcopy(_spinner_instance.state) end
  return {}
end

return M
