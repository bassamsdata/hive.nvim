--[[
===============================================================================
    File:       codecompanion-extra/tools/get_diagnostics.lua
    Author:     Bassam Data (https://github.com/bassamsdata)
-------------------------------------------------------------------------------
    Description:
      Retrieves diagnostics (errors, warnings, info, hints) from a file for the LLM to analyze and fix.
      Uses vim.diagnostic API to fetch LSP diagnostics and other diagnostic sources.
      Uses textDocument/didOpen notification to trigger LSP diagnostics without opening a buffer.

      Strategy (inspired by github.com/bassamsdata/namu.nvim):
        1. Send didOpen to LSP with file content
        2. Poll vim.diagnostic.get() multiple times with delays
        3. Wait for diagnostic count to stabilize (same count N times in a row)
        4. No reliance on events (DiagnosticChanged is unreliable for virtual docs)
-------------------------------------------------------------------------------
    Attribution:
      If you use or distribute this code, please credit:
      Bassam Data (https://github.com/bassamsdata)
===============================================================================
--]]

---BUG: I'm getting some false-positive from solow LSPs or big files.
---I think we need to do something, maybe make the first time and second time we retirieve
---a bit longer.

local Path = require("plenary.path")
local helpers = require("codecompanion.utils.files")
local log = require("codecompanion.utils.log")
local tool_helpers = require("codecompanion.interactions.chat.tools.builtin.helpers")

local api = vim.api
local uv = vim.uv
local fmt = string.format

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local DEBUG_ENABLED = true
local LOG_FILE_PATH = vim.fn.stdpath("cache") .. "/get_diagnostics_debug.log"

-- Polling configuration (namu-style)
local CONFIG = {
  -- Initial delay before first poll (let LSP start processing)
  initial_delay_ms = 300,
  -- Delay between polls
  poll_delay_ms = 300,
  -- Maximum number of poll attempts
  max_polls = 12,
  -- How many consecutive stable counts before we stop (1 = two polls with same count)
  stable_count_threshold = 1,
  -- Maximum total wait time (safety net)
  max_total_ms = 6000,
}

--------------------------------------------------------------------------------
-- Async File Logger
--------------------------------------------------------------------------------

local Logger = {}
Logger.__index = Logger

function Logger.new(filepath)
  local self = setmetatable({}, Logger)
  self.filepath = filepath
  self.queue = {}
  self.writing = false
  return self
end

function Logger:log(level, message, ...)
  if not DEBUG_ENABLED then return end

  local ok, formatted = pcall(fmt, message, ...)
  if not ok then formatted = message .. " (fmt error)" end

  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local ms = math.floor((uv.hrtime() / 1e6) % 1000)
  local entry = fmt("[%s.%03d] [%-5s] %s\n", timestamp, ms, level, formatted)

  table.insert(self.queue, entry)
  self:_flush_async()
end

function Logger:debug(msg, ...)
  self:log("DEBUG", msg, ...)
end
function Logger:info(msg, ...)
  self:log("INFO", msg, ...)
end
function Logger:warn(msg, ...)
  self:log("WARN", msg, ...)
end
function Logger:error(msg, ...)
  self:log("ERROR", msg, ...)
end

function Logger:_flush_async()
  if self.writing or #self.queue == 0 then return end

  self.writing = true
  local entries = table.concat(self.queue)
  self.queue = {}

  uv.fs_open(self.filepath, "a", 438, function(err_open, fd)
    if err_open or not fd then
      self.writing = false
      return
    end

    uv.fs_write(fd, entries, -1, function(_)
      uv.fs_close(fd, function()
        self.writing = false
        if #self.queue > 0 then vim.schedule(function()
          self:_flush_async()
        end) end
      end)
    end)
  end)
end

local dlog = Logger.new(LOG_FILE_PATH)

--------------------------------------------------------------------------------
-- Severity Mappings
--------------------------------------------------------------------------------

local SEVERITY_NAMES = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARNING",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

local SEVERITY_MAP = {
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
  warn = vim.diagnostic.severity.WARN,
  info = vim.diagnostic.severity.INFO,
  hint = vim.diagnostic.severity.HINT,
  all = nil,
}

---Parse severity filter from arguments
---@param severity_arg string The severity argument from the LLM
---@return vim.diagnostic.SeverityFilter|nil
local function parse_severity_filter(severity_arg)
  if not severity_arg or severity_arg == "" or severity_arg:lower() == "all" then return nil end

  local severity_lower = severity_arg:lower()

  if SEVERITY_MAP[severity_lower] then return SEVERITY_MAP[severity_lower] end

  if severity_arg:find(",") then
    local severities = {}
    for sev in severity_arg:gmatch("([^,]+)") do
      local trimmed = vim.trim(sev):lower()
      if SEVERITY_MAP[trimmed] then table.insert(severities, SEVERITY_MAP[trimmed]) end
    end
    if #severities > 0 then return severities end
  end

  local min_match = severity_arg:match("^min:(%w+)$")
  if min_match and SEVERITY_MAP[min_match:lower()] then return { min = SEVERITY_MAP[min_match:lower()] } end

  return nil
end

---Format a single diagnostic for output
---@param diag vim.Diagnostic The diagnostic to format
---@param lines string[]|nil The file lines for context
---@return string
local function format_diagnostic(diag, lines)
  local severity_name = SEVERITY_NAMES[diag.severity] or "UNKNOWN"
  local source = diag.source and fmt(" [%s]", diag.source) or ""
  local code = diag.code and fmt(" (%s)", diag.code) or ""

  local line_num = diag.lnum + 1
  local end_line_num = (diag.end_lnum or diag.lnum) + 1
  local col = diag.col + 1
  local end_col = diag.end_col and (diag.end_col + 1) or col

  local location = line_num == end_line_num and fmt("Line %d, Col %d-%d", line_num, col, end_col)
    or fmt("Lines %d-%d", line_num, end_line_num)

  local result = fmt("- [%s]%s%s %s: %s", severity_name, source, code, location, diag.message)

  if lines and diag.lnum < #lines then
    local context_line = lines[line_num]
    if context_line then
      local trimmed = context_line:gsub("^%s+", ""):gsub("%s+$", "")
      if #trimmed > 0 then result = result .. fmt("\n  Code: `%s`", trimmed) end
    end
  end

  return result
end

--------------------------------------------------------------------------------
-- LSP Client Helpers
--------------------------------------------------------------------------------

---Ensure LSP client compatibility (handle old vs new style clients)
---@param client vim.lsp.Client
---@return vim.lsp.Client
local function ensure_client_compatibility(client)
  if getmetatable(client) and getmetatable(client).request then return client end
  if client._wrapped then return client end
  local wrapped = { _wrapped = true }
  return setmetatable(wrapped, {
    __index = function(_, key)
      if key == "supports_method" then
        return function(_, method)
          return client:supports_method(method)
        end
      end
      if key == "notify" then
        return function(_, ...)
          return client.notify(...)
        end
      end
      return client[key]
    end,
  })
end

---Check if client supports text document sync
---@param client vim.lsp.Client
---@return boolean
local function client_supports_sync(client)
  local sync = vim.tbl_get(client.server_capabilities, "textDocumentSync")
  if type(sync) == "table" then return sync.openClose == true end
  return sync == 1 or sync == 2
end

---Notify LSP clients about a file to trigger diagnostics
---@param path string The file path (absolute)
---@param content string The file content
---@param filetype string The file type
---@return boolean success Whether any client was notified
---@return string[] notified_names Names of notified clients
local function notify_lsp_about_file(path, content, filetype)
  local clients = vim.lsp.get_clients()
  local notified_names = {}

  dlog:debug("notify_lsp_about_file: path=%s, filetype=%s, clients=%d", path, filetype, #clients)

  for _, client in ipairs(clients) do
    client = ensure_client_compatibility(client)

    local has_sync = client_supports_sync(client)
    local filetypes = client.config and client.config.filetypes
    local handles_filetype = filetypes and vim.tbl_contains(filetypes, filetype)

    dlog:debug("  %s: sync=%s, handles_ft=%s", client.name, tostring(has_sync), tostring(handles_filetype))

    if has_sync and handles_filetype then
      local uri = vim.uri_from_fname(path)
      client:notify("textDocument/didOpen", {
        textDocument = {
          uri = uri,
          version = 0,
          text = content,
          languageId = filetype,
        },
      })
      table.insert(notified_names, client.name)
      dlog:info("  -> didOpen sent to %s", client.name)
    end
  end

  return #notified_names > 0, notified_names
end

---Close the virtual document in LSP clients
---@param path string The file path (absolute)
local function close_lsp_document(path)
  local uri = vim.uri_from_fname(path)
  dlog:debug("close_lsp_document: %s", path)

  for _, client in ipairs(vim.lsp.get_clients()) do
    client = ensure_client_compatibility(client)
    if client_supports_sync(client) then
      pcall(function()
        client:notify("textDocument/didClose", {
          textDocument = { uri = uri },
        })
      end)
    end
  end
end

--------------------------------------------------------------------------------
-- Diagnostic Retrieval with Polling (namu-style)
--------------------------------------------------------------------------------

---Get diagnostics for a specific file path from global diagnostic store
---@param abs_path string Absolute file path
---@param opts table? Diagnostic filter options
---@return vim.Diagnostic[]
local function get_file_diagnostics(abs_path, opts)
  local all_diags = vim.diagnostic.get(nil, opts)
  local file_diags = {}

  for _, d in ipairs(all_diags) do
    if d.bufnr then
      local buf_name = api.nvim_buf_get_name(d.bufnr)
      if buf_name == abs_path then table.insert(file_diags, d) end
    end
  end

  return file_diags
end

---Poll for diagnostics with stability detection (namu-style)
---@param abs_path string Absolute file path
---@param diag_opts table? Diagnostic filter options
---@param callback fun(diagnostics: vim.Diagnostic[])
local function poll_for_diagnostics(abs_path, diag_opts, callback)
  local start_time = uv.hrtime()
  local poll_count = 0
  local last_count = -1
  local stable_count = 0
  local last_diagnostics = {}

  dlog:info("=== poll_for_diagnostics START ===")
  dlog:info("path=%s, max_polls=%d, stable_threshold=%d", abs_path, CONFIG.max_polls, CONFIG.stable_count_threshold)

  local function do_poll()
    poll_count = poll_count + 1
    local elapsed = (uv.hrtime() - start_time) / 1e6

    -- Safety: max time exceeded
    if elapsed > CONFIG.max_total_ms then
      dlog:warn("Max time exceeded (%.0fms), returning current results", elapsed)
      dlog:info("=== poll_for_diagnostics END (timeout) ===")
      callback(last_diagnostics)
      return
    end

    -- Get current diagnostics
    local diags = get_file_diagnostics(abs_path, diag_opts)
    local current_count = #diags

    -- Check stability (increment BEFORE logging and checking)
    if current_count == last_count then
      stable_count = stable_count + 1
    else
      stable_count = 0
    end

    dlog:debug(
      "Poll %d: count=%d, last=%d, stable=%d, elapsed=%.0fms",
      poll_count,
      current_count,
      last_count,
      stable_count,
      elapsed
    )

    last_count = current_count
    last_diagnostics = diags

    -- Determine if we should stop
    local should_stop = false
    local stop_reason = ""

    if poll_count >= CONFIG.max_polls then
      should_stop = true
      stop_reason = fmt("max_polls reached (%d)", CONFIG.max_polls)
    elseif stable_count >= CONFIG.stable_count_threshold and current_count > 0 then
      should_stop = true
      stop_reason = fmt("stable with %d diagnostics (stable_count=%d)", current_count, stable_count)
    elseif stable_count >= CONFIG.stable_count_threshold + 1 and current_count == 0 then
      -- Allow extra poll for zero case (LSP might be slow)
      should_stop = true
      stop_reason = "stable at 0 diagnostics"
    end

    if should_stop then
      dlog:info("Stopping: %s", stop_reason)
      dlog:info("Final: %d diagnostics after %d polls, %.0fms", current_count, poll_count, elapsed)
      dlog:info("=== poll_for_diagnostics END ===")
      callback(last_diagnostics)
      return
    end

    -- Schedule next poll
    vim.defer_fn(do_poll, CONFIG.poll_delay_ms)
  end

  -- Start polling after initial delay
  dlog:info("Starting poll after %dms initial delay", CONFIG.initial_delay_ms)
  vim.defer_fn(do_poll, CONFIG.initial_delay_ms)
end

--------------------------------------------------------------------------------
-- Main Entry Point (Async)
--------------------------------------------------------------------------------

---Format diagnostics result into output string
---@param diagnostics vim.Diagnostic[]
---@param path string
---@param lines string[]
---@param severity_arg string|nil
---@return {status: "success"|"error", data: string}
local function format_diagnostics_result(diagnostics, path, lines, severity_arg)
  if #diagnostics == 0 then
    local severity_msg = severity_arg and severity_arg ~= "all" and fmt(" with severity '%s'", severity_arg) or ""
    return {
      status = "success",
      data = fmt("No diagnostics found in `%s` %s(no diagnostics)", path, severity_msg),
    }
  end

  -- Sort by severity then line
  table.sort(diagnostics, function(a, b)
    if a.severity ~= b.severity then return a.severity < b.severity end
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    return (a.col or 0) < (b.col or 0)
  end)

  -- Count by severity
  local counts = {}
  for _, diag in ipairs(diagnostics) do
    local sev = SEVERITY_NAMES[diag.severity] or "UNKNOWN"
    counts[sev] = (counts[sev] or 0) + 1
  end

  -- Build summary
  local summary_parts = {}
  for _, sev in ipairs({ "ERROR", "WARNING", "INFO", "HINT" }) do
    if counts[sev] then
      table.insert(summary_parts, fmt("%d %s%s", counts[sev], sev:lower(), counts[sev] > 1 and "s" or ""))
    end
  end
  local summary = table.concat(summary_parts, ", ")

  -- Format output
  local output = {
    fmt("Diagnostics for `%s` (%s):", path, summary),
    "",
  }

  for _, diag in ipairs(diagnostics) do
    table.insert(output, format_diagnostic(diag, lines))
  end

  table.insert(output, "")
  table.insert(output, fmt("File type: %s", vim.fn.fnamemodify(path, ":e")))

  return {
    status = "success",
    data = table.concat(output, "\n"),
  }
end

---Get diagnostics for a file (async version)
---@param action {filepath: string, severity: string}
---@param callback fun(result: {status: "success"|"error", data: string})
local function get_diagnostics_async(action, callback)
  dlog:info("")
  dlog:info("========================================")
  dlog:info("get_diagnostics_async: filepath=%s, severity=%s", action.filepath, action.severity or "all")
  dlog:info("========================================")

  local path = helpers.validate_and_normalize_path(action.filepath)
  local abs_path = vim.fn.fnamemodify(path, ":p")
  local p = Path:new(abs_path)

  if not p:exists() or not p:is_file() then
    dlog:error("File not found: %s", abs_path)
    callback({
      status = "error",
      data = fmt("Error: File `%s` does not exist or is not a file", path),
    })
    return
  end

  -- Check if buffer is already loaded
  local bufnr = vim.fn.bufnr(abs_path)
  local buffer_loaded = bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr)

  dlog:info("Buffer: bufnr=%d, loaded=%s", bufnr, tostring(buffer_loaded))

  -- Read file content
  local content = p:read()
  local lines = vim.split(content, "\n", { plain = true })

  -- Determine filetype
  local filetype = vim.filetype.match({ filename = abs_path, contents = lines })
  dlog:info("Filetype: %s", filetype or "unknown")

  -- Log LSP clients
  local all_clients = vim.lsp.get_clients()
  dlog:info("LSP clients: %d", #all_clients)
  for _, c in ipairs(all_clients) do
    local ft = c.config and c.config.filetypes and table.concat(c.config.filetypes, ",") or "?"
    dlog:debug("  %s (id=%d): filetypes=%s", c.name, c.id, ft)
  end

  -- Parse severity filter
  local severity_filter = parse_severity_filter(action.severity)
  local diag_opts = {}
  if severity_filter then diag_opts.severity = severity_filter end

  if buffer_loaded then
    -- Buffer already loaded - get diagnostics directly (sync path)
    dlog:info("Buffer loaded, getting diagnostics directly")
    local diagnostics = vim.diagnostic.get(bufnr, diag_opts)
    dlog:info("Got %d diagnostics from buffer", #diagnostics)
    callback(format_diagnostics_result(diagnostics, path, lines, action.severity))
    return
  end

  -- Send didOpen and poll for diagnostics (async path)
  local notified, notified_names = notify_lsp_about_file(abs_path, content, filetype or "")

  if not notified then
    dlog:warn("No LSP clients notified, checking existing diagnostics")
    local diagnostics = get_file_diagnostics(abs_path, diag_opts)
    callback(format_diagnostics_result(diagnostics, path, lines, action.severity))
    return
  end

  dlog:info("Notified LSPs: %s", table.concat(notified_names, ", "))

  -- Async polling
  poll_for_diagnostics(abs_path, diag_opts, function(diagnostics)
    -- Cleanup virtual document
    close_lsp_document(abs_path)
    dlog:info("Final result: %d diagnostics", #diagnostics)
    callback(format_diagnostics_result(diagnostics, path, lines, action.severity))
  end)
end

--------------------------------------------------------------------------------
-- Tool Definition
--------------------------------------------------------------------------------

---@class CodeCompanion.Tool.GetDiagnostics: CodeCompanion.Tools.Tool
return {
  name = "get_diagnostics",
  cmds = {
    ---Execute the diagnostics retrieval (async)
    ---When cb is provided, CodeCompanion treats this as async and waits for cb() to be called
    ---@param _self CodeCompanion.Tool.GetDiagnostics
    ---@param args table
    ---@param _input? any
    ---@param cb? fun(result: {status: "success"|"error", data: string}) Async callback
    function(_self, args, _input, cb)
      if cb then
        -- Async mode: use callback
        get_diagnostics_async(args, cb)
      else
        -- Sync fallback (shouldn't happen with modern CodeCompanion)
        dlog:warn("Running in sync mode (no callback provided)")
        local result = nil
        local done = false
        get_diagnostics_async(args, function(r)
          result = r
          done = true
        end)
        vim.wait(CONFIG.max_total_ms + 1000, function()
          return done
        end, 50)
        return result or { status = "error", data = "Timeout waiting for diagnostics" }
      end
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "get_diagnostics",
      description = [[Retrieve diagnostics (errors, warnings, info, hints) from a file.

Use this tool to:
1. Validate changes after using insert_edit_into_file to ensure no syntax issues or regressions were introduced.
2. Check for errors or warnings in a file before making edits.
3. Identify what problems need to be fixed in a codebase.
4. Get specific diagnostic details including line numbers, severity, and messages.

The diagnostics come from LSP servers and other diagnostic sources configured in Neovim.
Results are sorted by severity (errors first) then by line number.]],
      parameters = {
        type = "object",
        properties = {
          filepath = {
            type = "string",
            description = "The relative path to the file to get diagnostics from, including its filename and extension.",
          },
          severity = {
            type = "string",
            description = [[Severity filter. Possible values:
- "all": Return all diagnostics (default)
- "error": Only errors
- "warning" or "warn": Only warnings
- "info": Only info messages
- "hint": Only hints
- "error,warning": Multiple severities (comma-separated)
- "min:warning": Minimum severity (warning and above, i.e., warning + error)]],
          },
        },
        required = { "filepath", "severity" },
        additionalProperties = false,
      },
    },
  },

  opts = {
    show_output_in_chat = false,
  },
  handlers = {
    on_exit = function(_tools)
      log:trace("[Get Diagnostics Tool] on_exit handler executed")
    end,
  },
  output = {
    prompt = function(self, _tools)
      local args = self.args
      local filepath = vim.fn.fnamemodify(args.filepath, ":.")
      local severity_info = args.severity and args.severity ~= "all" and fmt(" (severity: %s)", args.severity) or ""
      return fmt("Get diagnostics from %s%s?", filepath, severity_info)
    end,

    success = function(self, tools, _cmd, stdout)
      local chat = tools.chat
      local llm_output = vim.iter(stdout):flatten():join("\n")
      local filepath = vim.fn.fnamemodify(self.args.filepath, ":.")

      local first_line = llm_output:match("^[^\n]+") or ""
      local summary = first_line:match("%((.-)%)") or "retrieved"

      local user_output
      if self.opts and self.opts.show_output_in_chat then
        user_output = fmt("Retrieved diagnostics from `%s` (%s)\n```\n%s\n```", filepath, summary, llm_output)
      else
        user_output = fmt("Retrieved diagnostics from `%s` (%s)", filepath, summary)
      end

      chat:add_tool_output(self, llm_output, user_output)
    end,

    error = function(self, tools, _cmd, stderr)
      local chat = tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      log:debug("[Get Diagnostics Tool] Error output: %s", stderr)
      chat:add_tool_output(self, errors)
    end,

    rejected = function(self, tools, cmd, opts)
      local message = "The user rejected the get diagnostics tool"
      opts = vim.tbl_extend("force", { message = message }, opts or {})
      tool_helpers.rejected(self, tools, cmd, opts)
    end,
  },
}
