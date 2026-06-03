local M = {}

local store = require("ledger.jira.board.store")
local multi = require("ledger.jira.pickers.multi_select")

local CATEGORIES = {
  { key = "assignees", label = "  Assignees" },
  { key = "epics",     label = "  Epics" },
  { key = "types",     label = "  Types" },
  { key = "labels",    label = "  Labels" },
}

local function rerender_board()
  local ok, win = pcall(require, "jira-board.ui.window")
  if ok and win.is_open() then win.rerender() end
end

-- Open the multi-select picker for one category.
function M.open_category(cat)
  local options = store.filter_options(cat)
  if #options == 0 then
    vim.notify("jira-board: no " .. cat .. " to filter on", vim.log.levels.INFO)
    return
  end

  local current_set = store.state.filters[cat] or {}
  local label_to_id = {}
  local id_to_label = {}
  local label_list = {}
  local current_labels = {}
  for _, opt in ipairs(options) do
    label_to_id[opt.label] = opt.id
    id_to_label[opt.id] = opt.label
    table.insert(label_list, opt.label)
    if current_set[opt.id] then table.insert(current_labels, opt.label) end
  end

  multi.open({
    title = "Filter: " .. cat,
    options = label_list,
    current = current_labels,
    on_done = function(selected, _)
      if selected == nil then return end -- cancelled
      local new_set = {}
      for _, lbl in ipairs(selected) do
        local id = label_to_id[lbl]
        if id then new_set[id] = lbl end
      end
      store.set_filter_category(cat, new_set)
      rerender_board()
    end,
  })
end

-- Open the main category menu (nvzone/menu style).
function M.open()
  local ok, menu = pcall(require, "menu")
  if not ok then
    vim.notify("jira-board: nvzone/menu not installed", vim.log.levels.ERROR)
    return
  end
  pcall(require("menu.utils").delete_old_menus)

  local items = {}
  for _, cat in ipairs(CATEGORIES) do
    local set = store.state.filters[cat.key] or {}
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    local suffix = n > 0 and ("(" .. n .. ")") or ""
    table.insert(items, {
      name = cat.label,
      rtxt = suffix,
      cmd = function() M.open_category(cat.key) end,
    })
  end
  table.insert(items, { name = "separator" })
  if store.has_active_filters() then
    table.insert(items, {
      name = "󰁝  Clear all filters",
      hl = "ExRed",
      cmd = function()
        store.clear_filters()
        rerender_board()
      end,
    })
  end
  menu.open(items, {})
end

return M
