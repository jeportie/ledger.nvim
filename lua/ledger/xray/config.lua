local M = {}

local jira_config = require("ledger.jira.config")

local defaults = {
  project_key = "B2CQA",
  ledger_live_root = nil,
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", defaults, opts)
  jira_config.setup(opts)
end

function M.credentials()
  return jira_config.credentials()
end

return M
