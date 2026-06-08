local M = {}

local config = require("ledger.jira.board.config")
local store = require("ledger.jira.board.store")
local jira_cfg = require("ledger.jira.config")
local agile = require("ledger.jira.agile")
local jira_api = require("ledger.jira.api")

local function notify(msg, level)
  vim.notify("jira-board: " .. msg, level or vim.log.levels.INFO)
end

function M.setup(opts)
  config.setup(opts)
  jira_cfg.setup({})
end

-- Normalize the board configuration payload to { {name, status_ids}, ... }.
-- Board config only exposes status IDs, so we match by id on the issue side.
local function columns_from_config(data)
  local cols = {}
  local board_cols = (data and data.columnConfig and data.columnConfig.columns) or {}
  for _, col in ipairs(board_cols) do
    local ids = {}
    for _, s in ipairs(col.statuses or {}) do
      if s.id then
        table.insert(ids, tostring(s.id))
      end
    end
    table.insert(cols, { name = col.name, status_ids = ids })
  end
  return cols
end

local function resolve_board_id(cb)
  local c = config.get()
  if c.board_id then
    cb(c.board_id, c.board_name or ("board " .. c.board_id))
    return
  end

  local function pick_from(values, label)
    if not values or #values == 0 then
      cb(nil, nil, "no boards found" .. (label and (" for " .. label) or ""))
      return
    end
    if c.board_name then
      for _, b in ipairs(values) do
        if b.name == c.board_name then
          cb(b.id, b.name)
          return
        end
      end
    end
    cb(values[1].id, values[1].name)
  end

  if c.board_name then
    agile.find_boards({ name = c.board_name, project = c.project_key }, function(data, err)
      if err then
        cb(nil, nil, err)
        return
      end
      pick_from((data or {}).values, c.board_name)
    end)
  else
    agile.find_boards({ project = c.project_key }, function(data, err)
      if err then
        cb(nil, nil, err)
        return
      end
      pick_from((data or {}).values, c.project_key)
    end)
  end
end

local function load_columns(board_id, cb)
  agile.get_board_config(board_id, function(data, err)
    if err then
      cb(err)
      return
    end
    local cols = columns_from_config(data)
    if #cols == 0 then
      cb("board has no columns")
      return
    end
    store.set_columns(cols)
    cb(nil)
  end)
end

local function load_issues(board_id, cb)
  agile.get_all_board_issues(board_id, {
    fields = "summary,status,priority,assignee,issuetype,labels,updated,parent",
    page_cap = config.get().page_cap,
  }, function(issues, err)
    if err then
      cb(err)
      return
    end
    store.set_issues(issues or {})
    cb(nil)
  end)
end

local function ensure_me(cb)
  if store.state.me and store.state.me.accountId then
    return cb()
  end
  jira_api.get_myself(function(me, err)
    if not err and me and me.accountId then
      local urls = me.avatarUrls or {}
      local avatar_url = urls["48x48"] or urls["32x32"] or urls["24x24"] or urls["16x16"]
      store.set_me(me.accountId, me.displayName or me.emailAddress or "me", avatar_url)
    end
    cb()
  end)
end

function M.open()
  notify("loading board…")
  resolve_board_id(function(id, name, err)
    if err or not id then
      notify("could not resolve board: " .. tostring(err or "unknown"), vim.log.levels.ERROR)
      return
    end
    store.set_board(id, name)
    load_columns(id, function(cerr)
      if cerr then
        notify(tostring(cerr), vim.log.levels.ERROR)
        return
      end
      load_issues(id, function(ierr)
        if ierr then
          notify(tostring(ierr), vim.log.levels.ERROR)
          return
        end
        ensure_me(function()
          vim.schedule(function()
            require("ledger.jira.board.ui.window").open()
          end)
        end)
      end)
    end)
  end)
end

function M.close()
  require("ledger.jira.board.ui.window").close()
end

return M
