-- List directory tool for agents to explore directory structure
-- Provides a safe way to list files without cmd_runner access
-- Uses vim.fs for cross-platform compatibility

local log = require("codecompanion.utils.log")

local fmt = string.format

---List contents of a directory
---@param args { path: string, depth?: number, pattern?: string }
---@param opts? table
---@return { status: "success"|"error", data: string|string[] }
local function list_dir(args, opts)
  opts = opts or {}
  local path = args.path
  local depth = args.depth or 1
  local pattern = args.pattern

  if not path or path == "" then path = "." end

  local cwd = vim.fn.getcwd()
  local full_path

  if vim.fn.fnamemodify(path, ":p") == path then
    full_path = path
  else
    full_path = vim.fs.joinpath(cwd, path)
  end
  full_path = vim.fs.normalize(full_path)

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
    ---@param self CodeCompanion.Tool.ListDirectory
    ---@param args table The arguments from the LLM's tool call
    ---@param input? any The output from the previous function call
    ---@return { status: "success"|"error", data: string|string[] }
    function(self, args, input)
      return list_dir(args, self.tool.opts)
    end,
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
            description = "Optional Lua pattern to filter results. Only entries matching this pattern will be shown. Example: '%.lua$' for Lua files, '^test' for entries starting with 'test'.",
          },
        },
        required = { "path", "depth", "pattern" },
        additionalProperties = false,
      },
    },
  },
  handlers = {
    ---@param tools CodeCompanion.Tools The tool object
    ---@return nil
    on_exit = function(tools)
      log:trace("[List Directory Tool] on_exit handler executed")
    end,
  },
  output = {
    ---Returns the command that will be executed
    ---@param self CodeCompanion.Tool.ListDirectory
    ---@param args { tools: CodeCompanion.Tools }
    ---@return string
    cmd_string = function(self, args)
      local depth_info = self.args.depth and fmt(" (depth: %d)", self.args.depth) or ""
      local pattern_info = self.args.pattern and fmt(" [pattern: %s]", self.args.pattern) or ""
      return fmt("ls %s%s%s", self.args.path or ".", depth_info, pattern_info)
    end,

    ---@param self CodeCompanion.Tool.ListDirectory
    ---@param tools CodeCompanion.Tools
    ---@param cmd table The command that was executed
    ---@param stdout table The output from the command
    success = function(self, tools, cmd, stdout)
      local chat = tools.chat
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
    end,

    ---@param self CodeCompanion.Tool.ListDirectory
    ---@param tools CodeCompanion.Tools
    ---@param cmd table
    ---@param stderr table The error output from the command
    error = function(self, tools, cmd, stderr)
      local chat = tools.chat
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
    end,
  },
}
