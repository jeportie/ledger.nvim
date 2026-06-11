-- ledger.builder.ui.hl
--
-- Highlight groups for the Builder dashboard. We reuse volt's colorscheme-
-- derived accents (Ex* groups, loaded by volt.run) and add a few semantic
-- aliases so the panes read clearly. Defining them as links keeps them
-- tracking the active theme.

local M = {}

M.groups = {
  LedgerBuilderTitle = { link = "ExBlue" },
  LedgerBuilderDim = { link = "Comment" },
  LedgerBuilderKey = { link = "ExYellow" },
  LedgerBuilderOn = { link = "ExGreen" },
  LedgerBuilderOff = { link = "Comment" },
  -- step / process states
  LedgerStateDone = { link = "ExGreen" },
  LedgerStateRunning = { link = "ExYellow" },
  LedgerStatePending = { link = "Comment" },
  LedgerStateStale = { link = "ExYellow" },
  LedgerStateFailed = { link = "ExRed" },
}

function M.setup()
  for name, def in pairs(M.groups) do
    -- only set if missing so user overrides win
    if vim.fn.hlexists(name) == 0 or true then
      def = vim.tbl_extend("force", { default = true }, def)
      pcall(vim.api.nvim_set_hl, 0, name, def)
    end
  end
end

return M
