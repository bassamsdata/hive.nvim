-- Model picker for subagent small/big model assignment
-- Provides a chat keymap (gm) to select adapter + model from available options
-- and assign the result to vim.g.HIVE_SMALL_MODEL or vim.g.HIVE_BIG_MODEL

local fmt = string.format
local notify = require("hive.utils.notify")

local M = {}

---Get the change_adapter module from codecompanion.nvim
---@return table|nil
local function get_change_adapter()
  local ok, mod = pcall(require, "codecompanion.interactions.chat.keymaps.change_adapter")
  if ok then return mod end
  return nil
end

---Build the "adapter/model" string from selections
---@param adapter_name string
---@param model_id string|nil
---@return string
local function build_model_string(adapter_name, model_id)
  if model_id then return adapter_name .. "/" .. model_id end
  return adapter_name
end

---Select a model type (small/big/both) and apply
---@param model_string string The "adapter/model" string
local function select_and_apply(model_string)
  vim.ui.select({ "small (for tasks)", "big (for consultants)", "both" }, {
    prompt = "Set as:",
    kind = "codecompanion.nvim",
  }, function(choice)
    if not choice then return end

    if choice:match("^small") or choice == "both" then
      vim.g.HIVE_SMALL_MODEL = model_string
      notify(fmt("Small model \u{2192} %s", model_string), vim.log.levels.INFO)
    end
    if choice:match("^big") or choice == "both" then
      vim.g.HIVE_BIG_MODEL = model_string
      notify(fmt("Big model \u{2192} %s", model_string), vim.log.levels.INFO)
    end
  end)
end

---Resolve an adapter by name using codecompanion's factory
---@param adapter_name string
---@return table|nil resolved_adapter
local function resolve_adapter(adapter_name)
  local ok, adapters = pcall(require, "codecompanion.adapters")
  if not ok then return nil end

  local success, resolved = pcall(adapters.resolve, adapter_name)
  if not success or not resolved then return nil end

  return resolved
end

---Show model selection for an adapter then assign to small/big
---Uses change_adapter.list_http_models for proper model listing
---@param adapter_name string
local function select_model_and_assign(adapter_name)
  local change_adapter = get_change_adapter()
  if not change_adapter then return end

  local resolved = resolve_adapter(adapter_name)
  if not resolved then
    select_and_apply(adapter_name)
    return
  end

  local models_list = change_adapter.list_http_models(resolved)

  if not models_list or #models_list == 0 then
    -- No model choices available, use adapter with its default model
    local default_model = resolved.schema and resolved.schema.model and resolved.schema.model.default
    if type(default_model) == "function" then default_model = default_model(resolved) end
    select_and_apply(build_model_string(adapter_name, default_model))
    return
  end

  local function get_model_id(model)
    if type(model) == "table" then return model.id or model.modelId end
    return model
  end

  local current_default = resolved.schema and resolved.schema.model and resolved.schema.model.default
  if type(current_default) == "function" then current_default = current_default(resolved) end

  vim.ui.select(models_list, {
    prompt = "Select Model",
    kind = "codecompanion.nvim",
    format_item = function(model)
      local model_id = get_model_id(model)
      local display
      if type(model) == "table" then
        display = model.description or model.formatted_name or model.id or "Unknown"
      else
        display = tostring(model)
      end
      if model_id == current_default then return "* " .. display end
      return "  " .. display
    end,
  }, function(selected)
    if not selected then return end
    local model_id = get_model_id(selected)
    select_and_apply(build_model_string(adapter_name, model_id))
  end)
end

---Main callback for the model picker keymap
---@param chat table CodeCompanion.Chat
function M.callback(chat)
  local change_adapter = get_change_adapter()
  if not change_adapter then
    notify("Could not load codecompanion adapter module", vim.log.levels.ERROR)
    return
  end

  local current_adapter = chat.adapter.name
  local adapters_list = change_adapter.get_adapters_list(current_adapter)

  vim.ui.select(adapters_list, {
    prompt = "Select Adapter (for subagent model)",
    kind = "codecompanion.nvim",
    format_item = function(item)
      local small = vim.g.HIVE_SMALL_MODEL or ""
      local big = vim.g.HIVE_BIG_MODEL or ""
      local indicators = {}
      if small:match("^" .. vim.pesc(item) .. "/") then table.insert(indicators, "small") end
      if big:match("^" .. vim.pesc(item) .. "/") then table.insert(indicators, "big") end
      if #indicators > 0 then return item .. "  [" .. table.concat(indicators, ", ") .. "]" end
      return item
    end,
  }, function(selected_adapter)
    if not selected_adapter then return end
    select_model_and_assign(selected_adapter)
  end)
end

---Get current model assignment summary
---@return string
function M.get_summary()
  local small = vim.g.HIVE_SMALL_MODEL
  local big = vim.g.HIVE_BIG_MODEL
  local parts = {}
  if small then table.insert(parts, fmt("small=%s", small)) end
  if big then table.insert(parts, fmt("big=%s", big)) end
  if #parts == 0 then return "No subagent models set (inheriting from parent)" end
  return table.concat(parts, ", ")
end

---Register the chat buffer keymap
---@return nil
function M.setup()
  local hive_config = require("hive.config")

  local ok, cc_config = pcall(require, "codecompanion.config")
  if not ok then return end

  local keymaps = cc_config.interactions and cc_config.interactions.chat and cc_config.interactions.chat.keymaps
  if not keymaps then return end

  local modes = hive_config.keymap_modes("subagent_model")
  if not modes then return end

  keymaps["subagent_model"] = {
    modes = modes,
    index = 56,
    description = "[Model] Set subagent model (small/big)",
    callback = function(chat)
      M.callback(chat)
    end,
  }
end

return M
