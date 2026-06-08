local M = {}

local api = vim.api
local volt = require("volt")
local jutil = require("ledger.jira.util")
local store = require("ledger.jira.board.store")
local kanban = require("ledger.jira.board.ui.kanban")
local hl = require("ledger.jira.board.ui.hl")
local cfg = require("ledger.jira.board.config")

M._state = {
  buf = nil,
  win = nil,
  dim_buf = nil,
  dim_win = nil,
  ns = nil,
  layout = nil,
  built = nil,
  cursor = { band = 1, col = 1, idx = 1 },
}

local function close()
  local s = M._state
  if s.win and api.nvim_win_is_valid(s.win) then
    pcall(api.nvim_win_close, s.win, true)
  end
  if s.dim_win and api.nvim_win_is_valid(s.dim_win) then
    pcall(api.nvim_win_close, s.dim_win, true)
  end
  if s.buf and api.nvim_buf_is_valid(s.buf) then
    pcall(api.nvim_buf_delete, s.buf, { force = true })
  end
  if s.dim_buf and api.nvim_buf_is_valid(s.dim_buf) then
    pcall(api.nvim_buf_delete, s.dim_buf, { force = true })
  end
  M._state = {
    buf = nil,
    win = nil,
    dim_buf = nil,
    dim_win = nil,
    ns = nil,
    layout = nil,
    built = nil,
    cursor = { band = 1, col = 1, idx = 1 },
  }
end

-- Winbar (sticky header). Uses statusline syntax so it remains fixed at the
-- top of the board window regardless of scroll position.
function _G.JiraBoardCloseClick()
  require("ledger.jira.board.ui.window").close()
end

local function winbar_escape(s)
  return (s or ""):gsub("%%", "%%%%")
end

local function build_winbar()
  local st = store.state
  local title = st.board_name or "Jira Board"
  local total = store.total_filtered()
  local chips = {}
  if st.filter_assignee then
    table.insert(chips, st.filter_assignee_label or "me")
  end
  for _, s in ipairs(store.filter_summary()) do
    table.insert(chips, s)
  end
  if #chips == 0 then
    table.insert(chips, "all")
  end

  -- %N refers to the "default" winbar hl which we pin to JiraBoardWinBar via
  -- `winhighlight`. Using "%*" resets to the original WinBar (transparent in
  -- most themes) which is what was making the first line see-through.
  local N = "%#JiraBoardWinBar#"
  local parts = { N }
  table.insert(parts, "%#JiraBoardTitle# " .. winbar_escape(title) .. " " .. N)
  table.insert(parts, "%=")
  table.insert(parts, "%#JiraBoardMuted# " .. total .. " tickets " .. N .. " ")
  for _, c in ipairs(chips) do
    table.insert(parts, "%#JiraBoardFilterOn# " .. winbar_escape(c) .. " " .. N .. " ")
  end
  table.insert(parts, "%@v:lua.JiraBoardCloseClick@%#JiraBoardClose# ✕ " .. N .. "%X")
  return table.concat(parts)
end

local function refresh_winbar()
  local s = M._state
  if not (s.win and api.nvim_win_is_valid(s.win)) then
    return
  end
  vim.wo[s.win].winbar = build_winbar()
end

local CARD_H = require("ledger.jira.board.ui.card").CARD_HEIGHT

-- cursor.idx == 0 means the cursor sits on a collapsed band's header row.
local function find_first_valid_cursor(built)
  local bands = built and built.bands or {}
  for bi, b in ipairs(bands) do
    if b.collapsed then
      return { band = bi, col = 1, idx = 0 }
    end
    for ci = 1, built.ncols do
      local issues = b.issues_by_col[ci] or {}
      if #issues > 0 then
        return { band = bi, col = ci, idx = 1 }
      end
    end
  end
  return { band = 1, col = 1, idx = 1 }
end

local function valid_cursor(built, cur)
  local bands = built and built.bands or {}
  if #bands == 0 then
    return false
  end
  local b = bands[cur.band]
  if not b then
    return false
  end
  if b.collapsed then
    return cur.idx == 0
  end
  local issues = b.issues_by_col[cur.col] or {}
  return cur.idx >= 1 and cur.idx <= #issues
end

local function snap_cursor(built, cur)
  if valid_cursor(built, cur) then
    return cur
  end
  local bands = built and built.bands or {}
  if #bands == 0 then
    return { band = 1, col = 1, idx = 1 }
  end

  -- Prefer staying within the current band if it can still hold the cursor.
  local b = bands[cur.band]
  if b then
    if b.collapsed then
      return { band = cur.band, col = math.max(1, cur.col), idx = 0 }
    end
    local issues = b.issues_by_col[cur.col] or {}
    if #issues > 0 then
      return { band = cur.band, col = cur.col, idx = math.min(math.max(cur.idx, 1), #issues) }
    end
    for ci = 1, built.ncols do
      local iss = b.issues_by_col[ci] or {}
      if #iss > 0 then
        return { band = cur.band, col = ci, idx = 1 }
      end
    end
  end

  local col = cur.col
  if col < 1 or col > built.ncols then
    col = 1
  end
  local best, best_dist = nil, math.huge
  for bi, bd in ipairs(bands) do
    local this_idx
    if bd.collapsed then
      this_idx = 0
    else
      local issues = bd.issues_by_col[col] or {}
      if #issues > 0 then
        this_idx = math.min(cur.idx, #issues)
      end
    end
    if this_idx then
      local d = math.abs(bi - cur.band)
      if d < best_dist then
        best_dist = d
        best = { band = bi, col = col, idx = this_idx }
      end
    end
  end
  if best then
    return best
  end
  return find_first_valid_cursor(built)
end

function M.selected_issue()
  local cur = M._state.cursor
  local built = M._state.built
  if not (built and built.bands and built.bands[cur.band]) then
    return nil
  end
  if cur.idx == 0 then
    return nil
  end
  local issues = built.bands[cur.band].issues_by_col[cur.col] or {}
  return issues[cur.idx]
end

function M.on_card_click(band_idx, col_idx, card_idx)
  local s = M._state
  if not (s.win and api.nvim_win_is_valid(s.win)) then
    return
  end
  s.cursor.band = band_idx
  s.cursor.col = col_idx
  s.cursor.idx = card_idx
  M.rerender()
end

local function card_at_mouse()
  local pos = vim.fn.getmousepos()
  local s = M._state
  if not (s.win and s.built and s.layout) then
    return nil
  end
  if pos.winid ~= s.win then
    return nil
  end
  local line = pos.line -- 1-based buffer line
  local col_w = s.built.col_w
  local grid_row = (s.layout[1] and s.layout[1].row) or 0
  local grel = line - 1 - grid_row
  if grel < 0 then
    return nil
  end
  local target_band = nil
  for bi, b in ipairs(s.built.bands or {}) do
    if grel >= b.start_row and grel <= b.end_row then
      target_band = { idx = bi, band = b }
      break
    end
  end
  if not target_band then
    return nil
  end
  local b = target_band.band
  local cards_row_start = b.start_row + b.cards_offset
  if grel < cards_row_start then
    return nil
  end
  local rel = grel - cards_row_start
  local card_idx = math.floor(rel / CARD_H) + 1
  local x = pos.wincol - 1
  local vidx = math.floor(x / (col_w + 1)) + 1
  if vidx < 1 or vidx > s.built.ncols then
    return nil
  end
  local issues = b.issues_by_col[vidx] or {}
  if card_idx < 1 or card_idx > #issues then
    return nil
  end
  return target_band.idx, vidx, card_idx, issues[card_idx]
end

function M.card_at_mouse()
  return card_at_mouse()
end

local function land_on_band(cur, band_idx, built, step)
  local band = built.bands[band_idx]
  if band.collapsed then
    cur.band = band_idx
    cur.idx = 0
    return true
  end
  local issues = band.issues_by_col[cur.col] or {}
  if #issues > 0 then
    cur.band = band_idx
    cur.idx = (step == 1) and 1 or #issues
    return true
  end
  for ci = 1, built.ncols do
    local iss = band.issues_by_col[ci] or {}
    if #iss > 0 then
      cur.band = band_idx
      cur.col = ci
      cur.idx = (step == 1) and 1 or #iss
      return true
    end
  end
  return false
end

function M.move(dir)
  local s = M._state
  local cur = s.cursor
  local built = s.built
  if not built or not built.bands or #built.bands == 0 then
    return
  end
  local ncols = built.ncols
  local band = built.bands[cur.band]
  if not band then
    return
  end

  if dir == "right" or dir == "left" then
    if band.collapsed then
      return
    end
    local step = (dir == "right") and 1 or -1
    local new_col = cur.col
    for _ = 1, ncols do
      new_col = ((new_col - 1 + step) % ncols) + 1
      local issues = band.issues_by_col[new_col] or {}
      if #issues > 0 then
        cur.col = new_col
        cur.idx = math.min(cur.idx, #issues)
        M.rerender()
        return
      end
    end
    return
  end

  if dir == "down" or dir == "up" then
    local step = (dir == "down") and 1 or -1
    if not band.collapsed then
      local issues = band.issues_by_col[cur.col] or {}
      local new_idx = cur.idx + step
      if new_idx >= 1 and new_idx <= #issues then
        cur.idx = new_idx
        M.rerender()
        return
      end
    end
    local bi = cur.band + step
    while bi >= 1 and bi <= #built.bands do
      if land_on_band(cur, bi, built, step) then
        M.rerender()
        return
      end
      bi = bi + step
    end
    return
  end
end

local function build_layout(built)
  return { {
    name = "grid",
    lines = function()
      return built.grid
    end,
  } }
end

function M.rerender()
  local s = M._state
  if not (s.buf and api.nvim_buf_is_valid(s.buf)) then
    return
  end
  local issue = M.selected_issue()
  local key = issue and issue.key or nil
  local built = kanban.build({ selected_card_key = key, screen_w = vim.o.columns })
  s.built = built

  s.cursor = snap_cursor(built, s.cursor)
  local new_issue = M.selected_issue()
  if new_issue and new_issue.key ~= key then
    built = kanban.build({ selected_card_key = new_issue.key, screen_w = vim.o.columns })
    s.built = built
  end

  api.nvim_set_option_value("modifiable", true, { buf = s.buf })

  s.layout = build_layout(built)
  volt.gen_data({ {
    buf = s.buf,
    xpad = 0,
    layout = s.layout,
    ns = s.ns,
  } })
  local total_h = require("volt.state")[s.buf].h
  volt.set_empty_lines(s.buf, total_h, built.board_w)
  volt.redraw(s.buf, "all")
  api.nvim_set_option_value("modifiable", false, { buf = s.buf })

  -- Resize window so it never exceeds screen; keep content scrollable inside.
  if s.win and api.nvim_win_is_valid(s.win) then
    local screen_w = vim.o.columns
    local screen_h = vim.o.lines
    local w = math.min(built.board_w, screen_w - 6)
    local h = math.min(total_h, screen_h - 6)
    local row = math.floor((screen_h - h) / 2) - 1
    local col = math.floor((screen_w - w) / 2)
    pcall(api.nvim_win_set_config, s.win, {
      relative = "editor",
      row = row,
      col = col,
      width = w,
      height = h,
    })
  end

  refresh_winbar()
  M.move_cursor_to_selection()
end

function M.move_cursor_to_selection()
  local s = M._state
  if not (s.win and api.nvim_win_is_valid(s.win)) then
    return
  end
  if not (s.built and s.layout) then
    return
  end
  local cur = s.cursor
  local built = s.built
  local band = built.bands and built.bands[cur.band]
  if not band then
    return
  end
  local grid_row = (s.layout[1] and s.layout[1].row) or 0
  local row_0, col_x
  if band.collapsed or cur.idx == 0 then
    row_0 = grid_row + band.start_row
    col_x = 0
  else
    col_x = (cur.col - 1) * (built.col_w + 1)
    row_0 = grid_row + band.start_row + band.cards_offset + (cur.idx - 1) * CARD_H
  end
  local row_1 = row_0 + 1
  local maxrow = api.nvim_buf_line_count(s.buf)
  if row_1 > maxrow then
    row_1 = maxrow
  end
  if row_1 < 1 then
    row_1 = 1
  end
  pcall(api.nvim_win_set_cursor, s.win, { row_1, col_x })
end

local function set_keymaps(buf)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", close)
  map("<Esc>", close)
  map("<Tab>", function()
    M.move("right")
  end)
  map("<S-Tab>", function()
    M.move("left")
  end)
  map("l", function()
    M.move("right")
  end)
  map("h", function()
    M.move("left")
  end)
  map("j", function()
    M.move("down")
  end)
  map("k", function()
    M.move("up")
  end)
  map("<Down>", function()
    M.move("down")
  end)
  map("<Up>", function()
    M.move("up")
  end)
  map("<Right>", function()
    M.move("right")
  end)
  map("<Left>", function()
    M.move("left")
  end)
  map("<CR>", function()
    require("ledger.jira.board.actions").preview_selected()
  end)
  map("b", function()
    require("ledger.jira.board.actions").open_selected()
  end)
  map("y", function()
    require("ledger.jira.board.actions").yank_selected()
  end)
  map("R", function()
    require("ledger.jira.board.actions").refresh()
  end)
  map("A", function()
    require("ledger.jira.board.actions").toggle_assignee_filter()
  end)
  map("B", function()
    require("ledger.jira.board.actions").toggle_backlog()
  end)
  map("f", function()
    require("ledger.jira.board.ui.filter_picker").open()
  end)
  map("t", function()
    require("ledger.jira.board.actions").transition_selected()
  end)
  map("p", function()
    require("ledger.jira.board.actions").preview_selected()
  end)
  map("m", function()
    require("ledger.jira.board.actions").assign_selected_to_me()
  end)
  map("a", function()
    require("ledger.jira.board.actions").assign_selected_to_other()
  end)
  map("u", function()
    require("ledger.jira.board.actions").unassign_selected()
  end)
  map("z", function()
    require("ledger.jira.board.actions").toggle_epic_at_cursor()
  end)
  map("Z", function()
    require("ledger.jira.board.actions").toggle_all_epics()
  end)
  map("?", function()
    require("ledger.jira.board.actions").show_help()
  end)
  map("<C-l>", function()
    M.rerender()
  end)
  map("<RightMouse>", function()
    require("ledger.jira.board.ui.menu").open_at_mouse()
  end)
  map("<RightRelease>", function() end)
  map("<2-LeftMouse>", function()
    -- The first LeftMouse already moved the cursor onto the clicked card
    -- (via volt's card click action). Open the preview for the selection.
    local issue = M.selected_issue()
    if not issue then
      return
    end
    require("ledger.jira.board.actions").preview_selected()
  end)
end

local function open_dim_backdrop()
  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, false, {
    focusable = false,
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines - 2,
    relative = "editor",
    style = "minimal",
    border = "none",
    zindex = 20,
  })
  vim.wo[win].winblend = cfg.get().backdrop_blend or 30
  return buf, win
end

local function open_main(board_w, total_h)
  local screen_w = vim.o.columns
  local screen_h = vim.o.lines
  local w = math.min(board_w, screen_w - 6)
  local h = math.min(total_h, screen_h - 6)
  local row = math.floor((screen_h - h) / 2) - 1
  local col = math.floor((screen_w - w) / 2)
  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = w,
    height = h,
    style = "minimal",
    border = "single",
    zindex = 30,
  })
  jutil.clean_float_window(win)
  vim.wo[win].cursorline = false
  -- Pin the winbar background so our sticky header is opaque.
  vim.wo[win].winhighlight = "Normal:JiraBoardNormal,FloatBorder:JiraBoardBorder,"
    .. "WinBar:JiraBoardWinBar,WinBarNC:JiraBoardWinBar"
  vim.bo[buf].filetype = "jira-board"
  return buf, win
end

function M.open()
  close()
  local built = kanban.build({ screen_w = vim.o.columns })
  M._state.built = built
  M._state.cursor = find_first_valid_cursor(built)

  local dim_buf, dim_win = open_dim_backdrop()

  local layout = build_layout(built)
  -- +1 leaves room for the sticky winbar at the top of the window.
  local buf, win = open_main(built.board_w, built.board_h + 1)
  local ns = api.nvim_create_namespace("jira_board_hl")

  M._state.buf = buf
  M._state.win = win
  M._state.dim_buf = dim_buf
  M._state.dim_win = dim_win
  M._state.ns = ns
  M._state.layout = layout

  hl.define(ns)
  api.nvim_win_set_hl_ns(win, ns)
  api.nvim_set_hl(ns, "FloatBorder", { link = "JiraBoardBorder" })
  api.nvim_set_hl(ns, "Normal", { link = "JiraBoardNormal" })

  -- Sticky header via winbar (fixed at top of the window, does not scroll).
  vim.wo[win].winbar = build_winbar()

  api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })

  volt.gen_data({ { buf = buf, xpad = 0, layout = layout, ns = ns } })
  local total_h = require("volt.state")[buf].h
  volt.run(buf, { h = total_h, w = built.board_w })

  do
    local screen_w = vim.o.columns
    local screen_h = vim.o.lines
    local w = math.min(built.board_w, screen_w - 6)
    local h = math.min(total_h, screen_h - 6)
    local row = math.floor((screen_h - h) / 2) - 1
    local col = math.floor((screen_w - w) / 2)
    pcall(api.nvim_win_set_config, win, {
      relative = "editor",
      row = row,
      col = col,
      width = w,
      height = h,
    })
  end

  local volt_events = require("volt.events")
  volt_events.add(buf)
  volt_events.enable()

  set_keymaps(buf)

  M.move_cursor_to_selection()
end

function M.close()
  close()
end

function M.is_open()
  return M._state.win and api.nvim_win_is_valid(M._state.win)
end

function M.lock_scroll()
  local s = M._state
  if not (s.buf and api.nvim_buf_is_valid(s.buf)) then
    return
  end
  for _, lhs in ipairs({ "<ScrollWheelUp>", "<ScrollWheelDown>", "<ScrollWheelLeft>", "<ScrollWheelRight>" }) do
    pcall(vim.keymap.set, "n", lhs, function() end, { buffer = s.buf, nowait = true, silent = true })
  end
end

function M.unlock_scroll()
  local s = M._state
  if not (s.buf and api.nvim_buf_is_valid(s.buf)) then
    return
  end
  for _, lhs in ipairs({ "<ScrollWheelUp>", "<ScrollWheelDown>", "<ScrollWheelLeft>", "<ScrollWheelRight>" }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = s.buf })
  end
end

return M
