local compat = require("codecompanion-extra.tools.compat")
local subagent_utils = require("codecompanion-extra.tools.subagent.utils")

local fmt = string.format
local uv = vim.uv
local safe_close_timer = subagent_utils.safe_close_timer
local SPINNER_FRAMES = subagent_utils.SPINNER_FRAMES

local DEFAULT_TIMEOUT_S = 60
local DEFAULT_SHOW_TIMER_AFTER_S = 5
local STATUS_UPDATE_INTERVAL_MS = subagent_utils.UPDATE_INTERVAL_MS

---Strip ANSI escape codes from a table of strings
---@param tbl string[]
---@return string[]
local function strip_ansi(tbl)
  for i, v in ipairs(tbl) do
    tbl[i] = v:gsub("\027%[[0-9;]*%a", "")
  end
  return tbl
end

---Build a shell command from args (matches codecompanion's os_utils pattern)
---@param cmd string The command string
---@return string[]
local function build_shell_command(cmd)
  local is_windows = vim.fn.has("win32") == 1
  return {
    is_windows and "cmd.exe" or "sh",
    is_windows and "/c" or "-c",
    cmd,
  }
end

---Check if a command matches any pattern in a list
---@param cmd string The command to check
---@param patterns string[] Glob-like patterns
---@return boolean
local function matches_any(cmd, patterns)
  if not patterns or #patterns == 0 then return false end
  if not cmd or cmd == "" then return false end
  local models = require("codecompanion-extra.tools.subagent.models")
  for _, glob in ipairs(patterns) do
    if type(glob) == "string" then
      local pattern = models.glob_to_pattern(glob)
      if cmd:match(pattern) then return true end
    end
  end
  return false
end

-- stylua: ignore start
local DEFAULT_DANGEROUS_PATTERNS = {
  -- Recursive deletion targeting critical paths
  "*rm -rf /*",
  "*rm -rf ~*",
  "*rm -rf .*",
  "*rm -rf $*",
  "*rm -fr /*",
  "*rm -fr ~*",
  "*rm -rf *",
  "*rm -r *",
  "*rm -f *",
  "*rm *",
  "*rmdir /s*",
  -- Fork bombs and infinite loops
  "*:(){ :|:&*",
  "*while true*do*done*",
  "*for(;;)*",
  -- Disk/filesystem destruction
  "*mkfs*",
  "*dd if=*of=/dev*",
  "*> /dev/sd*",
  "*> /dev/nvme*",
  "*wipefs*",
  -- Permission escalation on critical paths
  "*chmod -R 777 /*",
  "*chmod -R 777 ~*",
  "*chown -R *:* /*",
  -- Overwriting critical files
  "*> /etc/passwd*",
  "*> /etc/shadow*",
  "*> /etc/sudoers*",
  -- Credential exposure
  "*cat ~/.ssh/id_*",
  "*cat /etc/shadow*",
  -- Kernel/system destruction
  "*rm -rf /boot*",
  "*rm -rf /usr*",
  "*rm -rf /var*",
  "*rm -rf /etc*",
  -- Curl-to-shell (arbitrary remote code execution)
  "*curl *| bash*",
  "*curl *| sh*",
  "*wget *| bash*",
  "*wget *| sh*",
}
-- stylua: ignore end

---Get cmd_runner config merged with defaults
---@return { timeout: number, auto_allow_patterns: string[], always_confirm_patterns: string[], show_timer_after: number, show_spinner: boolean }
local function get_config()
  local ok, config_module = pcall(require, "codecompanion-extra.config")
  local tool_config = ok and config_module.get().tools and config_module.get().tools.cmd_runner or {}
  local opts = tool_config.opts or tool_config

  return {
    timeout = opts.timeout or DEFAULT_TIMEOUT_S,
    auto_allow_patterns = opts.auto_allow_patterns or {},
    always_confirm_patterns = vim.list_extend(
      vim.deepcopy(opts.always_confirm_patterns or {}),
      DEFAULT_DANGEROUS_PATTERNS
    ),
    show_timer_after = opts.show_timer_after or DEFAULT_SHOW_TIMER_AFTER_S,
    show_spinner = opts.show_spinner ~= false,
  }
end

---Remove an autocmd by ID
---@param autocmd_id number|nil
local function remove_autocmd(autocmd_id)
  if autocmd_id then pcall(vim.api.nvim_del_autocmd, autocmd_id) end
end

---Kill a process safely (cross-platform)
---@param proc vim.SystemObj|nil
local function kill_process(proc)
  if not proc then return end
  if vim.fn.has("win32") == 1 then
    pcall(function()
      vim.system({ "taskkill", "/F", "/T", "/PID", tostring(proc.pid) })
    end)
  else
    pcall(function()
      proc:kill("sigkill")
    end)
  end
end

---Get the OS name for the system prompt
---@return string
local function get_os_name()
  if vim.fn.has("win32") == 1 then return "Windows" end
  if vim.fn.has("macunix") == 1 then return "Mac" end
  if vim.fn.has("unix") == 1 then return "Unix" end
  return "Unknown"
end

---@class CodeCompanion.Tool.ExtraCmdRunner: CodeCompanion.Tools.Tool
return {
  name = "cmd_runner",
  cmds = {
    compat.cmds(function(tools, args, opts)
      local cmd_str = args.cmd
      local flag = args.flag
      local output_cb = opts.output_cb

      local config = get_config()
      local chat = tools.chat

      -- Per-invocation state (avoids singleton conflicts between chats)
      local process = nil
      local timer = nil
      local autocmd_id = nil
      local timed_out = false
      local cancelled = false
      local done = false
      local status_timer = nil
      local status_ns = nil
      local start_time = uv.hrtime()

      -- Hoist OS detection before entering vim.system callback (unsafe to call vim.fn there)
      local is_windows = vim.fn.has("win32") == 1
      local eol_pattern = is_windows and "\r?\n" or "\n"
      local chat_bufnr = chat and chat.bufnr or nil

      local function cleanup()
        safe_close_timer(timer)
        timer = nil
        safe_close_timer(status_timer)
        status_timer = nil
        if status_ns and chat_bufnr then
          local status = require("codecompanion-extra.tools.subagent.status")
          status.clear(chat_bufnr, status_ns)
        end
        remove_autocmd(autocmd_id)
        autocmd_id = nil
        process = nil
      end

      -- Once-guard: ensures output_cb fires exactly once regardless of race conditions
      local cb = vim.schedule_wrap(function(result)
        if done then return end
        done = true
        cleanup()
        if output_cb then output_cb(result) end
      end)

      -- TODO: my idea didn't work :(
      -- ChatStopped listener: pressing `q` in chat kills the running process
      if chat_bufnr then
        autocmd_id = vim.api.nvim_create_autocmd("User", {
          pattern = "CodeCompanionChatStopped",
          once = true,
          callback = function(event)
            local stopped_bufnr = event.data and event.data.bufnr
            if stopped_bufnr == chat_bufnr and process then
              cancelled = true
              local proc = process
              process = nil
              kill_process(proc)
              safe_close_timer(timer)
              timer = nil
            end
          end,
        })
      end

      local shell_cmd = build_shell_command(cmd_str)

      process = vim.system(shell_cmd, {}, function(out)
        if flag then
          vim.schedule(function()
            if chat and chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) and chat.tool_registry then
              chat.tool_registry.flags = chat.tool_registry.flags or {}
              chat.tool_registry.flags[flag] = (out.code == 0)
            end
          end)
        end

        if timed_out or cancelled then return end

        if out.code == 0 then
          cb({
            status = "success",
            data = strip_ansi(vim.split(out.stdout or "", eol_pattern, { trimempty = true })),
          })
        else
          local combined = {}
          if out.stderr and out.stderr ~= "" then
            vim.list_extend(combined, strip_ansi(vim.split(out.stderr, eol_pattern, { trimempty = true })))
          end
          if out.stdout and out.stdout ~= "" then
            vim.list_extend(combined, strip_ansi(vim.split(out.stdout, eol_pattern, { trimempty = true })))
          end
          cb({ status = "error", data = combined })
        end
      end)

      local timeout_s = config.timeout
      if timeout_s and timeout_s > 0 then
        timer = uv.new_timer()
        timer:start(timeout_s * 1000, 0, function()
          if process then
            timed_out = true
            local proc = process
            process = nil
            kill_process(proc)
            cb({
              status = "error",
              data = {
                fmt("Command `%s` timed out after %d seconds and was killed.", cmd_str, timeout_s),
                "Consider: increasing the timeout, breaking the command into smaller steps, or using a different approach.",
              },
            })
          end
        end)
      end

      local show_after_s = config.show_timer_after
      if chat_bufnr and config.show_spinner and show_after_s and show_after_s > 0 then
        local status = require("codecompanion-extra.tools.subagent.status")
        status_ns = vim.api.nvim_create_namespace("codecompanion_cmd_status_" .. chat_bufnr .. "_" .. start_time)
        local spinner_idx = 0

        status_timer = uv.new_timer()
        status_timer:start(
          show_after_s * 1000,
          STATUS_UPDATE_INTERVAL_MS,
          vim.schedule_wrap(function()
            if done then return end
            spinner_idx = (spinner_idx % #SPINNER_FRAMES) + 1
            local elapsed_ms = subagent_utils.get_elapsed_ms(start_time)
            local elapsed_str = subagent_utils.format_duration(elapsed_ms)
            local timeout_str = timeout_s and timeout_s > 0 and fmt(" (timeout: %ds)", timeout_s) or ""

            local text = fmt(
              "───── cmd_runner ─────\n%s Running `%s`  ·  󱎫 %s%s",
              SPINNER_FRAMES[spinner_idx],
              subagent_utils.truncate(cmd_str, 35),
              elapsed_str,
              timeout_str
            )

            status.render({ bufnr = chat_bufnr, ns_id = status_ns, text = text })
          end)
        )
      end
    end),
  },

  schema = {
    type = "function",
    ["function"] = {
      name = "cmd_runner",
      description = "Run shell commands on the user's system, sharing the output with the user before then sharing with you.",
      parameters = {
        type = "object",
        properties = {
          cmd = {
            type = "string",
            description = "The command to run, e.g. `pytest` or `make test`",
          },
          flag = {
            anyOf = {
              { type = "string" },
              { type = "null" },
            },
            description = 'If running tests, set to `"testing"`; null otherwise',
          },
        },
        required = {
          "cmd",
          "flag",
        },
        additionalProperties = false,
      },
      strict = true,
    },
  },

  system_prompt = fmt(
    [[# Command Runner Tool (`cmd_runner`)

## CONTEXT
- You have access to a command runner tool running within CodeCompanion, in Neovim.
- You can use it to run shell commands on the user's system.
- You may be asked to run a specific command or to determine the appropriate command to fulfil the user's request.
- All tool executions take place in the current working directory %s.

## OBJECTIVE
- Follow the tool's schema.
- Respond with a single command, per tool execution.

## RESPONSE
- Only invoke this tool when the user specifically asks.
- If the user asks you to run a specific command, do so to the letter, paying great attention.
- Use this tool strictly for command execution; but file operations must NOT be executed in this tool unless the user explicitly approves.
- To run multiple commands, you will need to call this tool multiple times.

## SAFETY RESTRICTIONS
- Never execute the following dangerous commands under any circumstances:
  - `rm -rf /` or any variant targeting root directories
  - `rm -rf ~` or any command that could wipe out home directories
  - `rm -rf .` without specific context and explicit user confirmation
  - Any command with `:(){:|:&};:` or similar fork bombs
  - Any command that would expose sensitive information (keys, tokens, passwords)
  - Commands that intentionally create infinite loops
- For any destructive operation (delete, overwrite, etc.), always:
  1. Warn the user about potential consequences
  2. Request explicit confirmation before execution
  3. Suggest safer alternatives when available
- If unsure about a command's safety, decline to run it and explain your concerns

## POINTS TO NOTE
- This tool can be used alongside other tools within CodeCompanion
- Commands have a timeout limit. If a command takes too long, it will be automatically killed.

## USER ENVIRONMENT
- Shell: %s
- Operating System: %s
- Neovim Version: %s]],
    vim.fn.getcwd(),
    vim.o.shell,
    get_os_name(),
    vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch
  ),

  handlers = {
    ---Dynamically determine approval behavior based on auto_allow_patterns/always_confirm_patterns
    ---Yolo mode by default: commands auto-execute unless they match always_confirm_patterns
    ---@param self CodeCompanion.Tool.ExtraCmdRunner
    setup = compat.handler_setup(function(self, _meta)
      local config = get_config()
      local cmd_str = self.args and self.args.cmd or ""

      self.opts = self.opts or {}

      -- Always-confirm (blacklist) wins over everything — dangerous commands always need approval
      if matches_any(cmd_str, config.always_confirm_patterns) then
        self.opts.require_approval_before = true
        self.opts.require_cmd_approval = true
        self.opts.allowed_in_yolo_mode = false
        return
      end

      -- Auto-allow pattern match or yolo mode default: no approval needed
      self.opts.require_approval_before = false
      self.opts.require_cmd_approval = false
    end),
  },

  output = {
    ---Returns the command that will be executed (shown in approval prompt)
    ---@param self CodeCompanion.Tool.ExtraCmdRunner
    ---@return string
    cmd_string = compat.output_cmd_string(function(self, _meta)
      return self.args.cmd
    end),

    ---@param self CodeCompanion.Tool.ExtraCmdRunner
    ---@param stderr table The error output from the command
    ---@param meta { tools: CodeCompanion.Tools, cmd: string }
    error = compat.output_error(function(self, stderr, meta)
      if stderr then
        local chat = meta.tools.chat
        local errors = vim.iter(stderr):flatten():join("\n")

        local output = [[%s
```txt
%s
```]]

        local llm_output = fmt(output, fmt("There was an error running the `%s` command:", self.args.cmd), errors)
        local user_output = fmt(output, fmt("`%s` error", self.args.cmd), errors)

        chat:add_tool_output(self, llm_output, user_output)
      end
    end),

    ---Prompt the user to approve the execution of the command
    ---@param self CodeCompanion.Tool.ExtraCmdRunner
    ---@return string
    prompt = compat.output_prompt(function(self, _meta)
      return fmt("Run the command `%s`?", self.args.cmd)
    end),

    -- ---Rejection message back to the LLM
    -- ---@param self CodeCompanion.Tool.ExtraCmdRunner
    -- ---@param meta { tools: CodeCompanion.Tools, cmd: string, opts: table }
    -- rejected = compat.output_rejected(function(self, meta)
    --   local helpers = require("codecompanion.interactions.chat.tools.builtin.helpers")
    --   local message = fmt("The user rejected the execution of the `%s` command", self.args.cmd)
    --   if compat.is_new_api() then
    --     local opts = vim.tbl_extend("force", { message = message }, meta or {})
    --     helpers.rejected(self, opts)
    --   else
    --     local opts = vim.tbl_extend("force", { message = message }, meta.opts or {})
    --     helpers.rejected(self, meta.tools, meta.cmd, opts)
    --   end
    --   -- Workaround: orchestrator's rejection path doesn't auto-submit to the LLM,
    --   -- so we explicitly submit so the LLM can respond to the rejection.
    --   local chat = compat.is_new_api() and meta.tools and meta.tools.chat or meta.tools and meta.tools.chat
    --   if chat and chat.submit then vim.schedule(function()
    --     chat:submit({ auto_submit = true })
    --   end) end
    -- end),
    ---Rejection message back to the LLM
    ---@param self CodeCompanion.Tool.RunCommand
    ---@param meta {tools: CodeCompanion.Tools, cmd: string, opts: table}
    ---@return nil
    rejected = function(self, meta)
      local helpers = require("codecompanion.interactions.chat.tools.builtin.helpers")
      local message = fmt("The user rejected the execution of the `%s` command", self.args.cmd)
      meta = vim.tbl_extend("force", { message = message }, meta or {})
      helpers.rejected(self, meta)
    end,

    ---@param self CodeCompanion.Tool.ExtraCmdRunner
    ---@param stdout table|nil The output from the tool
    ---@param meta { tools: table, cmd: table }
    success = compat.output_success(function(self, stdout, meta)
      local chat = meta.tools.chat
      if stdout then
        local output = vim.iter(stdout[#stdout]):flatten():join("\n")
        local message = fmt(
          [[`%s`
````
%s
````]],
          self.args.cmd,
          output
        )
        return chat:add_tool_output(self, message)
      end
      return chat:add_tool_output(self, "There was no output from the cmd_runner tool")
    end),

    ---Handle cancellation
    ---@param self CodeCompanion.Tool.ExtraCmdRunner
    ---@param meta { tools: CodeCompanion.Tools, cmd: string }
    cancelled = compat.output_cancelled(function(self, meta)
      local chat = meta.tools and meta.tools.chat
      if chat then
        local message = fmt("The `%s` command was cancelled", self.args.cmd)
        chat:add_tool_output(self, message)
      end
    end),
  },
}
