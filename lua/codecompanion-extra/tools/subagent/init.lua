-- Subagent shared utilities
-- Re-exports all subagent foundation modules for easy access

return {
  utils = require("codecompanion-extra.tools.subagent.utils"),
  messages = require("codecompanion-extra.tools.subagent.messages"),
  status = require("codecompanion-extra.tools.subagent.status"),
  lifecycle = require("codecompanion-extra.tools.subagent.lifecycle"),
}
