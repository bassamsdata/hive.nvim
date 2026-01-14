-- Cerebras Adapter for CodeCompanion
-- A complete standalone adapter that extends OpenAI
-- Reference: https://inference-docs.cerebras.ai/
--
-- API Key Configuration
-- ======================
-- Users can provide the API key in multiple ways:
--
-- 1. Via adapter config with static string:
-- ```lua
-- cerebras = function()
--   return require("codecompanion.adapters").extend("cerebras", {
--     env = { api_key = "your-api-key" },
--   })
-- end,
-- ```
--
-- 2. Via adapter config with function (lazy loaded):
-- ```lua
-- local function get_cerebras_key()
--   return os.getenv("CEREBRAS_API_KEY") or vim.fn.inputsecret("Cerebras API Key: ")
-- end
--
-- cerebras = function()
--   return require("codecompanion.adapters").extend("cerebras", {
--     env = { api_key = get_cerebras_key },
--   })
-- end,
-- ```
--
-- 3. Via environment variables (fallback):
--    CEREBRAS_API_KEY or cerebras_api_key
--
-- 4. Via interactive prompt (if no key found):
--    The fallback models will be used, but the adapter will attempt to fetch
--    live models if a key becomes available.
--

local http_models = require("codecompanion.utils.http_models")

local function get_cerebras_models(api_key_source)
  return http_models.fetch_models({
    url = "https://api.cerebras.ai/v1/models",
    api_key_source = api_key_source,
    env_var_names = { "CEREBRAS_API_KEY", "cerebras_api_key" },
    fallback_models = {},
    model_transformer = function(model)
      return {
        formatted_name = model.id,
        opts = { has_vision = false },
      }
    end,
  })
end

-- Get the base OpenAI adapter
local openai = require("codecompanion.adapters.http.openai")

-- Build a complete adapter by starting with OpenAI and overriding what we need
return vim.tbl_deep_extend("force", {}, openai, {
  name = "cerebras",
  formatted_name = "Cerebras",
  url = "https://api.cerebras.ai/v1/chat/completions",
  env = {
    api_key = "CEREBRAS_API_KEY",
  },
  handlers = {
    -- Override form_messages to handle reasoning content formatting
    form_messages = function(self, messages)
      local res = openai.handlers.form_messages(self, messages)
      if res and res.messages then
        for _, msg in ipairs(res.messages) do
          if msg.reasoning then
            local reasoning_content = type(msg.reasoning) == "table" and msg.reasoning.content or msg.reasoning
            msg.content = reasoning_content .. "\n<answer>\n" .. (msg.content or "") .. "\n</answer>"
            msg.reasoning = nil
          end
        end
      end
      return res
    end,

    -- Extract reasoning from response
    parse_message_meta = function(self, data)
      local extra = data.extra
      if extra and extra.reasoning then
        data.output.reasoning = { content = extra.reasoning }
        if data.output.content == "" then data.output.content = nil end
      end
      return data
    end,

    -- Cerebras requires all tools to have the same 'strict' value
    form_tools = function(self, tools)
      if not self.opts.tools or not tools or vim.tbl_count(tools) == 0 then return nil end

      local transformed = {}
      for _, tool in pairs(tools) do
        for _, schema in pairs(tool) do
          if schema["function"] then schema["function"].strict = true end
          table.insert(transformed, schema)
        end
      end

      return { tools = transformed }
    end,
  },
  schema = {
    -- Override model with Cerebras-specific choices
    model = {
      order = 1,
      mapping = "parameters",
      type = "enum",
      desc = "ID of the model to use. See https://inference-docs.cerebras.ai/",
      default = "llama-3.3-70b",
      choices = function(self)
        local api_key_source = self and self.env and self.env.api_key or nil
        return get_cerebras_models(api_key_source)
      end,
    },
    -- Cerebras-specific reasoning_effort (only for gpt-oss-120b)
    reasoning_effort = {
      order = 2,
      mapping = "parameters",
      type = "enum",
      optional = true,
      choices = { "low", "medium", "high" },
      desc = "The amount of reasoning the model performs (gpt-oss-120b only).",
      ---@param self CodeCompanion.HTTPAdapter
      enabled = function(self)
        return self.schema.model.default == "gpt-oss-120b"
      end,
    },
    -- Cerebras-specific disable_reasoning (only for zai-glm models)
    disable_reasoning = {
      order = 3,
      mapping = "parameters",
      type = "boolean",
      optional = true,
      desc = "Toggle reasoning on or off (zai-glm models only).",
      ---@param self CodeCompanion.HTTPAdapter
      enabled = function(self)
        local model = self.schema.model.default
        return model and model:match("^zai%-glm")
      end,
    },
  },
})
