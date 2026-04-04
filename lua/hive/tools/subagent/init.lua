-- Subagent shared utilities
-- Re-exports all subagent foundation modules for easy access

return {
  utils = require("hive.tools.subagent.utils"),
  messages = require("hive.tools.subagent.messages"),
  status = require("hive.tools.subagent.status"),
  lifecycle = require("hive.tools.subagent.lifecycle"),
}
