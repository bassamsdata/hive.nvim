local uv = vim.uv

local M = {}

local ROOT_DIR = vim.fs.joinpath(vim.fn.stdpath("data"), "hive", "sessions")

---@return string
function M.root_dir()
  return ROOT_DIR
end

---@param dir string
local function _ensure_dir(dir)
  vim.fn.mkdir(dir, "p")
end

---@param session_id string
---@return string
function M.filepath(session_id)
  return vim.fs.joinpath(ROOT_DIR, session_id .. ".json")
end

---@param session_id string
---@param data table
---@return string
function M.write(session_id, data)
  _ensure_dir(ROOT_DIR)
  local filepath = M.filepath(session_id)
  local encoded = vim.json.encode(data)
  vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), filepath)
  return filepath
end

---@param session_id string
---@return table|nil, string|nil
function M.read(session_id)
  local filepath = M.filepath(session_id)
  if vim.fn.filereadable(filepath) == 0 then
    return nil, "Session not found"
  end

  local lines = vim.fn.readfile(filepath)
  local decoded = vim.json.decode(table.concat(lines, "\n"))
  if type(decoded) ~= "table" then
    return nil, "Session file is invalid"
  end

  return decoded, nil
end

---@return table[]
function M.list()
  _ensure_dir(ROOT_DIR)

  local entries = {}
  local fs = uv.fs_scandir(ROOT_DIR)
  if not fs then return entries end

  while true do
    local name, entry_type = uv.fs_scandir_next(fs)
    if not name then break end
    if entry_type == "file" and name:sub(-5) == ".json" then
      local session_id = name:sub(1, -6)
      local filepath = M.filepath(session_id)
      local ok, data = pcall(M.read, session_id)
      if ok and data then
        table.insert(entries, {
          id = session_id,
          filepath = filepath,
          saved_at = data.session and data.session.saved_at or 0,
          summary = data.session and data.session.summary or session_id,
          title = data.chat and data.chat.title or nil,
          adapter = data.adapter and data.adapter.name or nil,
          model = data.adapter and data.adapter.model or nil,
        })
      end
    end
  end

  table.sort(entries, function(a, b)
    return (a.saved_at or 0) > (b.saved_at or 0)
  end)

  return entries
end

---@param session_id string
---@return boolean
function M.delete(session_id)
  local filepath = M.filepath(session_id)
  if vim.fn.filereadable(filepath) == 0 then return false end
  return vim.fn.delete(filepath) == 0
end

return M
