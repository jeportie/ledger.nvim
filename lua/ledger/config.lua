local M = {}

M.defaults = {
  jira = {
    project_key = "QAA",
    board_name = "Team QA Automation",
  },
  xray = {
    project_key = "B2CQA",
  },
  monorepo_root = nil,
  coinapps_path = nil,
  speculos = {
    device = "nanoSP",
    image_tag = "ghcr.io/ledgerhq/speculos:latest",
  },
  seed = {
    keychain_service = "ledger-e2e-seed",
    env_var = "SEED",
  },
}

M.opts = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.defaults, opts or {})

  if M.opts.jira then
    local jcfg = require("ledger.jira.config")
    if jcfg and type(jcfg) == "table" and jcfg.set then
      jcfg.set(M.opts.jira)
    end
  end

  if M.opts.xray then
    local ok, xray = pcall(require, "ledger.xray")
    if ok and xray.setup then
      xray.setup({ project_key = M.opts.xray.project_key })
    end
  end

  if M.opts.jira and M.opts.jira.project_key then
    local ok, board = pcall(require, "ledger.jira.board")
    if ok and board.setup then
      board.setup({
        project_key = M.opts.jira.project_key,
        board_name = M.opts.jira.board_name,
      })
    end
  end

  -- Builder backend: :LedgerTask / :LedgerTasks
  local ok_tasks, tasks = pcall(require, "ledger.tasks")
  if ok_tasks and tasks.register_commands then
    tasks.register_commands()
  end
end

function M.get()
  return M.opts
end

return M
