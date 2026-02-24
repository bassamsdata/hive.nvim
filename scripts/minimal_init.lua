vim.cmd([[let &rtp.=','.getcwd()]])
vim.cmd("set rtp+=deps/mini.test")

-- codecompanion.nvim and its dependencies (for compat tests)
local cc_path = vim.fn.getcwd() .. "/deps/codecompanion.nvim"
if vim.uv.fs_stat(cc_path) then
  vim.cmd("set rtp+=deps/codecompanion.nvim")
  vim.cmd("set rtp+=deps/plenary.nvim")
end

require("mini.test").setup()
