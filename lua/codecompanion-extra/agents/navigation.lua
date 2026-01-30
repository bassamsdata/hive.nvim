-- Navigation between parent/child agent chats
-- Provides keymaps: ]s (next subagent), [s (prev subagent), [p (parent), gs (list)
-- Provides winbar indicator showing current agent hierarchy context

local M = {}

---@type table
M.keymaps = {}

---@type table<number, { winbar_set: boolean, autocmd_id?: number }>
M._winbar_state = {}

local fmt = string.format

local WINBAR_NS = vim.api.nvim_create_namespace("codecompanion_agent_winbar")

---Build winbar string for a chat buffer
---@param bufnr number
---@return string|nil
local function build_winbar(bufnr)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")
  local agents = require("codecompanion-extra.agents")

  local session = hierarchy.get_session(bufnr)
  local agent_name = agents.active(bufnr)

  if not session and not agent_name then return nil end

  local parts = {}

  if session then
    if session.parent_bufnr then
      local parent_session = hierarchy.get_session(session.parent_bufnr)
      local parent_name = parent_session and parent_session.agent_name or "Parent"
      table.insert(parts, fmt("%%#Comment#↑ %s%%*", parent_name))
    end

    local status_hl = ({
      running = "WarningMsg",
      completed = "DiagnosticOk",
      failed = "ErrorMsg",
      cancelled = "Comment",
    })[session.status] or "Normal"

    local type_label = session.agent_type == "subagent" and "Subagent" or "Agent"
    table.insert(parts, fmt("%%#%s#%s: %s%%*", status_hl, type_label, session.agent_name))

    local children = hierarchy.get_children(bufnr)
    if #children > 0 then table.insert(parts, fmt("%%#Comment#↓ %d subagents%%*", #children)) end
  elseif agent_name then
    table.insert(parts, fmt("Agent: %s", agent_name))
  end

  if #parts == 0 then return nil end

  return " " .. table.concat(parts, "  │  ")
end

---Update winbar for a specific window/buffer
---@param bufnr number
---@param winid? number
local function update_winbar(bufnr, winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local winbar = build_winbar(bufnr)

  if winid and vim.api.nvim_win_is_valid(winid) then
    if winbar then
      vim.wo[winid].winbar = winbar
    else
      vim.wo[winid].winbar = ""
    end
  else
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      if vim.api.nvim_win_is_valid(win) then
        if winbar then
          vim.wo[win].winbar = winbar
        else
          vim.wo[win].winbar = ""
        end
      end
    end
  end
end

---Setup winbar tracking for a chat buffer
---@param bufnr number
---@param force? boolean Force re-setup even if already set up
function M.setup_winbar(bufnr, force)
  if M._winbar_state[bufnr] and not force then
    -- Already set up, just refresh
    vim.schedule(function()
      update_winbar(bufnr)
    end)
    return
  end

  -- Clear existing state if forcing
  if force and M._winbar_state[bufnr] then
    if M._winbar_state[bufnr].autocmd_id then pcall(vim.api.nvim_del_autocmd, M._winbar_state[bufnr].autocmd_id) end
  end

  M._winbar_state[bufnr] = { winbar_set = true }

  vim.schedule(function()
    update_winbar(bufnr)
  end)

  local autocmd_id = vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    buffer = bufnr,
    callback = function()
      update_winbar(bufnr)
    end,
  })

  M._winbar_state[bufnr].autocmd_id = autocmd_id

  vim.api.nvim_create_autocmd("BufDelete", {
    buffer = bufnr,
    once = true,
    callback = function()
      M.clear_winbar(bufnr)
    end,
  })
end

---Clear winbar for a buffer
---@param bufnr number
function M.clear_winbar(bufnr)
  local state = M._winbar_state[bufnr]
  if not state then return end

  if state.autocmd_id then pcall(vim.api.nvim_del_autocmd, state.autocmd_id) end

  for _, win in ipairs(vim.fn.win_findbuf(bufnr) or {}) do
    if vim.api.nvim_win_is_valid(win) then vim.wo[win].winbar = "" end
  end

  M._winbar_state[bufnr] = nil
end

---Refresh winbar for a buffer (call after hierarchy changes)
---@param bufnr number
function M.refresh_winbar(bufnr)
  if M._winbar_state[bufnr] then vim.schedule(function()
    update_winbar(bufnr)
  end) end
end

---Setup navigation keymaps in CodeCompanion config
function M.setup()
  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local keymaps = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.keymaps
  if not keymaps then return end

  keymaps["next_subagent"] = {
    modes = { n = "]s" },
    index = 60,
    callback = function(chat)
      M.keymaps.next_subagent(chat)
    end,
    description = "[Nav] Next subagent",
  }

  keymaps["prev_subagent"] = {
    modes = { n = "[s" },
    index = 61,
    callback = function(chat)
      M.keymaps.prev_subagent(chat)
    end,
    description = "[Nav] Previous subagent",
  }

  keymaps["parent_agent"] = {
    modes = { n = "[p" },
    index = 62,
    callback = function(chat)
      M.keymaps.parent_agent(chat)
    end,
    description = "[Nav] Parent agent",
  }

  keymaps["list_subagents"] = {
    modes = { n = "gs" },
    index = 63,
    callback = function(chat)
      M.keymaps.list_subagents(chat)
    end,
    description = "[Nav] List subagents",
  }
end

---Navigate from one chat buffer to another
---@param from_bufnr number Current buffer
---@param to_bufnr number Target buffer
local function navigate_to(from_bufnr, to_bufnr)
  local codecompanion = require("codecompanion")
  local hierarchy = require("codecompanion-extra.agents.hierarchy")

  local from_chat = codecompanion.buf_get_chat(from_bufnr)
  local to_chat = codecompanion.buf_get_chat(to_bufnr)

  if not from_chat or not to_chat then
    vim.notify("Cannot navigate: chat not found", vim.log.levels.WARN)
    return false
  end

  hierarchy.show(to_bufnr)

  local window_opts = from_chat.ui.window_opts or { default = true }
  from_chat.ui:hide()
  to_chat.ui:open({ window_opts = window_opts })

  M.setup_winbar(to_bufnr)
  M.refresh_winbar(from_bufnr)
  M.refresh_winbar(to_bufnr)

  return true
end

---Find current index in a list of buffers
---@param bufnr number
---@param buffers number[]
---@return number|nil
local function find_index(bufnr, buffers)
  for i, b in ipairs(buffers) do
    if b == bufnr then return i end
  end
  return nil
end

---Navigate to next subagent
---If current chat has children, go to first child
---If current chat is a child, go to next sibling
---@param chat table CodeCompanion chat instance
function M.keymaps.next_subagent(chat)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")

  local children = hierarchy.get_children(chat.bufnr)
  if #children > 0 then
    local target = children[1]
    navigate_to(chat.bufnr, target)
    return
  end

  local parent_bufnr = hierarchy.get_parent(chat.bufnr)
  if parent_bufnr then
    local siblings = hierarchy.get_children(parent_bufnr)
    local current_idx = find_index(chat.bufnr, siblings)

    if current_idx and siblings[current_idx + 1] then
      local target = siblings[current_idx + 1]
      navigate_to(chat.bufnr, target)
      return
    end
  end

  vim.notify("No subagents to navigate to", vim.log.levels.INFO)
end

---Navigate to previous subagent
---If current chat is a child, go to previous sibling or parent
---@param chat table CodeCompanion chat instance
function M.keymaps.prev_subagent(chat)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")

  local parent_bufnr = hierarchy.get_parent(chat.bufnr)
  if not parent_bufnr then
    vim.notify("No previous subagent", vim.log.levels.INFO)
    return
  end

  local siblings = hierarchy.get_children(parent_bufnr)
  local current_idx = find_index(chat.bufnr, siblings)

  if current_idx and current_idx > 1 then
    navigate_to(chat.bufnr, siblings[current_idx - 1])
    return
  end

  navigate_to(chat.bufnr, parent_bufnr)
end

---Navigate to parent agent
---@param chat table CodeCompanion chat instance
function M.keymaps.parent_agent(chat)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")

  local parent_bufnr = hierarchy.get_parent(chat.bufnr)
  if not parent_bufnr then
    vim.notify("No parent agent", vim.log.levels.INFO)
    return
  end

  navigate_to(chat.bufnr, parent_bufnr)
end

---List all subagents and allow selection
---@param chat table CodeCompanion chat instance
function M.keymaps.list_subagents(chat)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")

  local children = hierarchy.get_children(chat.bufnr)

  local parent_bufnr = hierarchy.get_parent(chat.bufnr)
  if parent_bufnr then
    local siblings = hierarchy.get_children(parent_bufnr)
    if #siblings > 0 then children = siblings end
  end

  if #children == 0 then
    vim.notify("No subagents available", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, child_bufnr in ipairs(children) do
    local session = hierarchy.get_session(child_bufnr)
    if session then
      local status_icon = ({
        pending = "○",
        running = "◐",
        completed = "✓",
        failed = "✗",
        cancelled = "⊘",
      })[session.status] or "?"

      local hidden_tag = session.hidden and " (hidden)" or ""

      local summary = hierarchy.get_tool_summary(child_bufnr)
      local elapsed = hierarchy.get_elapsed_ms(child_bufnr)
      local duration = hierarchy.format_duration(elapsed)

      local tool_info = ""
      if summary.total > 0 then tool_info = fmt(" [%d tools]", summary.total) end

      local time_info = ""
      if session.status == "running" then
        time_info = fmt(" (%s...)", duration)
      elseif session.status == "completed" or session.status == "failed" then
        time_info = fmt(" (%s)", duration)
      end

      table.insert(items, {
        bufnr = child_bufnr,
        display = fmt(
          "%s %s: %s%s%s%s",
          status_icon,
          session.agent_name,
          session.description,
          tool_info,
          time_info,
          hidden_tag
        ),
        session = session,
      })
    end
  end

  if #items == 0 then
    vim.notify("No subagents available", vim.log.levels.INFO)
    return
  end

  vim.ui.select(items, {
    prompt = "Select Subagent:",
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if choice then navigate_to(chat.bufnr, choice.bufnr) end
  end)
end

---Get navigation status string for display
---@param bufnr number
---@return string|nil
function M.get_status(bufnr)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")

  local session = hierarchy.get_session(bufnr)
  if not session then return nil end

  local parts = {}

  if session.parent_bufnr then
    local parent = hierarchy.get_session(session.parent_bufnr)
    if parent then table.insert(parts, fmt("Parent: %s", parent.agent_name)) end
  end

  local children = hierarchy.get_children(bufnr)
  if #children > 0 then
    local active = hierarchy.count_active_children(bufnr)
    local completed = #children - active
    table.insert(parts, fmt("Subagents: %d active, %d done", active, completed))
  end

  if session.status == "running" then
    local elapsed = hierarchy.get_elapsed_ms(bufnr)
    local duration = hierarchy.format_duration(elapsed)
    table.insert(parts, fmt("Running: %s", duration))
  elseif session.duration_ms then
    local duration = hierarchy.format_duration(session.duration_ms)
    table.insert(parts, fmt("Completed: %s", duration))
  end

  if #parts == 0 then return nil end

  return table.concat(parts, " | ")
end

---Get detailed info for a session (for display in list)
---@param bufnr number
---@return table|nil
function M.get_session_info(bufnr)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")

  local session = hierarchy.get_session(bufnr)
  if not session then return nil end

  local summary = hierarchy.get_tool_summary(bufnr)
  local elapsed = hierarchy.get_elapsed_ms(bufnr)

  return {
    bufnr = bufnr,
    agent_name = session.agent_name,
    description = session.description,
    status = session.status,
    tool_count = summary.total,
    tools_completed = summary.completed,
    tools_failed = summary.failed,
    current_tool = summary.current,
    elapsed_ms = elapsed,
    duration_str = hierarchy.format_duration(elapsed),
    hidden = session.hidden,
  }
end

---Navigate to next subagent (standalone function for commands)
function M.next_subagent()
  local ok, chat_module = pcall(require, "codecompanion.interactions.chat")
  if not ok then
    vim.notify("CodeCompanion not loaded", vim.log.levels.ERROR)
    return
  end

  local chat = chat_module.buf_get_chat(0)
  if not chat then
    vim.notify("No active chat buffer", vim.log.levels.WARN)
    return
  end

  M.keymaps.next_subagent(chat)
end

---Navigate to previous subagent (standalone function for commands)
function M.prev_subagent()
  local ok, chat_module = pcall(require, "codecompanion.interactions.chat")
  if not ok then
    vim.notify("CodeCompanion not loaded", vim.log.levels.ERROR)
    return
  end

  local chat = chat_module.buf_get_chat(0)
  if not chat then
    vim.notify("No active chat buffer", vim.log.levels.WARN)
    return
  end

  M.keymaps.prev_subagent(chat)
end

---Navigate to parent agent (standalone function for commands)
function M.parent()
  local ok, chat_module = pcall(require, "codecompanion.interactions.chat")
  if not ok then
    vim.notify("CodeCompanion not loaded", vim.log.levels.ERROR)
    return
  end

  local chat = chat_module.buf_get_chat(0)
  if not chat then
    vim.notify("No active chat buffer", vim.log.levels.WARN)
    return
  end

  M.keymaps.parent_agent(chat)
end

return M
