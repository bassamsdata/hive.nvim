-- Status display utilities for subagent tools
-- Renders virtual line notifications in parent chat buffer

local api = vim.api

local M = {}

local _scrolled_namespaces = {}

-- ============================================================================
-- Highlight Detection
-- ============================================================================

---Detect appropriate highlight group for a status line
---@param line string The line text to analyze
---@param icons? table Optional icon definitions for matching
---@return string highlight_group The highlight group name
function M.detect_highlight(line, icons)
  local utils = require("codecompanion-extra.tools.subagent.utils")
  local HIGHLIGHTS = utils.HIGHLIGHTS
  icons = icons or utils.STATUS_ICONS

  if line:match("^───") then
    return HIGHLIGHTS.header
  elseif line:match("Running") or line:match("Working") or line:match("Starting") then
    return HIGHLIGHTS.running
  elseif line:match("Done") or line:match("Complete") or line:match(icons.completed or "✓") then
    return HIGHLIGHTS.success
  elseif line:match("Failed") or line:match("Cancelled") or line:match(icons.failed or "✗") then
    return HIGHLIGHTS.error
  elseif line:match(icons.timer or "") then
    return HIGHLIGHTS.info
  end

  return HIGHLIGHTS.default
end

---Scroll window to end if conditions are met
---@param bufnr number
---@param ns_id number
---@param line_count number
function M._scroll_to_end(bufnr, ns_id, line_count)
  local config = require("codecompanion-extra.config").config.tools.status or {}
  if config.scroll_to_show == false or _scrolled_namespaces[ns_id] then return end

  local ok, ui_utils = pcall(require, "codecompanion.utils.ui")
  local window = ok and ui_utils.buf_get_win(bufnr)

  if window and api.nvim_win_is_valid(window) then
    local cursor = api.nvim_win_get_cursor(window)
    if api.nvim_get_current_win() ~= window or (line_count - cursor[1]) <= (config.scroll_cursor_distance or 5) then
      _scrolled_namespaces[ns_id] = true
      api.nvim_win_call(window, function()
        pcall(api.nvim_win_set_cursor, 0, { line_count, 0 })
        vim.cmd("normal! zz")
      end)
    end
  end
end

-- ============================================================================
-- Virtual Line Rendering
-- ============================================================================

---Render status as virtual lines at end of buffer
---@param args { bufnr: number, ns_id: number, text: string, icons?: table }
function M.render(args)
  local bufnr = args.bufnr
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end

  local lines = vim.split(args.text, "\n")
  local virt_lines = { { { "", "Normal" } } }

  for _, line in ipairs(lines) do
    local hl = M.detect_highlight(line, args.icons)
    table.insert(virt_lines, { { line, hl } })
  end

  table.insert(virt_lines, { { "", "Normal" } })

  pcall(api.nvim_buf_clear_namespace, bufnr, args.ns_id, 0, -1)

  local buf_lines = api.nvim_buf_line_count(bufnr)
  local target_line = math.max(0, buf_lines - 1)

  pcall(api.nvim_buf_set_extmark, bufnr, args.ns_id, target_line, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
    priority = 100,
  })

  M._scroll_to_end(bufnr, args.ns_id, buf_lines)
end

---Clear virtual lines from buffer
---@param bufnr number
---@param ns_id number
function M.clear(bufnr, ns_id)
  _scrolled_namespaces[ns_id] = nil
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end
  vim.schedule(function()
    if api.nvim_buf_is_valid(bufnr) then pcall(api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1) end
  end)
end

---Clear status after a delay
---@param args { bufnr: number, ns_id: number, delay_ms?: number }
function M.clear_after_delay(args)
  local delay = args.delay_ms or 500
  vim.defer_fn(function()
    M.clear(args.bufnr, args.ns_id)
  end, delay)
end

return M
