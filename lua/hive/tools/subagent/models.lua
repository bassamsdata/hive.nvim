-- Shared model utilities for subagents
-- Consolidates model validation, pattern matching, and validation logic
-- Used by: lifecycle.lua, task.lua, consult.lua, cmd_runner.lua

local log = require("codecompanion.utils.log")
local fmt = string.format

local M = {}

-- ============================================================================
-- Pattern Matching
-- ============================================================================

---Convert a glob-like pattern to a Lua regex pattern
---Supports: * (any chars), ? (single char). Escapes Lua magic chars.
---Example: "copilot/gpt*" -> "^copilot/gpt.*$"
---@param glob string The glob pattern
---@return string Lua regex pattern
function M.glob_to_pattern(glob)
  local pattern = glob:gsub("([%.%+%-%^%$%(%)%%])", "%%%1")
  pattern = pattern:gsub("%[", "%%[")
  pattern = pattern:gsub("%]", "%%]")
  pattern = pattern:gsub("%*", ".*")
  pattern = pattern:gsub("%?", ".")
  return "^" .. pattern .. "$"
end

-- ============================================================================
-- Model Parsing & Configuration
-- ============================================================================

---Parse model string in format "adapter/model" or "adapter/provider/model"
---@param model_str string|nil The model string to parse
---@return { adapter: string, model: string }|nil Parsed adapter and model, or nil if invalid
function M.parse_model_string(model_str)
  if not model_str or model_str == "" then return nil end

  local parts = vim.split(model_str, "/", { plain = true })
  if #parts == 2 then
    -- Format: "openai/gpt-4o-mini" -> adapter: openai, model: gpt-4o-mini
    return { adapter = parts[1], model = parts[2] }
  elseif #parts >= 3 then
    -- Format: "openrouter/openai/gpt-4o" -> adapter: openrouter, model: openai/gpt-4o
    return { adapter = parts[1], model = table.concat(vim.list_slice(parts, 2), "/") }
  end

  return nil
end

---Get model configuration for agents (big or small)
---Priority: vim.g.HIVE_{TYPE}_MODEL > vim.g.hive_{type}_model > config.agents.{type}_model > nil
---@param type "small"|"big"
---@return { adapter: string, model: string }|nil
function M.get_model(type)
  local ok, config_module = pcall(require, "hive.config")
  if not ok then return nil end

  local model = vim.g["HIVE_" .. type:upper() .. "_MODEL"]
    or vim.g["hive_" .. type .. "_model"]
    or (config_module.get().agents and config_module.get().agents[type .. "_model"])

  return M.parse_model_string(model)
end

-- ============================================================================
-- Expensive Model Detection
-- ============================================================================

---Check if a model matches any expensive model pattern from config
---Patterns can be:
---  "adapter/model*" - match specific adapter
---  "model*" - match any adapter with this model pattern
---  "*/model*" - explicitly match any adapter
---@param adapter_name string The adapter name (e.g., "copilot", "openai")
---@param model_name string|nil The model name (e.g., "gpt-4o", "claude-opus")
---@return boolean true if model matches any pattern in confirm_expensive_models
function M.is_expensive_model(adapter_name, model_name)
  local ok, config_module = pcall(require, "hive.config")
  if not ok then return false end

  local config = config_module.get()
  local patterns = config.agents and config.agents.confirm_expensive_models
  if not patterns or #patterns == 0 then return false end

  local model_str = adapter_name .. "/" .. (model_name or "")
  log:debug("[Models] Checking expensive model: '%s' against %d patterns", model_str, #patterns)

  for _, glob in ipairs(patterns) do
    local pat, match_target

    if glob:find("/", 1, true) then
      pat = M.glob_to_pattern(glob)
      match_target = model_str
    else
      pat = M.glob_to_pattern(glob)
      match_target = model_name or ""
    end

    log:debug("[Models]   Pattern: '%s' -> '%s' (matching against '%s')", glob, pat, match_target)
    if match_target:match(pat) then
      log:debug("[Models]   ✓ MATCH! '%s' matches '%s'", match_target, glob)
      return true
    end
  end

  log:debug("[Models]   ✗ No match for '%s'", model_str)
  return false
end

-- ============================================================================
-- Suspicious Fast Completion Detection
-- ============================================================================

---Detect if a subagent completed suspiciously fast with no tool usage
---This usually indicates a misconfigured provider/model (wrong API key, endpoint, etc.)
---@param args { elapsed_ms: number, tool_count: number, threshold_ms: number, subagent_type: string, context: "task"|"consult" }
---@return boolean is_suspicious, string|nil error_message
function M.detect_suspicious_fast_completion(args)
  local elapsed_ms = args.elapsed_ms
  local tool_count = args.tool_count
  local threshold_ms = args.threshold_ms
  local subagent_type = args.subagent_type
  local context = args.context

  if elapsed_ms >= threshold_ms or tool_count > 0 then return false, nil end

  local context_label = context == "task" and "Task" or "Consult"
  local log_msg = fmt(
    "[%s] Subagent '%s' completed in %dms with 0 tools — likely misconfigured provider/model",
    context_label,
    subagent_type,
    elapsed_ms
  )

  local result_msg = fmt(
    "Subagent '%s' completed suspiciously fast (%dms) with no tool usage. "
      .. "This usually means the provider or model is misconfigured (wrong API key, model name, or endpoint). "
      .. "Check your adapter configuration.",
    subagent_type,
    elapsed_ms
  )

  log:warn(log_msg)
  return true, result_msg
end

return M
