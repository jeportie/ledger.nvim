local M = {}

local defaults = {
  team = "QA Automation",
  project_key = "QAA",
  board_name = "Team QA Automation",
  board_id = nil,
  page_cap = 10,
  card_min_width = 30,
  card_max_width = 42,
  backdrop_blend = 30,
}

local cfg = vim.deepcopy(defaults)

function M.setup(opts)
  cfg = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get()
  return cfg
end

return M
