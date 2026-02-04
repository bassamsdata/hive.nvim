--[[
| OS        | jit.os      | vim.uv.os_uname().sysname   |
| --------- | ----------  | --------------------------- |
| macOS     | `"OSX"`     | `"Darwin"`                  |
| Linux     | `"Linux"`   | `"Linux"`                   |
| Windows   | `"Windows"` | `"Windows_NT"`              |
]]
local Noti = {}
--- Show a desktop notification(mac and linux).
--- @param title string
--- @param message string
--- @param fallback? boolean
function Noti.smart_notify(title, message, fallback)
  local info = vim.uv.os_uname()
  local sys = info.sysname

  local function notify_fallback()
    if fallback then
      vim.schedule(function()
        vim.notify(message, vim.log.levels.INFO, { title = title })
      end)
    end
  end

  if sys == "Darwin" then
    local sound = (info.machine == "arm64") and "Crystal" or "Glass"
    local script = string.format("display notification %q with title %q sound name %q", message, title, sound)
    vim.system({ "osascript", "-e", script }, { detach = true }, function(obj)
      if obj.code ~= 0 then notify_fallback() end
    end)
  elseif sys == "Linux" then
    vim.system({ "notify-send", title, message }, { detach = true }, function(obj)
      if obj.code ~= 0 then notify_fallback() end
    end)
  else
    notify_fallback()
  end
end

return Noti
