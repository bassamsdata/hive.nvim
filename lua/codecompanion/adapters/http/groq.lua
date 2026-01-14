-- Groq Adapter for CodeCompanion
-- Extends OpenAI adapter with Groq-specific features (reasoning tokens)
-- Reference: https://console.groq.com/docs/reasoning
--
-- API Key Configuration
-- ======================
-- Users can provide the API key in multiple ways:
--
-- 1. Via adapter config with static string:
-- ```lua
-- groq = function()
--   return require("codecompanion.adapters").extend("groq", {
--     env = { api_key = "your-api-key" },
--   })
-- end,
-- ```
--
-- 2. Via adapter config with function (lazy loaded):
-- ```lua
-- local function get_groq_key()
--   return os.getenv("GROQ_API_KEY") or vim.fn.inputsecret("Groq API Key: ")
-- end
--
-- groq = function()
--   return require("codecompanion.adapters").extend("groq", {
--     env = { api_key = get_groq_key },
--   })
-- end,
-- ```
--
-- 3. Via environment variables (fallback):
--    GROQ_API_KEY or groq_api_key
--
-- 4. Via interactive prompt (if no key found):
--    The fallback models will be used, but the adapter will attempt to fetch
--    live models if a key becomes available.
--

local http_models = require("codecompanion.utils.http_models")

local function get_groq_models(api_key_source)
  return http_models.fetch_models({
    url = "https://api.groq.com/openai/v1/models",
    api_key_source = api_key_source,
    env_var_names = { "GROQ_API_KEY", "groq_api_key" },
    fallback_models = { ["llama-3.3-70b-versatile"] = { opts = {} } },
  })
end

-- Get the base OpenAI adapter
local openai = require("codecompanion.adapters.http.openai")

-- Build a complete adapter by starting with OpenAI and overriding what we need
return vim.tbl_deep_extend("force", {}, openai, {
  name = "groq",
  formatted_name = "Groq",
  url = "https://api.groq.com/openai/v1/chat/completions",
  env = {
    api_key = "GROQ_API_KEY",
  },
  handlers = {
    -- Groq-specific: Handle reasoning tokens from parsed format
    -- When reasoning_format: "parsed", reasoning comes in message.reasoning field
    parse_message_meta = function(self, data)
      local extra = data.extra
      if not extra then return data end

      -- Handle reasoning content from Groq's parsed format
      if extra.reasoning then
        data.output.reasoning = data.output.reasoning or {}
        data.output.reasoning.content = extra.reasoning
      end

      -- Don't show empty content as a response
      if data.output.content == "" then data.output.content = nil end

      return data
    end,
  },
  schema = {
    model = {
      order = 1,
      mapping = "parameters",
      type = "enum",
      desc = "ID of the model to use. See https://console.groq.com/docs/models",
      default = "openai/gpt-oss-120b",
      choices = function(self)
        local api_key_source = self and self.env and self.env.api_key or nil
        return get_groq_models(api_key_source)
      end,
    },
    reasoning_format = {
      order = 2,
      mapping = "parameters",
      type = "enum",
      optional = true,
      desc = "Controls how reasoning is presented. Only for reasoning models.",
      default = "parsed",
      choices = { "parsed", "raw", "hidden" },
      condition = function(self)
        local model = self.schema.model.default
        if type(model) == "function" then model = model(self) end
        local choices = self.schema.model.choices
        if type(choices) == "function" then choices = choices(self) end
        return choices and choices[model] and choices[model].opts and choices[model].opts.can_reason
      end,
    },
    reasoning_effort = {
      order = 3,
      mapping = "parameters",
      type = "enum",
      optional = true,
      desc = "Reasoning effort level. GPT-OSS: low/medium/high. Qwen: none/default.",
      choices = { "none", "default", "low", "medium", "high" },
      condition = function(self)
        local model = self.schema.model.default
        if type(model) == "function" then model = model(self) end
        local choices = self.schema.model.choices
        if type(choices) == "function" then choices = choices(self) end
        return choices and choices[model] and choices[model].opts and choices[model].opts.can_reason
      end,
    },
    temperature = {
      order = 4,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 0.5,
      desc = "Sampling temperature (0-2). Lower values (0.5) recommended for tool calling.",
      validate = function(n)
        return n >= 0 and n <= 2, "Must be between 0 and 2"
      end,
    },
    max_completion_tokens = {
      order = 5,
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
      order = 6,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 0.95,
      desc = "Nucleus sampling threshold (0-1).",
      validate = function(n)
        return n >= 0 and n <= 1, "Must be between 0 and 1"
      end,
    },
  },
})
