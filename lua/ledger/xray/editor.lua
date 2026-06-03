local M = {}

local NS_NAME = "xray_edit_focus"

local _sessions = {}

local function clear_highlight(session)
  if session.ns and session.buf and vim.api.nvim_buf_is_valid(session.buf) then
    vim.api.nvim_buf_clear_namespace(session.buf, session.ns, 0, -1)
  end
end

local function render_focus(session)
  clear_highlight(session)
  if session.focus_idx < 1 then return end
  local r = session.regions[session.focus_idx]
  if not r then return end
  pcall(vim.api.nvim_buf_set_extmark, session.buf, session.ns, r.line, r.col_start, {
    end_col = r.col_end,
    hl_group = "XrayEditFocus",
    priority = 200,
  })
  if session.win and vim.api.nvim_win_is_valid(session.win) then
    pcall(vim.api.nvim_win_set_cursor, session.win, { r.line + 1, r.col_start })
  end
end

local function move(session, delta)
  if #session.regions == 0 then return end
  if session.focus_idx == 0 then
    session.focus_idx = delta > 0 and 1 or #session.regions
  else
    session.focus_idx = session.focus_idx + delta
    if session.focus_idx < 1 then session.focus_idx = #session.regions end
    if session.focus_idx > #session.regions then session.focus_idx = 1 end
  end
  render_focus(session)
end

local function activate(session)
  if session.focus_idx < 1 then return end
  local r = session.regions[session.focus_idx]
  if not r then return end
  if session.on_activate then
    session.on_activate(r, session)
  else
    vim.notify("xray: edit " .. (r.field or "?") .. " (not wired yet)", vim.log.levels.INFO)
  end
end

local function click_at(session, line, col)
  for i, r in ipairs(session.regions) do
    if line == r.line and col >= r.col_start and col < r.col_end then
      session.focus_idx = i
      render_focus(session)
      activate(session)
      return true
    end
  end
  return false
end

function M.attach(buf, win, regions, opts)
  opts = opts or {}
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  regions = regions or {}

  local session = {
    buf = buf,
    win = win,
    regions = regions,
    focus_idx = 0,
    ns = vim.api.nvim_create_namespace(NS_NAME .. "_" .. buf),
    on_activate = opts.on_activate,
    fallback_click = opts.fallback_click,
    key = opts.key,
  }
  _sessions[buf] = session

  local km = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "<Tab>", function() move(session, 1) end, km)
  vim.keymap.set("n", "<S-Tab>", function() move(session, -1) end, km)
  vim.keymap.set("n", "<Right>", function() move(session, 1) end, km)
  vim.keymap.set("n", "<Left>", function() move(session, -1) end, km)

  vim.keymap.set("n", "<CR>", function() activate(session) end, km)
  vim.keymap.set("n", "<LeftMouse>", function()
    local pos = vim.fn.getmousepos()
    if not pos or pos.winid ~= session.win then
      if opts.fallback_click then opts.fallback_click() end
      return
    end
    local handled = click_at(session, (pos.line or 1) - 1, (pos.column or 1) - 1)
    if not handled and opts.fallback_click then
      opts.fallback_click()
    end
  end, km)

  return session
end

function M.update(buf, regions)
  local s = _sessions[buf]
  if not s then return end
  s.regions = regions or {}
  s.focus_idx = 0
  clear_highlight(s)
end

function M.detach(buf)
  local s = _sessions[buf]
  if not s then return end
  clear_highlight(s)
  _sessions[buf] = nil
end

function M.focused(buf)
  local s = _sessions[buf]
  if not s or s.focus_idx < 1 then return nil end
  return s.regions[s.focus_idx]
end

return M
