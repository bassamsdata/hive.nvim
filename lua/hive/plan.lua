local fmt = string.format
local uv = vim.uv

local M = {}

---@class Hive.PlanState
---@field bufnr number
---@field file_path string
---@field previous_agent string
---@field status "active"
---@field created_at number
---@field updated_at number
---@type table<number, Hive.PlanState>
local _states = {}

---@param path string
---@return boolean
---@return string|nil
local function ensure_directory(path)
  local ok = vim.fn.mkdir(path, "p")
  if ok == 0 then return false, fmt("Failed to create directory: %s", path) end
  return true, nil
end

---@param path string
---@return string|nil
---@return string|nil
local function read_file(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then return nil, fmt("Failed to open file: %s", path) end

  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, fmt("Failed to stat file: %s", path)
  end

  local content = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)

  if content == nil then return nil, fmt("Failed to read file: %s", path) end
  return content, nil
end

---@param path string
---@param content string
---@return boolean
---@return string|nil
local function write_file(path, content)
  local fd = uv.fs_open(path, "w", 420)
  if not fd then return false, fmt("Failed to open file for writing: %s", path) end

  local ok = uv.fs_write(fd, content, 0)
  uv.fs_close(fd)

  if not ok then return false, fmt("Failed to write file: %s", path) end
  return true, nil
end

---@param bufnr number
---@param cwd? string
---@return string
function M.plan_dir(bufnr, cwd)
  return vim.fs.joinpath(cwd or uv.cwd(), ".hive", "plans")
end

---@param bufnr number
---@param cwd? string
---@return string
function M.plan_path(bufnr, cwd)
  return vim.fs.joinpath(M.plan_dir(bufnr, cwd), fmt("chat-%d.md", bufnr))
end

---@param bufnr number
---@return Hive.PlanState|nil
function M.get(bufnr)
  local state = _states[bufnr]
  return state and vim.deepcopy(state) or nil
end

---@param bufnr number
---@return boolean
function M.is_active(bufnr)
  return _states[bufnr] ~= nil
end

---@param chat table
---@param opts? { cwd?: string }
---@return Hive.PlanState|nil
---@return string|nil
function M.enter(chat, opts)
  opts = opts or {}
  if not chat or not chat.bufnr then return nil, "No chat context available" end

  local existing = _states[chat.bufnr]
  if existing then return vim.deepcopy(existing), nil end

  local plan_dir = M.plan_dir(chat.bufnr, opts.cwd)
  local ok, dir_err = ensure_directory(plan_dir)
  if not ok then return nil, dir_err end

  local file_path = M.plan_path(chat.bufnr, opts.cwd)
  local stat = uv.fs_stat(file_path)
  if not stat then
    local write_ok, write_err = write_file(file_path, "")
    if not write_ok then return nil, write_err end
  end

  local agents = require("hive.agents")
  local previous_agent = agents.active(chat.bufnr) or "build"
  local now = os.time()
  local state = {
    bufnr = chat.bufnr,
    file_path = file_path,
    previous_agent = previous_agent,
    status = "active",
    created_at = now,
    updated_at = now,
  }

  _states[chat.bufnr] = state

  return vim.deepcopy(state), nil
end

---@param bufnr number
---@return string|nil
---@return string|nil
---@return string|nil
function M.read(bufnr)
  local state = _states[bufnr]
  if not state then return nil, nil, "Plan mode is not active" end

  local content, err = read_file(state.file_path)
  if err then return nil, nil, err end

  state.updated_at = os.time()
  return content or "", state.file_path, nil
end

---@param bufnr number
---@param content string
---@return { file_path: string, bytes: number }|nil
---@return string|nil
function M.write(bufnr, content)
  local state = _states[bufnr]
  if not state then return nil, "Plan mode is not active" end
  if type(content) ~= "string" then return nil, "Plan content must be a string" end

  local ok, err = write_file(state.file_path, content)
  if not ok then return nil, err end

  state.updated_at = os.time()
  return {
    file_path = state.file_path,
    bytes = #content,
  }, nil
end

---@param chat table
---@param opts? { approved?: boolean }
---@return { file_path: string, content: string, approved: boolean }|nil
---@return string|nil
function M.exit(chat, opts)
  opts = opts or {}
  if not chat or not chat.bufnr then return nil, "No chat context available" end

  local state = _states[chat.bufnr]
  if not state then return nil, "Plan mode is not active" end

  local content, _, read_err = M.read(chat.bufnr)
  if read_err then return nil, read_err end

  _states[chat.bufnr] = nil

  return {
    file_path = state.file_path,
    content = content or "",
    approved = opts.approved == true,
  }, nil
end

---@param bufnr number
function M.clear(bufnr)
  _states[bufnr] = nil
end

function M.clear_all()
  _states = {}
end

---@param bufnr number
---@return string
function M.prompt_suffix(bufnr)
  local state = _states[bufnr]
  if not state then return "" end

  return fmt(
    [[

<plan-workflow>
Plan mode is active for this chat.
Plan file: %s

This is a planning phase. Stay in the current chat, but shift your behavior from implementation to exploration and design.

In plan mode, you should:
1. Thoroughly explore the codebase and understand existing patterns before deciding on an approach.
2. Identify similar features, trace relevant code paths, and compare trade-offs when multiple approaches are possible.
3. Ask the user clarifying questions when requirements or preferences affect the design.
4. Write the full implementation plan to the plan file with `write_plan_file`.
5. Use `read_plan_file` to verify what is currently saved on disk.
6. Call `exit_plan_mode` when the plan is complete and ready for approval.

Important constraints:
- Do not modify project files while in plan mode.
- Do not treat this as an implementation phase.
- Keep your work focused on research, design, sequencing, and risks.
</plan-workflow>]],
    state.file_path
  )
end

return M
