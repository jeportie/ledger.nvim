local M = {}

local function actions()
  return require("ledger.jira.board.actions")
end

local function win()
  return require("ledger.jira.board.ui.window")
end

-- Build the right-click context menu items for the given issue.
function M.items_for_issue(issue)
  local has_issue = issue ~= nil
  local key = issue and issue.key or "?"

  local items = {}

  if has_issue then
    table.insert(items, {
      name = "  Preview details",
      cmd = function() actions().preview_selected() end,
      rtxt = "⏎",
    })
    table.insert(items, {
      name = "  Open in browser",
      cmd = function() actions().open_selected() end,
      rtxt = "b",
    })
    table.insert(items, {
      name = "  Yank " .. key,
      cmd = function() actions().yank_selected() end,
      rtxt = "y",
      hl = "ExBlue",
    })
    table.insert(items, {
      name = "  Transition status",
      cmd = function() actions().transition_selected() end,
      rtxt = "t",
      hl = "ExYellow",
    })
    table.insert(items, { name = "separator" })

    table.insert(items, {
      name = "  Assign to me",
      cmd = function() actions().assign_selected_to_me() end,
      rtxt = "m",
      hl = "ExGreen",
    })
    table.insert(items, {
      name = "󰀄  Assign to someone…",
      cmd = function() actions().assign_selected_to_other() end,
      rtxt = "a",
    })

    local a = issue.fields and issue.fields.assignee
    if a and a ~= vim.NIL and a.accountId and a.accountId ~= vim.NIL then
      local label = a.displayName or a.emailAddress or "assignee"
      table.insert(items, {
        name = "󰀧  Unassign",
        cmd = function() actions().unassign_selected() end,
        rtxt = "u",
      })
      table.insert(items, {
        name = "  Filter by " .. label,
        cmd = function()
          local store = require("ledger.jira.board.store")
          store.set_filter(a.accountId, label)
          win().rerender()
        end,
      })
    end

    table.insert(items, { name = "separator" })
  end

  -- Global actions (always present)
  table.insert(items, {
    name = "󰁝  Clear assignee filter",
    cmd = function()
      local store = require("ledger.jira.board.store")
      if store.state.filter_assignee then
        store.set_filter(nil, nil)
        win().rerender()
      end
    end,
  })
  table.insert(items, {
    name = "  Toggle Backlog",
    cmd = function() actions().toggle_backlog() end,
    rtxt = "B",
  })
  table.insert(items, {
    name = "  Filter picker",
    cmd = function()
      local ok, filter = pcall(require, "jira-board.ui.filter_picker")
      if ok and filter.open then filter.open() end
    end,
    rtxt = "f",
  })
  table.insert(items, {
    name = "  Refresh",
    cmd = function() actions().refresh() end,
    rtxt = "R",
  })
  table.insert(items, { name = "separator" })
  table.insert(items, {
    name = "  Help",
    cmd = function() actions().show_help() end,
    rtxt = "?",
    hl = "ExBlue",
  })
  table.insert(items, {
    name = "  Close board",
    cmd = function() win().close() end,
    rtxt = "q",
    hl = "ExRed",
  })

  return items
end

function M.open_at_mouse()
  local ok, menu = pcall(require, "menu")
  if not ok then
    vim.notify("jira-board: nvzone/menu not installed", vim.log.levels.ERROR)
    return
  end
  pcall(require("menu.utils").delete_old_menus)

  -- Read card under the cursor BEFORE anything changes the mouse context.
  local band_idx, vidx, idx, issue = win().card_at_mouse()
  if band_idx and vidx and idx then
    win().on_card_click(band_idx, vidx, idx)
  end

  menu.open(M.items_for_issue(issue), { mouse = true })
end

return M
