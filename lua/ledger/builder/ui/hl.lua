-- ledger.builder.ui.hl
--
-- Highlight groups for the Builder dashboard. Reuse volt's colorscheme-derived
-- accents (Ex* groups, loaded by volt.run) so colours track the active theme:
--   done   = green   running = blue   failed = red   stale = yellow
--   pending/dim = comment grey      keys/accent = yellow / blue

local M = {}

M.groups = {
  LedgerBuilderTitle = { link = "ExBlue" },
  LedgerBuilderDim = { link = "Comment" },
  LedgerBuilderKey = { link = "ExYellow" },
  LedgerBuilderOn = { link = "ExGreen" },
  LedgerBuilderOff = { link = "Comment" },
  -- step / process states
  LedgerStateDone = { link = "ExGreen" },
  LedgerStateRunning = { link = "ExBlue" },
  LedgerStatePending = { link = "Comment" },
  LedgerStateStale = { link = "ExYellow" },
  LedgerStateFailed = { link = "ExRed" },
}

function M.setup()
  for name, def in pairs(M.groups) do
    pcall(vim.api.nvim_set_hl, 0, name, vim.tbl_extend("force", { default = true }, def))
  end
end

return M
