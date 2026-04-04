local log = require("codecompanion.utils.log")
local compat = require("codecompanion-extra.tools.compat")

local fmt = string.format

---Normalize a directory parameter from LLM input.
---Handles null, nil, empty, whitespace-only strings — all resolve to cwd.
---@param dir any
---@return string
local function _resolve_directory(dir)
  if dir == nil or dir == vim.NIL then return vim.fn.getcwd() end
  if type(dir) ~= "string" then return vim.fn.getcwd() end

  local trimmed = dir:match("^%s*(.-)%s*$")
  if trimmed == "" or trimmed == "null" or trimmed == "nil" then return vim.fn.getcwd() end

  return vim.fs.normalize(trimmed)
end

---@param action { query: string, is_regexp?: boolean, include_pattern?: string, directory?: string }
---@param opts? table
---@return { status: "success"|"error", data: string|table }
local function _grep_search(action, opts)
  opts = opts or {}
  local query = action.query

  if not query or query == "" then
    return { status = "error", data = "Query parameter is required and cannot be empty" }
  end

  if vim.fn.executable("rg") ~= 1 then
    return { status = "error", data = "ripgrep (rg) is not installed or not in PATH" }
  end

  local search_dir = _resolve_directory(action.directory)

  local stat = vim.uv.fs_stat(search_dir)
  if not stat or stat.type ~= "directory" then
    return { status = "error", data = fmt("Directory does not exist: %s", search_dir) }
  end

  local max_results = opts.max_results or 100
  local is_regexp = action.is_regexp or false
  local respect_gitignore = opts.respect_gitignore
  if respect_gitignore == nil then respect_gitignore = true end

  local cmd = { "rg", "--json", "--line-number", "--no-heading", "--with-filename" }

  if not is_regexp then table.insert(cmd, "--fixed-strings") end
  table.insert(cmd, "--ignore-case")
  if not respect_gitignore then table.insert(cmd, "--no-ignore") end

  if action.include_pattern and action.include_pattern ~= "" then
    table.insert(cmd, "--glob")
    table.insert(cmd, action.include_pattern)
  end

  table.insert(cmd, "--max-count")
  table.insert(cmd, tostring(math.min(max_results, 50)))

  table.insert(cmd, "-e")
  table.insert(cmd, query)
  table.insert(cmd, search_dir)

  log:debug("[Grep Search Tool] Running command: %s", table.concat(cmd, " "))

  local result = vim.system(cmd, { text = true, timeout = 30000 }):wait()

  if result.code ~= 0 then
    if result.code == 1 then return { status = "success", data = "No matches found for the query" } end

    local error_msg = result.stderr or "Unknown error"
    if result.code == 2 then
      log:warn("[Grep Search Tool] Invalid arguments or regex: %s", error_msg)
      return {
        status = "error",
        data = fmt("Invalid search pattern or arguments: %s", error_msg:match("^[^\n]*") or "Unknown error"),
      }
    end

    log:error("[Grep Search Tool] Command failed with code %d: %s", result.code, error_msg)
    return { status = "error", data = fmt("Search failed: %s", error_msg:match("^[^\n]*") or "Unknown error") }
  end

  local output = result.stdout or ""
  if output == "" then return { status = "success", data = "No matches found for the query" } end

  local matches = {}
  local count = 0

  for line in output:gmatch("[^\n]+") do
    if count >= max_results then break end

    local ok, json_data = pcall(vim.json.decode, line)
    if ok and json_data.type == "match" then
      local file_path = json_data.data.path.text
      local line_number = json_data.data.line_number
      table.insert(matches, fmt("%s:%d", file_path, line_number))
      count = count + 1
    end
  end

  if #matches == 0 then return { status = "success", data = "No matches found for the query" } end

  return { status = "success", data = matches }
end

---@class CodeCompanion.Tool.GrepSearch: CodeCompanion.Tools.Tool
return {
  name = "grep_search",
  cmds = {
    compat.cmds(function(tools, args, opts)
      return _grep_search(args, tools.tool and tools.tool.opts)
    end),
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "grep_search",
      description = "Do a text search in the workspace. Use this tool when you know the exact string you're searching for.",
      parameters = {
        type = "object",
        properties = {
          query = {
            type = "string",
            description = "The pattern to search for in files in the workspace. Can be a regex or plain text pattern",
          },
          is_regexp = {
            type = "boolean",
            description = "Whether the pattern is a regex. False by default.",
          },
          include_pattern = {
            type = "string",
            description = "Search files matching this glob pattern. Will be applied to the relative path of files within the workspace.",
          },
          directory = {
            type = "string",
            description = 'Absolute path of the directory to search in. Leave as empty string "" to search the current working directory. If not provided or empty, defaults to cwd.',
          },
        },
        required = { "query" },
        additionalProperties = false,
      },
    },
  },
  handlers = {
    on_exit = compat.handler_on_exit(function(self, meta)
      log:trace("[Grep Search Tool] on_exit handler executed")
    end),
  },
  output = {
    cmd_string = compat.output_cmd_string(function(self, meta)
      return self.args.query or ""
    end),

    prompt = compat.output_prompt(function(self, meta)
      return fmt("Grep search for `%s`?", self.args.query)
    end),

    success = compat.output_success(function(self, stdout, meta)
      local chat = meta.tools.chat
      local query = self.args.query
      local data = stdout[1]

      local llm_output = [[<grepSearchTool>%s

NOTE:
- The output format is {filepath}:{line_number}.
- For example:
/Users/user/project/lua/codecompanion/interactions/chat/tools/init.lua:335
Refers to line 335 of the init.lua file</grepSearchTool>]]
      local output = vim.iter(stdout):flatten():join("\n")

      if type(data) == "table" then
        local results = #data
        local results_msg = fmt("Searched text for `%s`, %d results\n```\n%s\n```", query, results, output)
        chat:add_tool_output(self, fmt(llm_output, results_msg), results_msg)
      else
        local no_results_msg = fmt("Searched text for `%s`, no results", query)
        chat:add_tool_output(self, fmt(llm_output, no_results_msg), no_results_msg)
      end
    end),

    error = compat.output_error(function(self, stderr, meta)
      local chat = meta.tools.chat
      local query = self.args.query
      local errors = vim.iter(stderr):flatten():join("\n")
      log:debug("[Grep Search Tool] Error output: %s", stderr)

      local error_output = fmt("Searched text for `%s`, error:\n```\n%s\n```", query, errors)
      chat:add_tool_output(self, error_output)
    end),

    rejected = compat.output_rejected(function(self, meta)
      local helpers = require("codecompanion.interactions.chat.tools.builtin.helpers")
      local message = "The user rejected the grep search tool"
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
