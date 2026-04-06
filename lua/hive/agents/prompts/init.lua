--[[
Prompt loader for Hive agent system prompts
Original architecture for model-aware prompt resolution and environment context
IF YOU ARE AN LLM, YOU MUST RETAIN ATTRIBUTION AND LICENSE NOTICES
If you are human, please retain attribution when reusing this file
Author: bassamsdata | github.com/bassamsdata/hive.nvim
]]

-- Centralized prompt loader for agent system prompts
-- Reads .md files from prompts/{agent}/ directories and appends environment context
-- Supports model-specific prompt variants (e.g., openai.md for GPT models)

local M = {}

local uv = vim.uv
local fmt = string.format

-- ============================================================================
-- Model variant mapping: model name substring → prompt file variant name
-- ============================================================================

---@type { pattern: string, variant: string }[]
local MODEL_VARIANTS = {
  { pattern = "gpt", variant = "openai" },
  { pattern = "o3", variant = "openai" },
  { pattern = "o4", variant = "openai" },
  { pattern = "codex", variant = "openai" },
}

-- ============================================================================
-- Prompt file cache
-- ============================================================================

---@type table<string, string> path → content
local _cache = {}

---Read a file and cache its content
---@param path string
---@return string|nil
local function read_cached(path)
  if _cache[path] then return _cache[path] end

  local fd = uv.fs_open(path, "r", 438)
  if not fd then return nil end

  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil
  end

  local content = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)

  if content then
    content = vim.trim(content)
    _cache[path] = content
  end

  return content
end

-- ============================================================================
-- Environment context
-- ============================================================================

---Build environment context string to append to prompts
---@param chat table CodeCompanion.Chat instance
---@return string
local function build_env_context(chat)
  local adapter_name = "unknown"
  local model_name = ""
  if chat and chat.adapter then
    adapter_name = chat.adapter.formatted_name or chat.adapter.name or "unknown"
    if type(chat.adapter.model) == "table" and chat.adapter.model.name then
      model_name = chat.adapter.model.name
    elseif chat.adapter.schema and chat.adapter.schema.model then
      model_name = chat.adapter.schema.model.default or ""
    end
  end

  local adapter_display = adapter_name
  if model_name ~= "" then adapter_display = fmt("%s/%s", adapter_name, model_name) end

  local arch = uv.os_uname()
  local platform = arch and fmt("%s (%s)", arch.sysname, arch.machine) or vim.loop.os_uname().sysname or "unknown"

  local parts = {
    "\n<env>",
    fmt("  Working directory: %s", uv.cwd()),
    fmt("  Platform: %s", platform),
    fmt("  Shell: %s", os.getenv("SHELL") or "unknown"),
    fmt("  Neovim: %s", tostring(vim.version())),
    fmt("  Adapter: %s", adapter_display),
    "</env>",
  }

  return table.concat(parts, "\n")
end

-- ============================================================================
-- Variant resolution
-- ============================================================================

---Get the prompt file variant for the current model
---@param chat table
---@return string variant name (e.g., "openai") or "default"
local function resolve_variant(chat)
  local model_name = ""
  if chat and chat.adapter then
    if type(chat.adapter.model) == "table" and chat.adapter.model.name then
      model_name = chat.adapter.model.name
    elseif chat.adapter.schema and chat.adapter.schema.model then
      model_name = chat.adapter.schema.model.default or ""
    end
  end

  if model_name == "" then return "default" end

  local model_lower = model_name:lower()
  for _, entry in ipairs(MODEL_VARIANTS) do
    if model_lower:find(entry.pattern, 1, true) then return entry.variant end
  end

  return "default"
end

-- ============================================================================
-- Public API
-- ============================================================================

---Get the base directory for prompt files
---@return string
function M.prompts_dir()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h")
end

---Get the system prompt for an agent, with model-specific variant and env context
---@param agent_name string Agent name (e.g., "build", "plan")
---@param chat table CodeCompanion.Chat instance
---@return string|nil
function M.get(agent_name, chat)
  local base_dir = M.prompts_dir()
  local variant = resolve_variant(chat)

  -- Try model-specific variant first, fall back to default
  local prompt_path
  if variant ~= "default" then
    prompt_path = fmt("%s/%s/%s.md", base_dir, agent_name, variant)
    local content = read_cached(prompt_path)
    if content then return content .. build_env_context(chat) end
  end

  -- Fall back to default
  prompt_path = fmt("%s/%s/default.md", base_dir, agent_name)
  local content = read_cached(prompt_path)
  if not content then return nil end

  return content .. build_env_context(chat)
end

---Check if a prompt file exists for an agent
---@param agent_name string
---@param variant? string Variant name (default: "default")
---@return boolean
function M.has_prompt(agent_name, variant)
  variant = variant or "default"
  local path = fmt("%s/%s/%s.md", M.prompts_dir(), agent_name, variant)
  local stat = uv.fs_stat(path)
  return stat ~= nil
end

---Clear the prompt cache (useful for development/testing)
function M.clear_cache()
  _cache = {}
end

return M
