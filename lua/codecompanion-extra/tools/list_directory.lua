-- List directory tool for agents to explore directory structure
-- Provides a safe way to list files without cmd_runner access
-- Uses vim.fs for cross-platform compatibility

local log = require("codecompanion.utils.log")
local compat = require("codecompanion-extra.tools.compat")

local fmt = string.format

---List contents of a directory
---@param args { path: string, depth?: number, pattern?: string, hidden?: boolean }
---@param opts? table
---@return { status: "success"|"error", data: string|string[] }
local function list_dir(args, opts)
  opts = opts or {}
  local path = args.path
  local depth = args.depth
  local pattern = args.pattern
  local show_hidden = args.hidden or false

  -- Handle string "null"/"nil" from LLM JSON, and empty string as "no value"
  if type(depth) == "string" and (depth == "nil" or depth == "null" or depth == "") then depth = nil end
  if type(pattern) == "string" and (pattern == "nil" or pattern == "null" or pattern == "") then pattern = nil end
  if type(show_hidden) == "string" and (show_hidden == "nil" or show_hidden == "null") then show_hidden = false end

  depth = depth or 1
  if not path or path == "" then path = "." end

  local full_path
  if path:sub(1, 1) == "/" or path:sub(1, 1) == "~" or path:match("^%a:") then
    full_path = vim.fs.normalize(path)
  else
    full_path = vim.fs.normalize(vim.fs.joinpath(vim.fn.getcwd(), path))
  end

  local stat = vim.uv.fs_stat(full_path)
  if not stat then return {
    status = "error",
    data = fmt("Path does not exist: %s", path),
  } end

  if stat.type ~= "directory" then
    return {
      status = "error",
      data = fmt("Path is not a directory: %s", path),
    }
  end

  local entries = {}
  local max_entries = opts.max_entries or 500

  local ok, iter_or_err = pcall(vim.fs.dir, full_path, { depth = depth })
  if not ok then return {
    status = "error",
    data = fmt("Failed to read directory: %s", iter_or_err),
  } end

  for name, type in iter_or_err do
    if not show_hidden and name:sub(1, 1) == "." then goto continue end

    if pattern then
      local match_ok, matches = pcall(function()
        return name:match(pattern)
      end)
      if not match_ok or not matches then goto continue end
    end

    local indicator = ""
    if type == "directory" then
      indicator = "/"
    elseif type == "link" then
      indicator = "@"
    end

    table.insert(entries, name .. indicator)

    if #entries >= max_entries then
      table.insert(entries, fmt("... (truncated, showing %d of more entries)", max_entries))
      break
    end

    ::continue::
  end

  if #entries == 0 then return {
    status = "success",
    data = fmt("Directory is empty: %s", path),
  } end

  -- Sort entries (directories first, then alphabetically)
  table.sort(entries, function(a, b)
    local a_is_dir = a:sub(-1) == "/"
    local b_is_dir = b:sub(-1) == "/"
    if a_is_dir and not b_is_dir then
      return true
    elseif not a_is_dir and b_is_dir then
      return false
    else
      return a < b
    end
  end)

  return {
    status = "success",
    data = entries,
  }
end

---@class CodeCompanion.Tool.ListDirectory: CodeCompanion.Tools.Tool
return {
  name = "list_directory",
  cmds = {
    ---Execute the list_directory command
    ---@param tools CodeCompanion.Tools
    ---@param args table
    ---@param opts table
    ---@return { status: "success"|"error", data: string|string[] }
    compat.cmds(function(tools, args, opts)
      return list_dir(args, tools.tool and tools.tool.opts)
    end),
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "list_directory",
      description = [[List the contents of a directory. Returns file and directory names with type indicators:
- Directories end with /
- Symbolic links end with @
- Regular files have no suffix

Use this to explore the project structure before reading or creating files.
For finding files by pattern across the codebase, prefer file_search or grep_search instead.]],
      parameters = {
        type = "object",
        properties = {
          path = {
            type = "string",
            description = "The directory path to list. Can be relative to the current working directory or absolute. Use '.' for the current directory.",
          },
          depth = {
            type = "number",
            description = "How deep to traverse into subdirectories. Default is 1 (only immediate contents). Use higher values to see nested structure, but be mindful of large directories.",
          },
          pattern = {
            type = "string",
            description = "Optional Lua pattern to filter results. Only entries matching this pattern will be shown. Example: '%.lua$' for Lua files, '^test' for entries starting with 'test'. Use empty string \"\" if you don't want to filter by pattern.",
          },
          hidden = {
            type = "boolean",
            description = "Whether to include hidden files and directories (those starting with '.'). Default is false. Set to true to see .git, .env, .gitignore, etc.",
          },
        },
        required = { "path", "depth", "pattern", "hidden" },
        additionalProperties = false,
      },
    },
  },
  handlers = {
    on_exit = compat.handler_on_exit(function(self, meta)
      log:trace("[List Directory Tool] on_exit handler executed")
    end),
  },
  output = {
    cmd_string = compat.output_cmd_string(function(self, meta)
      local depth_info = self.args.depth and fmt(" (depth: %d)", self.args.depth) or ""
      local pattern_info = self.args.pattern and fmt(" [pattern: %s]", self.args.pattern) or ""
      local hidden_info = self.args.hidden and " (including hidden)" or ""
      return fmt("ls %s%s%s%s", self.args.path or ".", depth_info, pattern_info, hidden_info)
    end),

    prompt = compat.output_prompt(function(self, meta)
      return fmt("List directory `%s`?", self.args.path or ".")
    end),

    success = compat.output_success(function(self, stdout, meta)
      local chat = meta.tools.chat
      local path = self.args.path or "."
      local data = stdout[1]

      local llm_output = "<listDirectoryTool>%s</listDirectoryTool>"

      if type(data) == "table" then
        -- Entries were found
        local count = #data
        local output = table.concat(data, "\n")
        local results_msg = fmt("Listed `%s`, %d entries:\n```\n%s\n```", path, count, output)
        chat:add_tool_output(self, fmt(llm_output, results_msg), results_msg)
      else
        -- Empty or message
        local msg = fmt("Listed `%s`: %s", path, data)
        chat:add_tool_output(self, fmt(llm_output, msg), msg)
      end
    end),

    error = compat.output_error(function(self, stderr, meta)
      local chat = meta.tools.chat
      local path = self.args.path or "."
      local errors = vim.iter(stderr):flatten():join("\n")
      log:debug("[List Directory Tool] Error output: %s", stderr)

      local error_output = fmt(
        [[Listed directory `%s`, error:

```txt
%s
```]],
        path,
        errors
      )
      chat:add_tool_output(self, error_output)
    end),

    rejected = compat.output_rejected(function(self, meta)
      local helpers = require("codecompanion.interactions.chat.tools.builtin.helpers")
      local message = "The user rejected listing the directory"
      if compat.is_new_api() then
        local opts = vim.tbl_extend("force", { message = message }, meta.opts or {})
        opts.tools = meta.tools
        helpers.rejected(self, opts)
      else
        local opts = vim.tbl_extend("force", { message = message }, meta.opts or {})
        helpers.rejected(self, meta.tools, meta.cmd, opts)
      end
    end),
  },
}
