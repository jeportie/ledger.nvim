local M = {}

local store = require("ledger.jira.board.store")
local api = require("ledger.jira.api")
local jutil = require("ledger.jira.util")
local status_picker = require("ledger.jira.pickers.status")

local function get_window()
  return require("ledger.jira.board.ui.window")
end

local function notify(msg, level)
  vim.notify("jira-board: " .. msg, level or vim.log.levels.INFO)
end

function M.open_selected()
  local issue = get_window().selected_issue()
  if not issue then return end
  jutil.open_url(jutil.ticket_url(issue.key))
end

function M.yank_selected()
  local issue = get_window().selected_issue()
  if not issue then return end
  vim.fn.setreg("+", issue.key)
  vim.fn.setreg('"', issue.key)
  notify("yanked " .. issue.key)
end

local function refetch_issues(cb)
  local agile = require("ledger.jira.agile")
  local st = store.state
  if not st.board_id then cb("no board loaded"); return end
  agile.get_all_board_issues(st.board_id, {
    fields = "summary,status,priority,assignee,issuetype,labels,updated,parent",
    page_cap = 10,
  }, function(issues, err)
    if err then cb(err); return end
    store.set_issues(issues or {})
    cb(nil)
  end)
end

function M.refresh()
  notify("refreshing…")
  refetch_issues(function(err)
    if err then notify("refresh failed: " .. tostring(err), vim.log.levels.ERROR); return end
    vim.schedule(function()
      if get_window().is_open() then get_window().rerender() end
    end)
  end)
end

function M.toggle_assignee_filter()
  local st = store.state
  if st.filter_assignee then
    store.set_filter(nil, nil)
    get_window().rerender()
    notify("showing all assignees")
    return
  end

  local function apply_me()
    if st.me and st.me.accountId then
      store.set_filter(st.me.accountId, st.me.label)
      get_window().rerender()
      notify("filtered: " .. (st.me.label or "me"))
    else
      notify("could not resolve current user", vim.log.levels.ERROR)
    end
  end

  if st.me and st.me.accountId then
    apply_me()
  else
    api.get_myself(function(me, err)
      if err or not me then
        notify("whoami failed: " .. tostring(err), vim.log.levels.ERROR); return
      end
      local urls = me.avatarUrls or {}
      local avatar_url = urls["48x48"] or urls["32x32"] or urls["24x24"] or urls["16x16"]
      store.set_me(me.accountId, me.displayName or me.emailAddress or "me", avatar_url)
      vim.schedule(apply_me)
    end)
  end
end

function M.transition_selected()
  local issue = get_window().selected_issue()
  if not issue then return end
  local cur_status = issue.fields and issue.fields.status and issue.fields.status.name
  status_picker.open(issue.key, cur_status, function(to_name, err)
    if err or not to_name then return end
    vim.schedule(function()
      notify("refreshing after transition…")
      refetch_issues(function(rerr)
        if rerr then
          notify("refresh failed: " .. tostring(rerr), vim.log.levels.ERROR); return
        end
        vim.schedule(function()
          if get_window().is_open() then get_window().rerender() end
        end)
      end)
    end)
  end)
end

local function refresh_and_rerender()
  refetch_issues(function(rerr)
    if rerr then
      notify("refresh failed: " .. tostring(rerr), vim.log.levels.ERROR); return
    end
    vim.schedule(function()
      if get_window().is_open() then get_window().rerender() end
    end)
  end)
end

local function ensure_me(cb)
  local st = store.state
  if st.me and st.me.accountId then return cb(st.me) end
  api.get_myself(function(me, err)
    if err or not me or not me.accountId then
      notify("whoami failed: " .. tostring(err or "no accountId"), vim.log.levels.ERROR)
      return
    end
    local urls = me.avatarUrls or {}
    local avatar_url = urls["48x48"] or urls["32x32"] or urls["24x24"] or urls["16x16"]
    store.set_me(me.accountId, me.displayName or me.emailAddress or "me", avatar_url)
    vim.schedule(function() cb(store.state.me) end)
  end)
end

function M.assign_selected_to_me()
  local issue = get_window().selected_issue()
  if not issue then return end
  ensure_me(function(me)
    api.set_assignee(issue.key, me.accountId, function(_, err)
      if err then
        notify("assign failed: " .. tostring(err), vim.log.levels.ERROR); return
      end
      notify(issue.key .. " ← " .. (me.label or "me"))
      refresh_and_rerender()
    end)
  end)
end

function M.assign_selected_to_other()
  local issue = get_window().selected_issue()
  if not issue then return end
  local picker = require("ledger.jira.pickers.assignee")
  local cur = issue.fields and issue.fields.assignee
  local current_assignee = nil
  if cur and cur ~= vim.NIL and cur.accountId and cur.accountId ~= vim.NIL then
    current_assignee = { accountId = cur.accountId }
  end
  picker.open(issue.key, current_assignee, function(result, err)
    if err or not result then return end
    refresh_and_rerender()
  end)
end

function M.unassign_selected()
  local issue = get_window().selected_issue()
  if not issue then return end
  api.set_assignee(issue.key, nil, function(_, err)
    if err then
      notify("unassign failed: " .. tostring(err), vim.log.levels.ERROR); return
    end
    notify(issue.key .. " ← Unassigned")
    refresh_and_rerender()
  end)
end

function M.show_help()
  require("ledger.jira.board.ui.help").toggle()
end

function M.preview_selected()
  local issue = get_window().selected_issue()
  if not issue then return end
  local ok, preview = pcall(require, "jira-board.ui.preview")
  if ok and preview.open then
    preview.open(issue)
  else
    notify("preview not available yet")
  end
end

function M.toggle_backlog()
  local hidden = store.toggle_backlog()
  local win = get_window()
  -- Reset cursor; rerender will snap it to the first valid card.
  win._state.cursor = { band = 1, col = 1, idx = 1 }
  win.rerender()
  notify(hidden and "Backlog hidden" or "Backlog visible")
end

function M.toggle_epic(key)
  store.toggle_epic_collapsed(key)
  get_window().rerender()
end

function M.toggle_epic_at_cursor()
  local win = get_window()
  local s = win._state
  local built = s.built
  if not (built and built.bands) then return end
  local band = built.bands[s.cursor.band]
  if not band then return end
  -- After collapsing, the cursor should sit on the header so a follow-up z
  -- can re-expand without having to navigate back.
  s.cursor.idx = 0
  M.toggle_epic(band.key)
end

function M.collapse_all_epics()
  store.set_all_epics_collapsed(true)
  local win = get_window()
  win._state.cursor = { band = 1, col = 1, idx = 0 }
  win.rerender()
end

function M.expand_all_epics()
  store.set_all_epics_collapsed(false)
  get_window().rerender()
end

-- Z: if every epic is already collapsed, expand all — otherwise collapse all.
function M.toggle_all_epics()
  if store.all_epics_collapsed() then
    M.expand_all_epics()
  else
    M.collapse_all_epics()
  end
end

return M
