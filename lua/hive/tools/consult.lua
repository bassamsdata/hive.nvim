-- Consult tool for expert advisory consultations
-- Spawns specialized advisor subagents for strategic guidance, code review, and analysis
--
-- Unlike the task tool (delegation), consult is for getting expert opinions:
-- - sage: Strategic/architectural decisions, complex debugging
-- - reviewer: Code review after completing work
-- - security: Security analysis and vulnerability assessment
-- - performance: Performance optimization guidance

local log = require("codecompanion.utils.log")
local compat = require("hive.tools.compat")
local subagent = require("hive.tools.subagent")

local api = vim.api
local fmt = string.format
local uv = vim.uv

-- ============================================================================
-- Advisor-Specific Icons
-- ============================================================================

local ICONS = {
  sage = "󰏒",
  reviewer = "",
  security = "󰒃",
  performance = "󰓅",
  default = "",
  thinking = "",
}

local SUSPICIOUS_FAST_MS = 2000

-- ============================================================================
-- Active Consultations Registry
-- ============================================================================

---@class ConsultationState
---@field id string Unique consultation ID
---@field parent_chat table Parent chat reference
---@field parent_bufnr number Parent buffer number
---@field advisor_type string Type of advisor (sage, reviewer, etc.)
---@field question string The original consultation question
---@field description string Brief description for status display
---@field child_bufnr number|nil Child buffer number
---@field child_chat table|nil Child chat reference
---@field start_time number Start time (hrtime nanoseconds)
---@field callback function|nil Completion callback
---@field timer uv.uv_timer_t|nil Animation timer
---@field ns_id number Namespace ID for extmarks
---@field tool_count number Number of tools executed
---@field current_tool string|nil Currently executing tool
---@field status "running"|"completed"|"failed"|"cancelled" Current status
---@field result string|nil Final result text
---@field timeout_timer uv.uv_timer_t|nil Idle timeout timer
---@field aug number|nil Autocommand group ID
---@field completed boolean Whether consultation has completed
---@field advisor_info? { name: string, display_name: string, icon: string } Cached advisor display metadata
---@field agent_icons? string[] Cached icon list for highlight detection
---@field static_status_lines? string[] Cached static status lines (header + description)

---@type table<number, ConsultationState> Active consultations by parent bufnr
local _active_consultations = {}

---@type table<string, ConsultationState> Consultation history by ID (for resume)
local _consultation_history = {}

---@type number Consultation ID counter
local _consultation_id_counter = 0

-- ============================================================================
-- Utility Functions
-- ============================================================================

---Generate a unique consultation ID
---@return string
local function generate_consultation_id()
  _consultation_id_counter = _consultation_id_counter + 1
  return fmt("consult_%d_%d", os.time(), _consultation_id_counter)
end

---Get icon for advisor type
---@param advisor_type string
---@return string
local function get_advisor_icon(advisor_type)
  return ICONS[advisor_type] or ICONS.default
end

---Get advisor display info from registry
---@param advisor_type string
---@return { name: string, display_name: string, icon: string }
local function get_advisor_info(advisor_type)
  local ok, registry = pcall(require, "hive.agents.registry")
  if ok then
    local agent = registry.get(advisor_type)
    if agent then
      return {
        name = agent.name,
        display_name = agent.display_name or subagent.utils.capitalize(agent.name),
        icon = agent.icon ~= "" and agent.icon or get_advisor_icon(agent.name),
      }
    end
  end

  return {
    name = advisor_type,
    display_name = subagent.utils.capitalize(advisor_type),
    icon = get_advisor_icon(advisor_type),
  }
end

---Rebuild cached status display data for a consultation
---@param state ConsultationState
local function rebuild_status_cache(state)
  local info = state.advisor_info or get_advisor_info(state.advisor_type)
  state.advisor_info = info
  state.agent_icons = { info.icon }
  state.static_status_lines = {
    fmt("─────── %s %s Consultation ───────", info.icon, info.display_name),
    fmt("  %s %s", info.icon, state.description),
  }
end

---Build consultation prompt with context
---@param args { question: string, context?: string, urgency?: string }
---@return string
local function build_consultation_prompt(args)
  local parts = {}

  if args.urgency == "blocking" then
    -- TODO:I need to re-evalute this one fi it's better or not to enhance performance of Sage
    table.insert(parts, "**URGENT - BLOCKING**: This is blocking my work and needs immediate guidance.\n")
  elseif args.urgency == "important" then
    table.insert(parts, "**Important**: This is a significant decision that needs careful consideration.\n")
  end

  table.insert(parts, "## Consultation Request\n")
  table.insert(parts, args.question)

  if args.context and args.context ~= "" then
    table.insert(parts, "\n\n## Context Provided\n")
    table.insert(parts, args.context)
  end

  table.insert(parts, "\n\n---\nPlease provide your expert analysis and recommendations.")

  return table.concat(parts, "")
end

-- ============================================================================
-- Status Display
-- ============================================================================

---Build status text for a consultation
---@param state ConsultationState
---@param spinner_char string
---@return string
local function build_status_text(state, spinner_char)
  local utils = subagent.utils

  local elapsed_ms = utils.get_elapsed_ms(state.start_time)
  local elapsed_str = utils.format_duration(elapsed_ms)

  if not state.static_status_lines then rebuild_status_cache(state) end
  local lines = { state.static_status_lines[1], state.static_status_lines[2] }

  if state.status == "running" then
    local tool_info = state.tool_count > 0 and fmt(" | ToolCalls: %d", state.tool_count) or ""
    if state.current_tool then
      table.insert(lines, fmt("  %s Running: `%s`%s", spinner_char, state.current_tool, tool_info))
    else
      table.insert(lines, fmt("  %s Working...%s", spinner_char, tool_info))
    end
  elseif state.status == "completed" then
    local tool_info = state.tool_count > 0 and fmt(" (%d tools)", state.tool_count) or ""
    table.insert(lines, fmt("  %s Complete%s", utils.STATUS_ICONS.completed, tool_info))
  elseif state.status == "failed" then
    table.insert(lines, fmt("  %s Failed", utils.STATUS_ICONS.failed))
  elseif state.status == "cancelled" then
    table.insert(lines, fmt("  %s Cancelled", utils.STATUS_ICONS.cancelled))
  end

  table.insert(lines, fmt("  %s %s", utils.STATUS_ICONS.timer, elapsed_str))
  table.insert(lines, "  " .. utils.KEYMAP_HINTS)
  table.insert(lines, "───────────────────────────────")

  return table.concat(lines, "\n")
end

---Render status notification in parent chat buffer
---@param state ConsultationState
local function render_status(state)
  if not state.parent_bufnr or not api.nvim_buf_is_valid(state.parent_bufnr) then return end

  local spinner_idx = math.floor((uv.hrtime() - state.start_time) / 100000000) % #subagent.utils.SPINNER_FRAMES + 1
  local spinner_char = subagent.utils.SPINNER_FRAMES[spinner_idx]
  if not state.agent_icons or not state.static_status_lines then rebuild_status_cache(state) end

  local status_text = build_status_text(state, spinner_char)
  subagent.status.render({
    bufnr = state.parent_bufnr,
    ns_id = state.ns_id,
    text = status_text,
    icons = subagent.utils.STATUS_ICONS,
    agent_icons = state.agent_icons,
  })
end

-- ============================================================================
-- Timer Management
-- ============================================================================

---Start animation timer for consultation status
---@param state ConsultationState
local function start_timer(state)
  if state.timer then return end

  state.timer = subagent.utils.create_spinner_timer({
    on_tick = function()
      if not state.parent_bufnr or not api.nvim_buf_is_valid(state.parent_bufnr) then
        subagent.utils.safe_close_timer(state.timer)
        state.timer = nil
        return
      end
      render_status(state)
    end,
  })
end

---Stop animation timer
---@param state ConsultationState
local function stop_timer(state)
  subagent.utils.safe_close_timer(state.timer)
  state.timer = nil
end

---Stop timeout timer
---@param state ConsultationState
local function stop_timeout_timer(state)
  subagent.utils.safe_close_timer(state.timeout_timer)
  state.timeout_timer = nil
end

---Reset (restart) the idle timeout timer
---@param state ConsultationState
local function reset_timeout_timer(state)
  stop_timeout_timer(state)

  state.timeout_timer = subagent.utils.create_timeout_timer({
    on_timeout = function()
      if state.status ~= "running" then return end

      local hierarchy = require("hive.agents.hierarchy")
      local session = state.child_bufnr and hierarchy.get_session(state.child_bufnr)
      if not session or session.status ~= "running" then return end

      local info = state.advisor_info or get_advisor_info(state.advisor_type)
      state.advisor_info = info
      local elapsed_sec = math.floor(subagent.utils.IDLE_TIMEOUT_MS / 1000)

      log:warn(
        "[Consult] Advisor '%s' timed out after %ds of inactivity (tools used: %d)",
        state.advisor_type,
        elapsed_sec,
        state.tool_count
      )

      state.status = "failed"
      hierarchy.set_status(state.child_bufnr, "failed")
      if state.child_chat and state.child_chat.stop then pcall(state.child_chat.stop, state.child_chat) end

      vim.defer_fn(function()
        complete_consultation(
          state,
          "error",
          fmt(
            "Advisor '%s' timed out after %d seconds of no tool activity. Tools executed: %d",
            info.display_name,
            elapsed_sec,
            state.tool_count
          )
        )
      end, 500)
    end,
  })
end

-- ============================================================================
-- Consultation Completion
-- ============================================================================

---Complete a consultation and call callback
---@param state ConsultationState
---@param status "success"|"error"
---@param result string
function complete_consultation(state, status, result)
  if state.completed then return end

  state.completed = true
  state.status = status == "success" and "completed" or "failed"
  state.result = result
  stop_timeout_timer(state)
  stop_timer(state)

  subagent.status.clear_after_delay({
    bufnr = state.parent_bufnr,
    ns_id = state.ns_id,
  })

  local elapsed_ms = subagent.utils.get_elapsed_ms(state.start_time)
  local hierarchy = require("hive.agents.hierarchy")
  if state.child_bufnr then hierarchy.set_status(state.child_bufnr, state.status, result) end

  subagent.lifecycle.cleanup_listeners(state.aug)

  local duration_str = subagent.utils.format_duration(elapsed_ms)

  local consolidated = fmt(
    [[<consultation_result id="%s" advisor="%s" status="%s" duration="%s" tool_calls="%d">
%s
</consultation_result>]],
    state.id,
    state.advisor_type,
    status,
    duration_str,
    state.tool_count,
    result
  )

  _consultation_history[state.id] = state
  _active_consultations[state.parent_bufnr] = nil

  if state.callback then state.callback({ status = status, data = consolidated }) end
end

-- ============================================================================
-- Event Listeners
-- ============================================================================

---Setup event listeners for a child chat
---@param state ConsultationState
local function setup_child_listeners(state)
  local hierarchy = require("hive.agents.hierarchy")

  local tool_call_counter = 0

  local aug = subagent.lifecycle.setup_listeners({
    child_bufnr = state.child_bufnr,
    group_name = "codecompanion_consult_" .. state.child_bufnr,
    callbacks = {
      on_tool_started = function(event, tool_name)
        tool_call_counter = tool_call_counter + 1
        state.tool_count = tool_call_counter
        state.current_tool = tool_name

        local tool_id = fmt("tool_%d", tool_call_counter)
        hierarchy.tool_started(state.child_bufnr, tool_id, tool_name)
        reset_timeout_timer(state)

        subagent.utils.fire("SubagentProgress", {
          parent_bufnr = state.parent_bufnr,
          child_bufnr = state.child_bufnr,
          agent_name = state.advisor_type,
          agent_type = "consult",
          tool_name = tool_name,
          tool_count = tool_call_counter,
        })
      end,

      on_tool_finished = function(event, tool_name)
        local tool_id = fmt("tool_%d", tool_call_counter)
        hierarchy.tool_finished(state.child_bufnr, tool_id, true, tool_name)
        state.current_tool = nil
        reset_timeout_timer(state)
      end,

      on_done = function()
        if state.completed then return end

        local ok, err = pcall(function()
          -- chat.status == "error" is set by on_error before ChatDone fires
          local chat_errored = state.child_chat and state.child_chat.status == "error"

          local elapsed_ms = subagent.utils.get_elapsed_ms(state.start_time)
          local final_status = chat_errored and "error" or "success"

          subagent.utils.fire("SubagentCompleted", {
            parent_bufnr = state.parent_bufnr,
            child_bufnr = state.child_bufnr,
            agent_name = state.advisor_type,
            agent_type = "consult",
            status = final_status,
            duration_ms = elapsed_ms,
            tool_count = state.tool_count,
          })

          -- TODO: maybe we need to chewck if it's empty string??
          local extract_ok, result = pcall(subagent.messages.extract_result, state.child_chat)
          if not extract_ok then
            log:debug("[Consult] on_done extraction failed: %s", result)
            result = chat_errored and "Consultation failed (API error) and result extraction also failed"
              or "Consultation completed but result extraction failed"
          end

          -- Detect suspiciously fast completion: likely a misconfigured provider/model
          local models = require("hive.tools.subagent.models")
          local is_suspicious, suspicious_msg = models.detect_suspicious_fast_completion({
            elapsed_ms = elapsed_ms,
            tool_count = state.tool_count,
            threshold_ms = SUSPICIOUS_FAST_MS,
            subagent_type = state.advisor_type,
            context = "consult",
          })

          if final_status == "success" and is_suspicious then
            final_status = "error"
            result = suspicious_msg
          end

          complete_consultation(state, final_status, result)
        end)

        if not ok then
          log:debug("[Consult] on_done failed: %s", err)
          complete_consultation(state, "error", fmt("Consultation failed with internal error: %s", tostring(err)))
        end
      end,

      on_stopped = function()
        if state.completed then return end

        local ok, err = pcall(function()
          local elapsed_ms = subagent.utils.get_elapsed_ms(state.start_time)
          subagent.utils.fire("SubagentCompleted", {
            parent_bufnr = state.parent_bufnr,
            child_bufnr = state.child_bufnr,
            agent_name = state.advisor_type,
            agent_type = "consult",
            status = "stopped",
            duration_ms = elapsed_ms,
            tool_count = state.tool_count,
          })

          local info = state.advisor_info or get_advisor_info(state.advisor_type)
          state.advisor_info = info
          complete_consultation(state, "error", fmt("Consultation with %s was stopped", info.display_name))
        end)

        if not ok then
          log:debug("[Consult] on_stopped failed: %s", err)
          complete_consultation(state, "error", fmt("Consultation stopped with internal error: %s", tostring(err)))
        end
      end,

      on_closed = function()
        if state.completed then return end
        if state.status ~= "running" then return end

        local ok, err = pcall(function()
          local elapsed_ms = subagent.utils.get_elapsed_ms(state.start_time)
          subagent.utils.fire("SubagentCompleted", {
            parent_bufnr = state.parent_bufnr,
            child_bufnr = state.child_bufnr,
            agent_name = state.advisor_type,
            agent_type = "consult",
            status = "cancelled",
            duration_ms = elapsed_ms,
            tool_count = state.tool_count,
          })

          local info = state.advisor_info or get_advisor_info(state.advisor_type)
          state.advisor_info = info
          complete_consultation(state, "error", fmt("Consultation with %s was closed", info.display_name))
        end)

        if not ok then
          log:debug("[Consult] on_closed failed: %s", err)
          complete_consultation(state, "error", fmt("Consultation closed with internal error: %s", tostring(err)))
        end
      end,
    },
  })

  state.aug = aug
end

-- ============================================================================
-- Consultation Execution
-- ============================================================================

---Execute a consultation
---@param args table Tool arguments
---@param parent_chat table Parent chat
---@param callback function Completion callback
local function execute_consultation(args, parent_chat, callback)
  local registry = require("hive.agents.registry")

  local agent = registry.get(args.advisor_type)
  if not agent then
    callback({
      status = "error",
      data = fmt("Unknown advisor type: %s", args.advisor_type),
    })
    return
  end

  if not agent.is_advisor then
    callback({
      status = "error",
      data = fmt("'%s' is not an advisor (use task tool for regular subagents)", args.advisor_type),
    })
    return
  end

  local info = get_advisor_info(args.advisor_type)

  local description = args.description or subagent.utils.truncate(args.question or "", 60)

  local state = {
    id = generate_consultation_id(),
    parent_chat = parent_chat,
    parent_bufnr = parent_chat.bufnr,
    advisor_type = args.advisor_type,
    question = args.question,
    description = fmt("Consulting %s: %s", info.display_name, description),
    start_time = uv.hrtime(),
    callback = callback,
    timer = nil,
    ns_id = api.nvim_create_namespace("codecompanion_consult_" .. parent_chat.bufnr),
    tool_count = 0,
    current_tool = nil,
    status = "running",
    completed = false,
    advisor_info = info,
  }
  rebuild_status_cache(state)

  _active_consultations[parent_chat.bufnr] = state

  start_timer(state)

  local prompt = build_consultation_prompt({
    question = args.question,
    context = args.context,
    urgency = args.urgency,
  })

  local child_chat, child_bufnr = subagent.lifecycle.spawn_child({
    parent_chat = parent_chat,
    agent_name = args.advisor_type,
    prompt = prompt,
    description = state.description,
    hidden = true,
    silent = true,
    model_type = "big",
  })

  if not child_chat or not child_bufnr then
    log:error("[Consult] Failed to create child chat")
    stop_timer(state)
    subagent.status.clear(state.parent_bufnr, state.ns_id)
    state.status = "failed"
    _active_consultations[parent_chat.bufnr] = nil
    callback({
      status = "error",
      data = "Failed to create advisor chat",
    })
    return
  end

  state.child_chat = child_chat
  state.child_bufnr = child_bufnr

  setup_child_listeners(state)
  reset_timeout_timer(state)

  subagent.utils.fire("SubagentStarted", {
    parent_bufnr = state.parent_bufnr,
    child_bufnr = child_bufnr,
    agent_name = args.advisor_type,
    agent_type = "consult",
    description = state.description,
    total_tasks = 1,
  })

  log:debug("[Consult] Started consultation %s with %s advisor (bufnr %d)", state.id, args.advisor_type, child_bufnr)
end

-- ============================================================================
-- Resume/Follow-up Support
-- ============================================================================

---Get an active or recent consultation that can be resumed
---@param parent_bufnr number
---@param consultation_id? string
---@return ConsultationState|nil
local function get_resumable_consultation(parent_bufnr, consultation_id)
  if consultation_id then return _consultation_history[consultation_id] end
  return _active_consultations[parent_bufnr]
end

---Send a follow-up message to an existing consultation
---@param state ConsultationState
---@param message string
---@param callback function
local function send_followup(state, message, callback)
  if not state.child_chat then
    callback({
      status = "error",
      data = "Consultation no longer available for follow-up",
    })
    return
  end

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then
    callback({
      status = "error",
      data = "Failed to load codecompanion config",
    })
    return
  end

  local hierarchy = require("hive.agents.hierarchy")

  state.status = "running"
  state.completed = false
  state.callback = callback
  state.start_time = uv.hrtime()
  state.tool_count = 0
  state.ns_id = api.nvim_create_namespace("codecompanion_consult_followup_" .. state.parent_bufnr)

  local info = get_advisor_info(state.advisor_type)
  state.description = fmt("Follow-up with %s", info.display_name)
  state.advisor_info = info
  rebuild_status_cache(state)

  _active_consultations[state.parent_bufnr] = state

  start_timer(state)
  setup_child_listeners(state)
  reset_timeout_timer(state)

  if state.child_bufnr then hierarchy.start_timer(state.child_bufnr) end

  state.child_chat:add_message({
    role = cc_config.constants.USER_ROLE,
    content = message,
  }, { visible = true })

  state.child_chat:submit({ auto_submit = true })
end

-- ============================================================================
-- Tool Definition
-- ============================================================================

---@class CodeCompanion.Tool.Consult: CodeCompanion.Tools.Tool
return {
  name = "consult",
  cmds = {
    ---Execute the consult tool (async pattern)
    ---@param tools CodeCompanion.Tools
    ---@param args table
    ---@param opts table
    compat.cmds(function(tools, args, opts)
      local output_handler = opts.output_cb
      if not tools or not tools.chat then
        log:error("[Consult] No chat context available")
        return {
          status = "error",
          data = "No chat context available",
        }
      end

      if args.follow_up and args.consultation_id then
        local state = get_resumable_consultation(tools.chat.bufnr, args.consultation_id)
        if state and state.child_chat then
          log:debug("[Consult] Sending follow-up to consultation %s", args.consultation_id)
          send_followup(state, args.message or args.question, output_handler)
          return nil
        else
          return {
            status = "error",
            data = "Consultation not found or no longer available for follow-up",
          }
        end
      end

      log:debug("[Consult] Consulting %s advisor", args.advisor_type)

      execute_consultation(args, tools.chat, output_handler)

      return nil
    end),
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "consult",
      description = [[Consult a specialist advisor for expert guidance on complex decisions, code review, or analysis.

Unlike task delegation (for work completion), consult is for getting expert opinions and recommendations.

**When to use consult:**
- Complex architectural decisions with multiple trade-offs
- After completing significant implementation (self-review)
- After 2+ failed fix attempts (fresh perspective)
- Security concerns or vulnerability analysis
- Performance bottlenecks and optimization strategy

**Advisor types:**
- **sage**: Strategic and architectural guidance. Use for complex decisions, unfamiliar patterns, or when you need a second opinion on approach.
- **reviewer**: Code review after completing work. Gets feedback on correctness, maintainability, and patterns.
- **security**: Security analysis. Use for authentication, authorization, input validation, or data protection concerns.
- **performance**: Performance optimization. Use for bottlenecks, scaling decisions, or efficiency improvements.

**Tips:**
- Be specific in your question - vague questions get vague answers
- Include relevant context (file paths, code snippets, constraints)
- Set urgency appropriately - blocking issues get prioritized treatment
- The advisor will read files as needed to provide informed guidance

**Follow-up:**
- After receiving advice, you can send follow-up questions using follow_up=true and the consultation_id from the previous response]],
      parameters = {
        type = "object",
        properties = {
          advisor_type = {
            type = "string",
            enum = { "sage", "reviewer", "security", "performance" },
            description = "Which specialist to consult: sage (architecture/strategy), reviewer (code review), security (vulnerabilities), performance (optimization)",
          },
          question = {
            type = "string",
            description = "Your specific question or what you need guidance on. Be detailed and specific for better advice.",
          },
          description = {
            type = "string",
            description = "Brief one-line description of what you're consulting about (shown to user in status)",
          },
          context = {
            type = "string",
            description = "Optional additional context: relevant file paths, code snippets, constraints, or background information that would help the advisor.",
          },
          urgency = {
            type = "string",
            enum = { "blocking", "important", "nice_to_have" },
            description = "How urgent is this consultation? 'blocking' = can't proceed without answer, 'important' = significant decision, 'nice_to_have' = optimization/improvement",
          },
          follow_up = {
            type = "boolean",
            description = "Set to true to send a follow-up question to an existing consultation (requires consultation_id). Only include this field when sending a follow-up.",
          },
          consultation_id = {
            type = "string",
            description = "The ID of a previous consultation to send a follow-up to (returned in previous consultation result). Only include this field when follow_up is true.",
          },
        },
        required = { "advisor_type", "question", "description" },
      },
    },
  },
  handlers = {
    on_exit = compat.handler_on_exit(function(_self, _meta)
      log:trace("[Consult Tool] on_exit handler executed")
    end),
  },
  output = {
    ---@param self CodeCompanion.Tool.Consult
    ---@return string
    cmd_string = compat.output_cmd_string(function(self, _meta)
      local info = get_advisor_info(self.args.advisor_type)
      if self.args.follow_up then return fmt("%s Follow-up with %s", info.icon, info.display_name) end
      return fmt("%s Consulting %s", info.icon, info.display_name)
    end),

    ---@param self CodeCompanion.Tool.Consult
    ---@return string
    prompt = compat.output_prompt(function(self, _meta)
      local info = get_advisor_info(self.args.advisor_type)
      local description = self.args.description or subagent.utils.truncate(self.args.question, 80)
      if self.args.follow_up then
        local question_preview = subagent.utils.truncate(self.args.question, 80)
        return fmt("%s Send follow-up to %s?\n\nMessage: %s", info.icon, info.display_name, question_preview)
      end
      return fmt("%s Consult %s?\n\n%s", info.icon, info.display_name, description)
    end),

    ---@param self CodeCompanion.Tool.Consult
    ---@param stdout table
    ---@param meta table
    success = compat.output_success(function(self, stdout, meta)
      local chat = meta.tools.chat
      local output = vim.iter(stdout):flatten():join("\n")

      -- Parse structured attributes from the consultation_result tag
      local consultation_id = output:match('id="([^"]*)"') or "unknown"
      local advisor = output:match('advisor="([^"]*)"') or self.args.advisor_type
      local duration_str = output:match('duration="([^"]*)"') or "0s"
      local tool_count = tonumber(output:match('tool_calls="([^"]*)"')) or 0

      local info = get_advisor_info(advisor)

      local llm_output = output
        .. fmt(
          "\n\nThe %s has provided guidance above. Review their recommendations and proceed accordingly."
            .. '\nIf you need clarification or have follow-up questions, you can use the consult tool with follow_up=true and consultation_id="%s".',
          info.display_name,
          consultation_id
        )

      local description = self.args.description or "Consultation"

      local user_lines = {
        fmt("───── **%s %s Consultation Complete** ─────", info.icon, info.display_name),
        fmt("  %s %s", info.icon, description),
      }
      if tool_count > 0 then
        table.insert(user_lines, fmt("  **%s ToolCalls:** %d", subagent.utils.STATUS_ICONS.tools, tool_count))
      end
      table.insert(user_lines, fmt("  **%s Duration:** %s", subagent.utils.STATUS_ICONS.timer, duration_str))
      if consultation_id ~= "unknown" then table.insert(user_lines, fmt("  **ID:** %s", consultation_id)) end
      table.insert(
        user_lines,
        "─────────────────────────────────────────────"
      )

      local user_output = table.concat(user_lines, "\n")

      chat:add_tool_output(self, llm_output, user_output)
    end),

    error = compat.output_error(function(self, stderr, meta)
      local chat = meta.tools.chat
      local output = vim.iter(stderr):flatten():join("\n")
      local info = get_advisor_info(self.args.advisor_type)

      local error_output = fmt("Consultation with %s failed:\n%s", info.display_name, output)
      chat:add_tool_output(self, error_output, error_output)
    end),
  },
}
