-- OpenRouter Adapter for CodeCompanion
-- A complete standalone adapter that extends OpenAI
-- Reference: https://openrouter.ai/docs
--
-- Usage in codecompanion setup:
-- ```lua
-- adapters = {
--   openrouter = function()
--     return require("codecompanion.adapters").extend("openrouter", {
--       env = { api_key = "your-key" },
--       schema = { model = { default = "anthropic/claude-sonnet-4" } },
--     })
--   end,
-- }
-- ```

local fallback_models = {
  "google/gemini-2.0-flash-001",
  "google/gemini-2.5-pro-preview-03-25",
  "anthropic/claude-sonnet-4",
  "anthropic/claude-3.5-sonnet",
  "openai/gpt-4o-mini",
  "deepseek/deepseek-r1",
  "meta-llama/llama-3.2-90b-vision-instruct",
}

local _cached_models = nil
local _cache_expires = 0

local function get_openrouter_tool_models()
  if _cached_models and _cache_expires > os.time() then return _cached_models end

  local ok, curl = pcall(require, "plenary.curl")
  if not ok then return fallback_models end

  local success, response = pcall(function()
    return curl.get("https://openrouter.ai/api/v1/models?supported_parameters=tools", {
      sync = true,
      headers = {
        ["Content-Type"] = "application/json",
      },
      timeout = 5000,
    })
  end)

  if not success or not response or not response.body then
    vim.notify("Failed to fetch OpenRouter models, using fallback", vim.log.levels.WARN)
    return fallback_models
  end

  local parse_ok, json = pcall(vim.json.decode, response.body)
  if not parse_ok or not json or not json.data then
    vim.notify("Failed to parse OpenRouter models response", vim.log.levels.WARN)
    return fallback_models
  end

  local models = {}
  for _, model in ipairs(json.data) do
    if model.id then
      models[model.id] = {
        opts = {
          supports_tools = true,
          has_streaming = true,
        },
      }
    end
  end

  if vim.tbl_isempty(models) then
    vim.notify("No tool-capable models found, using fallback", vim.log.levels.WARN)
    return fallback_models
  end

  _cached_models = models
  _cache_expires = os.time() + (30 * 60)

  return models
end

-- Get the base OpenAI adapter and extend it
local openai = require("codecompanion.adapters.http.openai")

-- Build a complete adapter by starting with OpenAI and overriding what we need
return vim.tbl_deep_extend("force", {}, openai, {
  name = "openrouter",
  formatted_name = "OpenRouter",
  url = "https://openrouter.ai/api/v1/chat/completions",
  env = {
    api_key = "OPENROUTER_API_KEY",
  },
  headers = {
    Authorization = "Bearer ${api_key}",
    ["Content-Type"] = "application/json",
    ["HTTP-Referer"] = "https://github.com/codecompanion",
    ["X-Title"] = "CodeCompanion",
  },
  handlers = {
    -- Override form_messages to handle OpenRouter's reasoning_details format
    form_messages = function(self, messages)
      return {
        messages = vim
          .iter(messages)
          :map(function(m)
            local tool_calls, reasoning_details = nil, nil

            -- Preserve reasoning data in messages for models that need it
            if m.reasoning and m.reasoning._data then
              reasoning_details = reasoning_details or {}
              if m.reasoning._data.encrypted then
                table.insert(reasoning_details, {
                  type = "reasoning.encrypted",
                  data = m.reasoning._data.encrypted,
                  id = m.reasoning._data.id,
                  format = m.reasoning._data.format or "openrouter-v1",
                  index = #reasoning_details,
                })
              end
            end

            -- Extract thought signatures from tool_calls and convert to reasoning_details
            if m.tools and m.tools.calls then
              tool_calls = vim
                .iter(m.tools.calls)
                :map(function(tc)
                  if tc.extra_content and tc.extra_content.google then
                    reasoning_details = reasoning_details or {}
                    table.insert(reasoning_details, {
                      type = "reasoning.encrypted",
                      data = tc.extra_content.google.thought_signature,
                      id = tc.id,
                      format = "google-gemini-v1",
                      index = #reasoning_details,
                    })
                  end
                  return {
                    id = tc.id,
                    type = tc.type,
                    ["function"] = tc["function"],
                  }
                end)
                :totable()
            end

            local msg = {
              role = m.role,
              content = m.content,
              tool_calls = tool_calls,
              tool_call_id = m.tools and m.tools.call_id or nil,
            }
            if reasoning_details then msg.reasoning_details = reasoning_details end
            return msg
          end)
          :totable(),
      }
    end,

    -- Extract reasoning content from OpenRouter's reasoning_details
    parse_message_meta = function(self, data)
      local extra = data.extra
      if not extra or not extra.reasoning_details then return data end

      vim.api.nvim_exec_autocmds("User", {
        pattern = "CodeCompanionReasoning",
        data = { status = "thinking" },
      })

      local reasoning_content = {}
      local reasoning_data = {}

      for _, detail in ipairs(extra.reasoning_details) do
        if detail.type == "reasoning.text" and detail.text then
          table.insert(reasoning_content, detail.text)
          if detail.signature then reasoning_data.signature = detail.signature end
        elseif detail.type == "reasoning.summary" and detail.summary then
          table.insert(reasoning_content, detail.summary)
        elseif detail.type == "reasoning.encrypted" and detail.data then
          reasoning_data.encrypted = detail.data
          reasoning_data.id = detail.id
          reasoning_data.format = detail.format
        end
      end

      if #reasoning_content > 0 then
        data.output.reasoning = data.output.reasoning or {}
        data.output.reasoning.content = table.concat(reasoning_content, "\n\n")
        if next(reasoning_data) then data.output.reasoning._data = reasoning_data end
      elseif next(reasoning_data) then
        data.output.reasoning = data.output.reasoning or {}
        data.output.reasoning._data = reasoning_data
      end

      if data.output.content == "" then data.output.content = nil end

      return data
    end,

    -- Handle tool calls with OpenRouter's thought signature support
    chat_output = function(self, data, tools)
      local adapter_utils = require("codecompanion.utils.adapters")
      if not data or data == "" then return nil end

      local data_mod = type(data) == "table" and data.body or adapter_utils.clean_streamed_data(data)
      local ok, json = pcall(vim.json.decode, data_mod, { luanil = { object = true } })
      if not ok or not json.choices or #json.choices == 0 then return nil end

      local function get_signature(reasoning_details)
        if not reasoning_details then return nil end
        for _, detail in ipairs(reasoning_details) do
          if detail.type == "reasoning.encrypted" and detail.data then
            return { google = { thought_signature = detail.data } }
          end
        end
      end

      if self.opts.tools and tools then
        for _, choice in ipairs(json.choices) do
          local delta = self.opts.stream and choice.delta or choice.message
          local signature = get_signature(delta and delta.reasoning_details)

          if delta and delta.tool_calls then
            local is_parallel = #delta.tool_calls > 1

            for i, tool in ipairs(delta.tool_calls) do
              local tool_index = tool.index and tonumber(tool.index) or i
              local id = tool.id or string.format("call_%s_%s", json.created, i)
              local should_attach_signature = signature and (not is_parallel or i == 1)

              if self.opts.stream then
                local existing = vim.iter(tools):find(function(t)
                  return t._index == tool_index
                end)
                if existing then
                  if tool["function"] and tool["function"]["arguments"] then
                    existing["function"]["arguments"] = (existing["function"]["arguments"] or "")
                      .. tool["function"]["arguments"]
                  end
                  if should_attach_signature and not existing.extra_content then existing.extra_content = signature end
                else
                  table.insert(tools, {
                    _index = tool_index,
                    id = id,
                    type = tool.type,
                    ["function"] = {
                      name = tool["function"]["name"],
                      arguments = tool["function"]["arguments"] or "",
                    },
                    extra_content = should_attach_signature and signature or nil,
                  })
                end
              else
                table.insert(tools, {
                  _index = i,
                  id = id,
                  type = tool.type,
                  ["function"] = {
                    name = tool["function"]["name"],
                    arguments = tool["function"]["arguments"] or "",
                  },
                  extra_content = should_attach_signature and signature or nil,
                })
              end
            end
          end
        end
      end

      local choice = json.choices[1]
      local delta = self.opts.stream and choice.delta or choice.message

      if not delta then return nil end

      local extra = nil
      if delta.reasoning_details then extra = { reasoning_details = delta.reasoning_details } end

      return {
        status = "success",
        output = { role = delta.role, content = delta.content },
        extra = extra,
      }
    end,
  },
  schema = {
    model = {
      order = 1,
      mapping = "parameters",
      type = "enum",
      desc = "ID of the model to use. See https://openrouter.ai/docs#models",
      default = "google/gemini-2.0-flash-001",
      choices = function(self)
        return get_openrouter_tool_models()
      end,
    },
    temperature = {
      order = 2,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 0.5,
      desc = "Sampling temperature (0-2).",
      validate = function(n)
        return n >= 0 and n <= 2, "Must be between 0 and 2"
      end,
    },
    max_tokens = {
      order = 3,
      mapping = "parameters",
      type = "integer",
      optional = true,
      default = 4096,
      desc = "Maximum tokens to generate.",
      validate = function(n)
        return n > 0, "Must be greater than 0"
      end,
    },
    top_p = {
      order = 4,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 0.95,
      desc = "Nucleus sampling threshold (0-1).",
      validate = function(n)
        return n >= 0 and n <= 1, "Must be between 0 and 1"
      end,
    },
    provider = {
      order = 5,
      mapping = "parameters",
      type = "map",
      optional = true,
      desc = "OpenRouter provider configuration",
      default = {
        order = { "cerebras", "groq", "deepinfra" },
        allow_fallbacks = true,
        data_collection = "deny",
        ignore = {
          "chutes",
          "deepseek",
          "nineteen",
          "openinference",
          "stealth",
          "targon",
          "ai21",
          "aionlabs",
          "alibaba",
          "avian",
          "cloudflare",
          "crofai",
          "crusoe",
          "enfer",
          "friendli",
          "gmicloud",
          "hyperbolic",
          "lambda",
          "liquid",
          "minimax",
          "ncompass",
          "novitaai",
          "ubicloud",
          "wandb",
        },
      },
      subtype = {
        order = {
          type = "list",
          subtype = { type = "string" },
          desc = "Preferred provider order",
          optional = true,
        },
        allow_fallbacks = {
          type = "boolean",
          desc = "Allow fallback providers when primary is unavailable",
          default = true,
          optional = true,
        },
        data_collection = {
          type = "enum",
          desc = "Data collection policy - deny blocks training providers",
          choices = { "allow", "deny" },
          default = "deny",
          optional = true,
        },
        ignore = {
          type = "list",
          subtype = { type = "string" },
          desc = "Providers to block",
          optional = true,
        },
        require_parameters = {
          type = "boolean",
          desc = "Only use providers supporting all parameters",
          default = false,
          optional = true,
        },
      },
    },
  },
})
