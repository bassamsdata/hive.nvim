-- Child chat lifecycle management for subagent tools
-- Handles creation, event listeners, and cleanup of child chat sessions

local api = vim.api
local log = require("codecompanion.utils.log")
local fmt = string.format

local M = {}

-- ============================================================================
-- Adapter Configuration
-- ============================================================================

---Get adapter params based on model_type configuration
---Task subagents use "small" model, consult advisors use "big" model.
---Falls back to inheriting from the parent chat adapter if no model is configured.
---@param args { parent_chat: table, model_type?: "small"|"big" }
---@return table|nil params { adapter: string, model?: string }
function M.get_adapter_params(args)
  local parent_chat = args.parent_chat
  local model_type = args.model_type or "small"
  local extra_config = require("codecompanion-extra.config")

  local model = extra_config.get_model(model_type)
  if model then
    log:debug("[Lifecycle] Using %s_model: adapter=%s, model=%s", model_type, model.adapter, model.model)

    return {
      adapter = model.adapter,
      model = model.model,
    }
  end

  local parent_adapter = parent_chat.adapter
  if parent_adapter then
    local adapter_name = parent_adapter.name
    local model_name = parent_adapter.schema and parent_adapter.schema.model and parent_adapter.schema.model.default

    if type(model_name) == "function" then model_name = model_name(parent_adapter) end

    if adapter_name then
      log:debug("[Lifecycle] Inheriting from parent: adapter=%s, model=%s", adapter_name, model_name or "default")
      return {
        adapter = adapter_name,
        model = model_name,
      }
    end
  end

  return nil
end

-- ============================================================================
-- Child Chat Creation
-- ============================================================================

---Create a child chat with proper configuration
---@param args { parent_chat: table, auto_submit?: boolean, model_type?: "small"|"big" }
---@return table|nil child_chat
function M.create_child_chat(args)
  local codecompanion = require("codecompanion")
  local parent = args.parent_chat

  local chat_opts = {
    auto_submit = args.auto_submit or false,
    window_opts = parent.ui and parent.ui.window_opts,
    hidden = true,
  }

  local params = M.get_adapter_params({
    parent_chat = parent,
    model_type = args.model_type,
  })
  if params then chat_opts.params = params end

  return codecompanion.chat(chat_opts)
end

---Hide child UI and restore parent UI visibility
---@param args { child_chat: table, parent_chat: table }
function M.hide_child_restore_parent(args)
  local utils = require("codecompanion-extra.tools.subagent.utils")

  vim.schedule(function()
    utils.safe_hide_child_ui(args.child_chat)

    if args.parent_chat and args.parent_chat.ui then
      local window_opts = args.parent_chat.ui.window_opts or { default = true }
      args.parent_chat.ui:open({ window_opts = window_opts })
    end
  end)
end

---Create hierarchy session for child chat
---@param args { child_bufnr: number, parent_bufnr: number, agent_name: string, description?: string, hidden?: boolean }
function M.create_hierarchy_session(args)
  local hierarchy = require("codecompanion-extra.agents.hierarchy")

  hierarchy.create_session({
    bufnr = args.child_bufnr,
    parent_bufnr = args.parent_bufnr,
    agent_name = args.agent_name,
    agent_type = "subagent",
    description = args.description or "",
    hidden = args.hidden ~= false,
  })
end

---Activate agent, add prompt message, and submit
---@param args { child_chat: table, agent_name: string, prompt: string, silent?: boolean }
---@return boolean success
function M.activate_and_submit(args)
  local agents = require("codecompanion-extra.agents")
  local cc_config = require("codecompanion.config")
  local hierarchy = require("codecompanion-extra.agents.hierarchy")

  local ok = agents.activate(args.agent_name, args.child_chat, { silent = args.silent ~= false })
  if not ok then
    log:error("[Lifecycle] Failed to activate agent: %s", args.agent_name)
    return false
  end

  args.child_chat:add_message({
    role = cc_config.constants.USER_ROLE,
    content = args.prompt,
  }, { visible = true })

  hierarchy.start_timer(args.child_chat.bufnr)
  args.child_chat:submit()

  return true
end

-- ============================================================================
-- Event Listeners
-- ============================================================================

---@class SubagentListenerCallbacks
---@field on_tool_started? fun(event: table, tool_name: string)
---@field on_tool_finished? fun(event: table, tool_name: string)
---@field on_done? fun(event: table)
---@field on_stopped? fun(event: table)
---@field on_closed? fun(event: table)

---Setup event listeners for a child chat
---@param args { child_bufnr: number, group_name: string, callbacks: SubagentListenerCallbacks }
---@return number aug_id The autocommand group ID for cleanup
function M.setup_listeners(args)
  local aug = api.nvim_create_augroup(args.group_name, { clear = true })
  local bufnr = args.child_bufnr
  local cb = args.callbacks

  if cb.on_tool_started or cb.on_tool_finished then
    api.nvim_create_autocmd("User", {
      group = aug,
      pattern = { "CodeCompanionToolStarted", "CodeCompanionToolFinished" },
      callback = function(event)
        if not event.data or event.data.bufnr ~= bufnr then return end

        if event.match == "CodeCompanionToolStarted" and cb.on_tool_started then
          local tool_name = event.data.tool or "unknown"
          cb.on_tool_started(event, tool_name)
        elseif event.match == "CodeCompanionToolFinished" and cb.on_tool_finished then
          local tool_name = event.data.name or "unknown"
          cb.on_tool_finished(event, tool_name)
        end
      end,
    })
  end

  if cb.on_done then
    api.nvim_create_autocmd("User", {
      group = aug,
      pattern = "CodeCompanionChatDone",
      callback = function(event)
        if event.data and event.data.bufnr == bufnr then
          cb.on_done(event)
          return true
        end
      end,
    })
  end

  if cb.on_stopped then
    api.nvim_create_autocmd("User", {
      group = aug,
      pattern = "CodeCompanionChatStopped",
      callback = function(event)
        if event.data and event.data.bufnr == bufnr then
          cb.on_stopped(event)
          return true
        end
      end,
    })
  end

  if cb.on_closed then
    api.nvim_create_autocmd("User", {
      group = aug,
      pattern = "CodeCompanionChatClosed",
      callback = function(event)
        if event.data and event.data.bufnr == bufnr then
          cb.on_closed(event)
          return true
        end
      end,
    })
  end

  return aug
end

---Cleanup listeners by autogroup ID
---@param aug_id number|nil
function M.cleanup_listeners(aug_id)
  if aug_id then pcall(api.nvim_del_augroup_by_id, aug_id) end
end

-- ============================================================================
-- Full Lifecycle Setup
-- ============================================================================

---Full child chat setup: create, hide, hierarchy, activate, submit
---@param args { parent_chat: table, agent_name: string, prompt: string, description?: string, hidden?: boolean, silent?: boolean, model_type?: "small"|"big" }
---@return table|nil child_chat, number|nil child_bufnr
function M.spawn_child(args)
  local child_chat = M.create_child_chat({
    parent_chat = args.parent_chat,
    model_type = args.model_type,
  })
  if not child_chat then
    log:error("[Lifecycle] Failed to create child chat")
    return nil, nil
  end

  local child_bufnr = child_chat.bufnr

  if not child_chat.hidden then
    M.hide_child_restore_parent({
      child_chat = child_chat,
      parent_chat = args.parent_chat,
    })
  end

  M.create_hierarchy_session({
    child_bufnr = child_bufnr,
    parent_bufnr = args.parent_chat.bufnr,
    agent_name = args.agent_name,
    description = args.description,
    hidden = args.hidden,
  })

  local ok = M.activate_and_submit({
    child_chat = child_chat,
    agent_name = args.agent_name,
    prompt = args.prompt,
    silent = args.silent,
  })

  if not ok then return nil, nil end

  return child_chat, child_bufnr
end

return M
