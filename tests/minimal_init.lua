vim.opt.swapfile = false
vim.opt.shada = ""
vim.opt.more = false

local plugin_dir = vim.fn.fnamemodify(vim.fn.expand("<sfile>:p"), ":h:h")
local lazy_dir = vim.fn.stdpath("data") .. "/lazy"

vim.opt.runtimepath:prepend(plugin_dir)
vim.opt.runtimepath:prepend(lazy_dir .. "/plenary.nvim")
vim.opt.runtimepath:prepend(lazy_dir .. "/volt")

vim.opt.lines = 40
vim.opt.columns = 120

vim.cmd("runtime plugin/plenary.vim")