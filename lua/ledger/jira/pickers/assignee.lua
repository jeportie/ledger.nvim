local M = {}

local api = require("ledger.jira.api")
local util = require("ledger.jira.util")

local DEBOUNCE_MS = 200

local _state = nil

local function fresh_state()
  return {
    key = nil,
    prompt_buf = nil,
    prompt_win = nil,
    results_buf = nil,
    results_win = nil,
    ns = nil,
    closed = false,
    search_token = 0,
    me = nil,
    current_account_id = nil,
    pinned = {},
    results = {},
    entries = {},
    selected_idx = 1,
    on_done = nil,
    autocmds = {},
    parent_win = nil,
  }
end

local function is_open()
  return _state and _state.prompt_win and vim.api.nvim_win_is_valid(_state.prompt_win)
end

local function do_close(restore)
  if not _state or _state.closed then
    return
  end
  _state.closed = true
  local parent_win = _state.parent_win
  for _, id in ipairs(_state.autocmds) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  for _, win in ipairs({ _state.prompt_win, _state.results_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ _state.prompt_buf, _state.results_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if restore ~= false and parent_win and vim.api.nvim_win_is_valid(parent_win) then
    pcall(vim.api.nvim_set_current_win, parent_win)
  end
end

local function cancel_and_close(restore)
  if not _state then
    return
  end
  local on_done = _state.on_done
  _state.on_done = nil
  do_close(restore)
  if on_done then
    pcall(on_done, nil, nil)
  end
end

local function build_entries()
  local entries = {}
  local seen = {}
  for _, p in ipairs(_state.pinned) do
    local id = p.accountId or "_unassigned"
    if not seen[id] then
      seen[id] = true
      table.insert(entries, p)
    end
  end
  for _, r in ipairs(_state.results) do
    local id = r.accountId
    if id and not seen[id] then
      seen[id] = true
      table.insert(entries, {
        accountId = id,
        displayName = r.displayName or r.emailAddress or "?",
        email = r.emailAddress,
        marker = " ",
      })
    end
  end
  _state.entries = entries
  if #entries == 0 then
    _state.selected_idx = 0
  elseif _state.selected_idx < 1 or _state.selected_idx > #entries then
    _state.selected_idx = 1
  end
end

local function format_entry(e)
  local marker = e.marker or " "
  local name = e.displayName or "?"
  local suffix = e.suffix and (" " .. e.suffix) or ""
  local tag = ""
  if _state.current_account_id == nil and e.accountId == nil then
    tag = "  ← current"
  elseif _state.current_account_id and e.accountId == _state.current_account_id then
    tag = "  ← current"
  end
  return string.format("  %s  %s%s%s", marker, name, suffix, tag)
end

local function render_results()
  if not _state.results_buf or not vim.api.nvim_buf_is_valid(_state.results_buf) then
    return
  end
  local lines = {}
  if #_state.entries == 0 then
    lines = { "  (no matches)" }
  else
    for _, e in ipairs(_state.entries) do
      table.insert(lines, format_entry(e))
    end
  end
  vim.bo[_state.results_buf].modifiable = true
  vim.api.nvim_buf_set_lines(_state.results_buf, 0, -1, false, lines)
  vim.bo[_state.results_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(_state.results_buf, _state.ns, 0, -1)
  if #_state.entries > 0 and _state.selected_idx >= 1 then
    pcall(vim.api.nvim_buf_set_extmark, _state.results_buf, _state.ns, _state.selected_idx - 1, 0, {
      line_hl_group = "XraySelected",
    })
    if _state.results_win and vim.api.nvim_win_is_valid(_state.results_win) then
      pcall(vim.api.nvim_win_set_cursor, _state.results_win, { _state.selected_idx, 0 })
    end
  end
end

local function get_query()
  if not _state.prompt_buf or not vim.api.nvim_buf_is_valid(_state.prompt_buf) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(_state.prompt_buf, 0, 1, false)
  return (lines[1] or ""):gsub("^> ", "")
end

local function schedule_search(query)
  _state.search_token = _state.search_token + 1
  local token = _state.search_token
  if query == "" then
    _state.results = {}
    build_entries()
    render_results()
    return
  end
  vim.defer_fn(function()
    if not _state or _state.closed or token ~= _state.search_token then
      return
    end
    api.search_users(query, function(data, err)
      if not _state or _state.closed or token ~= _state.search_token then
        return
      end
      if err then
        vim.notify(err, vim.log.levels.WARN)
        return
      end
      _state.results = (type(data) == "table" and data) or {}
      build_entries()
      render_results()
    end)
  end, DEBOUNCE_MS)
end

local function on_prompt_changed()
  schedule_search(get_query())
end

local function move(delta)
  if #_state.entries == 0 then
    return
  end
  _state.selected_idx = math.max(1, math.min(#_state.entries, _state.selected_idx + delta))
  render_results()
end

local function focus_prompt_insert()
  if not _state or not _state.prompt_win or not vim.api.nvim_win_is_valid(_state.prompt_win) then
    return
  end
  vim.api.nvim_set_current_win(_state.prompt_win)
  vim.cmd("startinsert!")
  local query = get_query()
  pcall(vim.api.nvim_win_set_cursor, _state.prompt_win, { 1, #query + 2 })
end

local function confirm()
  if not _state then
    return
  end
  local entry = _state.entries[_state.selected_idx]
  if not entry then
    return
  end
  local key = _state.key
  local on_done = _state.on_done
  local setter = _state.setter or api.set_assignee
  local label_prefix = _state.title or "Assign"
  _state.on_done = nil
  do_close()
  setter(key, entry.accountId, function(_, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      if on_done then
        pcall(on_done, nil, err)
      end
      return
    end
    local label = entry.accountId and entry.displayName or "Unassigned"
    vim.notify(string.format("xray: %s %s ← %s", key, label_prefix, label), vim.log.levels.INFO)
    if on_done then
      pcall(on_done, { accountId = entry.accountId, displayName = entry.displayName }, nil)
    end
  end)
end

local function handle_mouse_click()
  if not _state then
    return
  end
  local pos = vim.fn.getmousepos()
  if not pos or not pos.winid or pos.winid == 0 then
    return
  end
  if pos.winid == _state.prompt_win then
    focus_prompt_insert()
  elseif pos.winid == _state.results_win then
    if pos.line and pos.line >= 1 and pos.line <= #_state.entries then
      _state.selected_idx = pos.line
      confirm()
    end
  end
end

function M.close()
  cancel_and_close()
end

function M.open(key, current_assignee, on_done, opts)
  opts = opts or {}
  if is_open() then
    do_close()
  end
  local parent_win = vim.api.nvim_get_current_win()
  _state = fresh_state()
  _state.key = key
  _state.on_done = on_done
  _state.current_account_id = current_assignee and current_assignee.accountId or nil
  _state.ns = vim.api.nvim_create_namespace("xray_assignee_picker")
  _state.parent_win = parent_win
  _state.setter = opts.setter
  _state.title = opts.title

  _state.pinned = {
    { accountId = nil, displayName = "Unassigned", marker = "○" },
  }

  local width = 54
  local prompt_h = 1
  local results_h = 12
  local total_w = vim.o.columns
  local total_h = vim.o.lines
  local outer_h = prompt_h + results_h + 4
  local row, col
  if opts.anchor == "cursor" then
    local a = util.screen_cursor_anchor(width + 2, outer_h)
    row, col = a.row, a.col
  else
    row = math.max(0, math.floor((total_h - outer_h) / 2) - 1)
    col = math.max(0, math.floor((total_w - width) / 2))
  end

  _state.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[_state.prompt_buf].buftype = "nofile"
  vim.bo[_state.prompt_buf].bufhidden = "wipe"
  util.disable_completion(_state.prompt_buf)
  vim.api.nvim_buf_set_lines(_state.prompt_buf, 0, -1, false, { "> " })
  _state.prompt_win = vim.api.nvim_open_win(_state.prompt_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = prompt_h,
    style = "minimal",
    border = "rounded",
    title = " " .. (_state.title or "Assign") .. " " .. key .. " — search users ",
    title_pos = "left",
    zindex = 260,
  })
  util.clean_float_window(_state.prompt_win)
  vim.wo[_state.prompt_win].winhighlight = "FloatBorder:XrayBorder,FloatTitle:XrayTitleFloat,NormalFloat:XrayNormal"

  _state.results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[_state.results_buf].buftype = "nofile"
  vim.bo[_state.results_buf].bufhidden = "wipe"
  util.disable_completion(_state.results_buf)
  _state.results_win = vim.api.nvim_open_win(_state.results_buf, false, {
    relative = "editor",
    row = row + prompt_h + 2,
    col = col,
    width = width,
    height = results_h,
    style = "minimal",
    border = "rounded",
    focusable = true,
    footer = " <CR> assign   <Esc> cancel ",
    footer_pos = "right",
    zindex = 260,
  })
  util.clean_float_window(_state.results_win)
  vim.wo[_state.results_win].winhighlight = "FloatBorder:XrayBorder,FloatFooter:XrayFooter,NormalFloat:XrayNormal"

  local p_opts = { buffer = _state.prompt_buf, nowait = true, silent = true }
  local r_opts = { buffer = _state.results_buf, nowait = true, silent = true }

  local down = function()
    move(1)
  end
  local up = function()
    move(-1)
  end

  vim.keymap.set({ "i", "n" }, "<Esc>", cancel_and_close, p_opts)
  vim.keymap.set("n", "q", cancel_and_close, p_opts)
  vim.keymap.set({ "i", "n" }, "<CR>", confirm, p_opts)
  vim.keymap.set({ "i", "n" }, "<Down>", down, p_opts)
  vim.keymap.set({ "i", "n" }, "<Up>", up, p_opts)
  vim.keymap.set({ "i", "n" }, "<C-n>", down, p_opts)
  vim.keymap.set({ "i", "n" }, "<C-p>", up, p_opts)
  vim.keymap.set({ "i", "n" }, "<LeftMouse>", handle_mouse_click, p_opts)
  vim.keymap.set({ "i", "n" }, "<ScrollWheelDown>", function()
    move(3)
  end, p_opts)
  vim.keymap.set({ "i", "n" }, "<ScrollWheelUp>", function()
    move(-3)
  end, p_opts)
  vim.keymap.set("n", "j", down, p_opts)
  vim.keymap.set("n", "k", up, p_opts)
  vim.keymap.set("n", "i", focus_prompt_insert, p_opts)
  vim.keymap.set("n", "a", focus_prompt_insert, p_opts)

  vim.keymap.set("n", "<Esc>", cancel_and_close, r_opts)
  vim.keymap.set("n", "q", cancel_and_close, r_opts)
  vim.keymap.set("n", "<CR>", confirm, r_opts)
  vim.keymap.set("n", "<LeftMouse>", handle_mouse_click, r_opts)
  vim.keymap.set("n", "<ScrollWheelDown>", function()
    move(3)
  end, r_opts)
  vim.keymap.set("n", "<ScrollWheelUp>", function()
    move(-3)
  end, r_opts)
  vim.keymap.set("n", "j", down, r_opts)
  vim.keymap.set("n", "k", up, r_opts)

  table.insert(
    _state.autocmds,
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = _state.prompt_buf,
      callback = function()
        local line = vim.api.nvim_buf_get_lines(_state.prompt_buf, 0, 1, false)[1] or ""
        if not line:match("^> ") then
          vim.api.nvim_buf_set_lines(_state.prompt_buf, 0, 1, false, { "> " .. line })
          pcall(vim.api.nvim_win_set_cursor, _state.prompt_win, { 1, #line + 2 })
        end
        on_prompt_changed()
      end,
    })
  )
  table.insert(
    _state.autocmds,
    vim.api.nvim_create_autocmd("WinClosed", {
      callback = function(args)
        if not _state then
          return
        end
        local win = tonumber(args.match)
        if win == _state.prompt_win or win == _state.results_win then
          vim.schedule(cancel_and_close)
        end
      end,
    })
  )

  local on_win_leave = function()
    vim.schedule(function()
      if not _state or _state.closed then
        return
      end
      local cur = vim.api.nvim_get_current_win()
      if cur == _state.prompt_win or cur == _state.results_win then
        return
      end
      cancel_and_close(false)
    end)
  end
  table.insert(
    _state.autocmds,
    vim.api.nvim_create_autocmd("WinLeave", {
      buffer = _state.prompt_buf,
      callback = on_win_leave,
    })
  )
  table.insert(
    _state.autocmds,
    vim.api.nvim_create_autocmd("WinLeave", {
      buffer = _state.results_buf,
      callback = on_win_leave,
    })
  )

  build_entries()
  render_results()
  pcall(vim.api.nvim_win_set_cursor, _state.prompt_win, { 1, 2 })
  vim.cmd("startinsert!")

  api.get_myself(function(me, err)
    if not _state or _state.closed then
      return
    end
    if err or not me then
      return
    end
    _state.me = me
    _state.pinned = {
      {
        accountId = me.accountId,
        displayName = me.displayName or "Me",
        marker = "★",
        suffix = "(me)",
      },
      { accountId = nil, displayName = "Unassigned", marker = "○" },
    }
    _state.selected_idx = 1
    build_entries()
    render_results()
  end)
end

return M
