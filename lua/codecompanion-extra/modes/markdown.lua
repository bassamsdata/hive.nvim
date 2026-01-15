-- Markdown Mode Loader for codecompanion-extra
-- Loads mode definitions from markdown files with YAML frontmatter
-- Functions here use internal codecompanion functions for YAML handling.
-- Some functions are partially copied and simplified from codecompanion.nvim.
-- credit to https://github.com/olimorris/codecompanion.nvim
--
-- File format:
-- ---
-- name: plan
-- description: Research and analyze before coding
-- tools:
--   - read_file
--   - grep_search
--   - file_search
-- opts:
--   include_default_system_prompt: true
--   include_tools_system_prompt: true
--   auto_submit_errors: false
--   auto_submit_success: false
-- ---
--
-- # System Prompt
--
-- You are in PLAN mode...
-- (rest of markdown becomes the system_prompt)

local M = {}

local uv = vim.uv

---@class CodeCompanionExtra.MarkdownMode
---@field name string
---@field description? string
---@field tools? string[]
---@field system_prompt? string
---@field opts? CodeCompanionExtra.ModeOpts

---Check if a path is a directory
---@param path string
---@return boolean
local function is_dir(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "directory" or false
end

---Read file contents
---@param path string
---@return string|nil
local function read_file(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then return nil end

  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil
  end

  local content = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return content
end

---Normalize line endings
---@param content string
---@return string
local function normalize_content(content)
  return (content:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

---Parse YAML frontmatter from markdown content
---@param content string
---@return table|nil frontmatter
---@return string body
local function parse_frontmatter(content)
  content = normalize_content(content)

  local frontmatter_yaml, body = content:match("^%-%-%-\n(.-)\n%-%-%-\n(.*)$")
  if not frontmatter_yaml then return nil, content end

  local ok, yaml = pcall(require, "codecompanion.utils.yaml")
  if not ok then return nil, body end

  local parse_ok, frontmatter = pcall(yaml.decode, frontmatter_yaml)
  if not parse_ok or type(frontmatter) ~= "table" then return nil, body end

  return frontmatter, body
end

---Extract system prompt from markdown body
---@param body string|nil
---@return string|nil
local function extract_system_prompt(body)
  if not body or body == "" then return nil end

  local prompt = vim.trim(body)

  local without_header = prompt:gsub("^#[^\n]*\n", "")
  without_header = vim.trim(without_header)

  if without_header ~= "" then return without_header end

  return prompt ~= "" and prompt or nil
end

---Parse a single markdown file into a mode definition
---@param path string
---@return CodeCompanionExtra.MarkdownMode|nil
function M.parse_file(path)
  local content = read_file(path)
  if not content or content == "" then return nil end

  local frontmatter, body = parse_frontmatter(content)
  if not frontmatter then return nil end

  if not frontmatter.name then frontmatter.name = vim.fn.fnamemodify(path, ":t:r") end

  local mode = {
    name = frontmatter.name,
    description = frontmatter.description,
    tools = frontmatter.tools,
    opts = frontmatter.opts,
  }

  local system_prompt = extract_system_prompt(body)
  if system_prompt then mode.system_prompt = system_prompt end

  return mode
end

---Load all markdown modes from a directory
---@param dir string
---@return table<string, CodeCompanionExtra.MarkdownMode>
function M.load_from_dir(dir)
  local modes = {}

  dir = vim.fs.normalize(dir)

  if not is_dir(dir) then return modes end

  local handle = uv.fs_scandir(dir)
  if not handle then return modes end

  while true do
    local name, ftype = uv.fs_scandir_next(handle)
    if not name then break end

    if (ftype == "file" or ftype == "link") and name:match("%.md$") then
      local path = vim.fs.joinpath(dir, name)
      local ok, mode = pcall(M.parse_file, path)

      if ok and mode and mode.name then modes[mode.name] = mode end
    end
  end

  return modes
end

---Register modes from a directory with the modes module
---@param dir string
---@return number count Number of modes registered
function M.register_from_dir(dir)
  local loaded_modes = M.load_from_dir(dir)
  local count = 0

  local modes_module = require("codecompanion-extra.modes")

  for name, mode in pairs(loaded_modes) do
    modes_module.register(name, {
      description = mode.description,
      tools = mode.tools,
      system_prompt = mode.system_prompt,
      opts = mode.opts,
    })
    count = count + 1
  end

  return count
end

---Get default modes directory path
---@return string
function M.default_dir()
  return vim.fs.joinpath(vim.fn.stdpath("config"), "codecompanion", "modes")
end

---Load modes from default directory
---@return number count Number of modes registered
function M.load_default()
  return M.register_from_dir(M.default_dir())
end

return M
