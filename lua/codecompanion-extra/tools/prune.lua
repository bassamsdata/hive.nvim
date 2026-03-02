local log = require("codecompanion.utils.log")
local compat = require("codecompanion-extra.tools.compat")

local fmt = string.format

local SYSTEM_PROMPT = [[<instruction name=context_management_protocol policy_level=critical>
You operate in a context-constrained environment. Proactive context management prevents context rot and maintains performance.

THE PRUNE TOOL
`prune` surgically removes tool outputs from your context. Use it to eliminate:
- **Noise**: irrelevant or unhelpful tool outputs
- **Superseded data**: older outputs replaced by newer reads/searches
- **Wrong targets**: files or searches that turned out to be irrelevant
- When you read files only to verify that they contain the correct content or fix, or when you use `get_changed_files` merely to check for changes without actually needing to reference the file contents.

A `<prunable-tools>` section appears in your context showing eligible outputs. Each line reads `ID: tool, parameter (~token count)`. Reference outputs by their numeric ID — these are your ONLY valid targets.

BATCH WISELY: Accumulate several candidates before pruning. Don't prune one tiny output alone.

DO NOT PRUNE WHEN:
- You plan to edit the file or reference the output for implementation
- You might need to re-examine the original content
- You are uncertain whether the data will be needed

Ask: "Is this noise, or will it serve me?" If the latter, keep it. Pruning that forces re-fetching is a net loss.

TIMING: Prefer managing context at the START of a new turn (after receiving a user message) rather than at the END of your previous turn. At turn start you have fresh signal about what the user needs next.

PARALLELISE: Avoid calling ONLY context management tools in your response. Combine prune with other relevant tools when possible.
</instruction>

<instruction name=injected_context_handling policy_level=critical>
A <prunable-tools> list is injected into your context after tool usage to help you manage context. Read the list and use it to inform pruning decisions. The list updates automatically after each turn. If no list is present, there is nothing to prune.
</instruction>]]

---@class CodeCompanion.Tool.Prune: CodeCompanion.Tools.Tool
return {
  name = "prune",
  cmds = {
    compat.cmds(function(tools, args, opts)
      local ids = args.ids
      if not ids or type(ids) ~= "table" or #ids == 0 then
        return {
          status = "error",
          data = "Missing or empty 'ids' parameter. Provide an array of numeric IDs from the <prunable-tools> list.",
        }
      end

      local numeric_ids = {}
      for _, id in ipairs(ids) do
        local n = tonumber(id)
        if n then table.insert(numeric_ids, n) end
      end

      if #numeric_ids == 0 then
        return {
          status = "error",
          data = "No valid numeric IDs provided. IDs must be numbers from the <prunable-tools> list.",
        }
      end

      return {
        status = "success",
        data = vim.json.encode(numeric_ids),
      }
    end),
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "prune",
      description = "Remove tool outputs from context to free up space. Pass numeric IDs from the <prunable-tools> list.",
      parameters = {
        type = "object",
        properties = {
          ids = {
            type = "array",
            items = { type = "integer" },
            description = "Numeric IDs from the <prunable-tools> list to prune",
          },
        },
        required = { "ids" },
        additionalProperties = false,
      },
    },
  },
  system_prompt = function(schema)
    return SYSTEM_PROMPT
  end,
  opts = {
    require_approval_before = false,
  },
  handlers = {
    setup = compat.handler_setup(function(self, meta)
      log:debug("[Prune] Setup: pruning IDs %s", vim.inspect(self.args.ids or {}))
    end),
    on_exit = compat.handler_on_exit(function(self, meta)
      log:trace("[Prune] on_exit handler executed")
    end),
  },
  output = {
    cmd_string = compat.output_cmd_string(function(self, meta)
      local ids = self.args.ids or {}
      return fmt("prune: [%s]", table.concat(vim.tbl_map(tostring, ids), ", "))
    end),
    prompt = compat.output_prompt(function(self, meta)
      local ids = self.args.ids or {}
      return fmt("Prune %d tool output(s)?", #ids)
    end),
    success = compat.output_success(function(self, stdout, meta)
      local chat = meta.tools.chat
      local raw = vim.iter(stdout):flatten():join("\n")

      local ok_ids, numeric_ids = pcall(vim.json.decode, raw)
      if not ok_ids or not numeric_ids then
        chat:add_tool_output(self, "Failed to parse prune IDs", "✗ Prune failed")
        return
      end

      local manager = require("codecompanion-extra.context_pruning").instance()
      if not manager then
        chat:add_tool_output(self, "Context pruning manager not initialized", "✗ Prune failed")
        return
      end

      local result = manager:prune(chat, numeric_ids)

      manager:update_prunable_message(chat)

      local parts = {}
      table.insert(parts, fmt("Pruned %d tool output(s), saving ~%d tokens.", result.pruned, result.tokens_saved))
      if #result.skipped > 0 then
        table.insert(parts, "Skipped:")
        for _, reason in ipairs(result.skipped) do
          table.insert(parts, "  - " .. reason)
        end
      end

      local llm_output = table.concat(parts, "\n")
      local user_output = fmt(" Pruned %d output(s) (~%d tokens saved)", result.pruned, result.tokens_saved)

      chat:add_tool_output(self, llm_output, user_output)
    end),
    error = compat.output_error(function(self, stderr, meta)
      local chat = meta.tools.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      chat:add_tool_output(self, fmt("Prune failed: %s", errors), "✗ Prune failed")
    end),
    rejected = compat.output_rejected(function(self, meta)
      local chat = meta.tools.chat
      chat:add_tool_output(self, "User rejected pruning operation")
    end),
    cancelled = compat.output_cancelled(function(self, meta)
      local chat = meta.tools.chat
      chat:add_tool_output(self, "Pruning was cancelled")
    end),
  },
}
