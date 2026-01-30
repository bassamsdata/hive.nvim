-- Skills discovery module for Agent Skills
-- Scans configured directories for SKILL.md files

local M = {}

local uv = vim.uv
local parser = require("codecompanion-extra.skills.parser")

---@class SkillDiscoveryOpts
---@field recursive? boolean Scan subdirectories recursively (default: false)

---Check if path is a directory
---@param path string
---@return boolean
local function is_dir(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "directory" or false
end

---Check if file exists
---@param path string
---@return boolean
local function file_exists(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "file" or false
end

---Scan a single directory for skill folders
---@param dir string Directory to scan
---@param opts? SkillDiscoveryOpts
---@return SkillMeta[]
local function scan_directory(dir, opts)
  opts = opts or {}
  local skills = {}

  dir = vim.fs.normalize(dir)

  if not is_dir(dir) then return skills end

  local handle = uv.fs_scandir(dir)
  if not handle then return skills end

  while true do
    local name, ftype = uv.fs_scandir_next(handle)
    if not name then break end

    if ftype == "directory" then
      local subdir = vim.fs.joinpath(dir, name)
      local skill_md = vim.fs.joinpath(subdir, "SKILL.md")

      local md_exists = file_exists(skill_md)

      if md_exists then
        local meta = parser.parse_meta(skill_md)
        if meta then
          local valid = parser.validate(meta)
          if valid then table.insert(skills, meta) end
        end
      end

      if opts.recursive then
        local nested = scan_directory(subdir, opts)
        for _, skill in ipairs(nested) do
          table.insert(skills, skill)
        end
      end
    end
  end

  return skills
end

---Find git root from a starting directory
---@param start_dir string
---@return string|nil
local function find_git_root(start_dir)
  local dir = vim.fs.normalize(start_dir)

  while dir and dir ~= "/" do
    if is_dir(vim.fs.joinpath(dir, ".git")) then return dir end
    dir = vim.fn.fnamemodify(dir, ":h")
  end

  return nil
end

---Get default skill directories to scan
---@return string[]
function M.default_directories()
  local dirs = {}
  local cwd = vim.fn.getcwd()
  local home = vim.fn.expand("~")

  -- Project-level directories
  table.insert(dirs, vim.fs.joinpath(cwd, ".codecompanion", "skills"))
  table.insert(dirs, vim.fs.joinpath(cwd, ".claude", "skills"))
  table.insert(dirs, vim.fs.joinpath(cwd, ".opencode", "skills"))

  -- User-level directories
  table.insert(dirs, vim.fs.joinpath(home, ".config", "codecompanion", "skills"))
  table.insert(dirs, vim.fs.joinpath(home, ".config", "opencode", "skills"))
  table.insert(dirs, vim.fs.joinpath(home, ".claude", "skills"))

  return dirs
end

---Discover all skills from configured directories
---@param directories string[]
---@param opts? SkillDiscoveryOpts
---@return table<string, SkillMeta> Map of skill name to metadata
function M.discover(directories, opts)
  opts = opts or {}
  local skills = {}

  for _, dir in ipairs(directories) do
    local found = scan_directory(dir, opts)
    for _, skill in ipairs(found) do
      if skills[skill.name] then
      else
        skills[skill.name] = skill
      end
    end
  end

  return skills
end

---Discover skills using default directories
---@param opts? SkillDiscoveryOpts
---@return table<string, SkillMeta>
function M.discover_default(opts)
  return M.discover(M.default_directories(), opts)
end

---Scan from current directory up to git root for skills
---@param opts? SkillDiscoveryOpts
---@return table<string, SkillMeta>
function M.discover_to_git_root(opts)
  opts = opts or {}
  local skills = {}
  local cwd = vim.fn.getcwd()
  local git_root = find_git_root(cwd)

  if not git_root then return M.discover_default(opts) end

  local dir = cwd
  while dir and #dir >= #git_root do
    local skill_dirs = {
      vim.fs.joinpath(dir, ".codecompanion", "skills"),
      vim.fs.joinpath(dir, ".claude", "skills"),
      vim.fs.joinpath(dir, ".opencode", "skills"),
    }

    for _, skill_dir in ipairs(skill_dirs) do
      if is_dir(skill_dir) then
        local found = scan_directory(skill_dir, opts)
        for _, skill in ipairs(found) do
          if not skills[skill.name] then skills[skill.name] = skill end
        end
      end
    end

    if dir == git_root then break end
    dir = vim.fn.fnamemodify(dir, ":h")
  end

  local home = vim.fn.expand("~")
  local user_dirs = {
    vim.fs.joinpath(home, ".config", "codecompanion", "skills"),
    vim.fs.joinpath(home, ".claude", "skills"),
    vim.fs.joinpath(home, ".config", "opencode", "skills"),
  }

  for _, user_dir in ipairs(user_dirs) do
    if is_dir(user_dir) then
      local found = scan_directory(user_dir, opts)
      for _, skill in ipairs(found) do
        if not skills[skill.name] then skills[skill.name] = skill end
      end
    end
  end

  return skills
end

return M
