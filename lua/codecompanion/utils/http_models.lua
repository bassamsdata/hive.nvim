---@class CodeCompanion.Utils.HTTPModels
---HTTP adapter model fetching utilities
---Provides common functionality for fetching and caching models from various API providers

local M = {}

---Resolve API key from configuration source (function or string)
---@param env_config string|function|nil
---@return string|nil
function M.resolve_api_key(env_config)
  if not env_config then return nil end

  local api_key = env_config
  if type(api_key) == "function" then api_key = api_key() end

  if api_key and api_key ~= "" then return api_key end
  return nil
end

---Fetch and cache models from an API endpoint
---@param args table Configuration for model fetching
---  - url: string - API endpoint URL
---  - api_key_source: string|function|nil - API key from adapter config
---  - env_var_names: table - Environment variable names to check (e.g., {"GROQ_API_KEY", "groq_api_key"})
---  - fallback_models: table - Models to use if API fetch fails
---  - model_transformer: function|nil - Optional function to transform each model entry
---  - cache_duration: number|nil - Cache duration in seconds (default: 1800)
---  - timeout: number|nil - Request timeout in milliseconds (default: 5000)
---@return table
function M.fetch_models(args)
  local url = args.url
  local api_key_source = args.api_key_source
  local env_var_names = args.env_var_names or {}
  local fallback_models = args.fallback_models or {}
  local model_transformer = args.model_transformer
  local cache_duration = args.cache_duration or 1800
  local timeout = args.timeout or 5000

  -- Use cache key based on URL to allow multiple cached model lists
  local cache_key = "_http_models_" .. url:gsub("[^%w]", "_")
  local cached_models = M[cache_key]
  local cached_expires = M[cache_key .. "_expires"]

  if cached_models and cached_expires and cached_expires > os.time() then return cached_models end

  local ok, Curl = pcall(require, "plenary.curl")
  if not ok then return fallback_models end

  -- Resolve API key from various sources
  local api_key = M.resolve_api_key(api_key_source)
  if not api_key then
    for _, env_var in ipairs(env_var_names) do
      api_key = vim.env[env_var]
      if api_key and api_key ~= "" then break end
    end
  end

  -- If no API key and one is required, return fallback
  if not api_key or api_key == "" then
    if args.requires_auth ~= false then return fallback_models end
  end

  -- Build headers
  local headers = { ["Content-Type"] = "application/json" }
  if api_key then headers["Authorization"] = "Bearer " .. api_key end

  -- Fetch models from API
  local success, response = pcall(function()
    return Curl.get(url, {
      sync = true,
      headers = headers,
      timeout = timeout,
    })
  end)

  if not success or not response or not response.body then return fallback_models end

  -- Parse response
  local parse_ok, json = pcall(vim.json.decode, response.body)
  if not parse_ok or not json or not json.data then return fallback_models end

  -- Transform models
  local models = {}
  for _, model in ipairs(json.data) do
    if model.id then
      if model_transformer and type(model_transformer) == "function" then
        models[model.id] = model_transformer(model)
      else
        models[model.id] = { opts = {} }
      end
    end
  end

  if vim.tbl_isempty(models) then return fallback_models end

  -- Cache results
  M[cache_key] = models
  M[cache_key .. "_expires"] = os.time() + cache_duration

  return models
end

return M
