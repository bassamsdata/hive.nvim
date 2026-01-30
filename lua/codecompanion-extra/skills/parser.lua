-- SKILL.md parser for Agent Skills
-- Parses YAML frontmatter to extract skill metadata (name, description)

local M = {}

local uv = vim.uv

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

---@class SkillMeta
---@field name string Skill name (required)
---@field description string Skill description (required)
---@field path string Full path to skill directory
---@field skill_file string Full path to SKILL.md
---@field license? string Optional license
---@field compatibility? string Optional compatibility info
---@field metadata? table Optional arbitrary metadata

---Parse SKILL.md file and extract metadata only (name, description)
---@param skill_md_path string Path to SKILL.md file
---@return SkillMeta|nil
function M.parse_meta(skill_md_path)
  local content = read_file(skill_md_path)
  if not content then return nil end

  local frontmatter, _ = parse_frontmatter(content)
  if not frontmatter then return nil end

  if not frontmatter.name or not frontmatter.description then return nil end

  local skill_dir = vim.fn.fnamemodify(skill_md_path, ":h")

  return {
    name = vim.trim(frontmatter.name),
    description = vim.trim(frontmatter.description),
    path = skill_dir,
    skill_file = skill_md_path,
    license = frontmatter.license,
    compatibility = frontmatter.compatibility,
    metadata = frontmatter.metadata,
  }
end

---Read full SKILL.md content for injection into context
---@param skill_md_path string Path to SKILL.md file
---@return string|nil content
function M.read_content(skill_md_path)
  return read_file(skill_md_path)
end

---List files in a skill directory (for informing LLM of available resources)
---@param skill_dir string Path to skill directory
---@return { scripts: string[], references: string[], assets: string[] }
function M.list_resources(skill_dir)
  local resources = {
    scripts = {},
    references = {},
    assets = {},
  }

  local subdirs = { "scripts", "references", "assets" }

  for _, subdir in ipairs(subdirs) do
    local dir_path = vim.fs.joinpath(skill_dir, subdir)
    local stat = uv.fs_stat(dir_path)

    if stat and stat.type == "directory" then
      local handle = uv.fs_scandir(dir_path)
      if handle then
        while true do
          local name, ftype = uv.fs_scandir_next(handle)
          if not name then break end
          if ftype == "file" or ftype == "link" then table.insert(resources[subdir], vim.fs.joinpath(subdir, name)) end
        end
      end
    end
  end

  return resources
end

---Validate skill name according to spec
---@param name string
---@return boolean valid
---@return string|nil error_message
function M.validate_name(name)
  if not name or name == "" then return false, "Name is required" end

  if #name > 64 then return false, "Name must be 64 characters or less" end

  if not name:match("^[a-z0-9%-]+$") then
    return false, "Name must contain only lowercase letters, numbers, and hyphens"
  end

  if name:match("^%-") or name:match("%-$") then return false, "Name must not start or end with a hyphen" end

  if name:match("%-%-") then return false, "Name must not contain consecutive hyphens" end

  return true, nil
end

---Validate skill description according to spec
---@param description string
---@return boolean valid
---@return string|nil error_message
function M.validate_description(description)
  if not description or description == "" then return false, "Description is required" end

  if #description > 1024 then return false, "Description must be 1024 characters or less" end

  return true, nil
end

---Validate a skill's metadata
---@param meta SkillMeta
---@return boolean valid
---@return string[] errors
function M.validate(meta)
  local errors = {}

  local name_valid, name_err = M.validate_name(meta.name)
  if not name_valid then table.insert(errors, name_err) end

  local desc_valid, desc_err = M.validate_description(meta.description)
  if not desc_valid then table.insert(errors, desc_err) end

  return #errors == 0, errors
end

return M
