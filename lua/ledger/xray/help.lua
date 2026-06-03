local M = {}

local icons = require("ledger.xray.icons")

local _state = { close = nil, win = nil }

local function render(title, sections)
  local lines = {}
  local hl = {}

  local function push(s) table.insert(lines, s); return #lines - 1 end
  local function mark(lnum, col_s, col_e, group)
    table.insert(hl, { line = lnum, col_start = col_s, col_end = col_e, hl_group = group })
  end

  local header = "  " .. title
  local hln = push(header)
  mark(hln, 0, #header, "XrayTitle")
  push("")

  local key_w = 14
  for _, sec in ipairs(sections) do
    local sline = "── " .. sec.name .. " "
    local sln = push(sline)
    mark(sln, 0, #sline, "XraySection")
    for _, binding in ipairs(sec.bindings) do
      local k = binding[1]
      local desc = binding[2]
      local padded = k .. string.rep(" ", math.max(0, key_w - #k))
      local line = "  " .. padded .. desc
      local lnum = push(line)
      mark(lnum, 2, 2 + #k, "XrayKey")
      mark(lnum, 2 + #padded, #line, "XrayValue")
    end
    push("")
  end

  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end

  push("")
  local footer = "  ? toggle   q close"
  local fln = push(footer)
  mark(fln, 0, #footer, "XrayFooter")

  return { lines = lines, highlights = hl }
end

function M.search_bindings()
  return {
    {
      name = "Search (left pane)",
      bindings = {
        { "type…",               "fuzzy filter the list" },
        { "<Down>/<Up>",         "move selection (any mode)" },
        { "j/k",                 "move selection (normal mode)" },
        { "<C-n>/<C-p>",         "move selection" },
        { "scroll",              "move selection" },
        { "<CR>/<Right>",        "focus detail pane" },
        { "<LeftMouse>",         "select line (any mode)" },
        { "i/a",                 "back to insert (normal mode)" },
        { "<C-y>",               "yank selected ticket key" },
        { "<C-o>",               "open selected in browser" },
        { "<Esc>/q",             "close picker (normal mode)" },
      },
    },
    {
      name = "Field filters (in search input)",
      bindings = {
        { "field:value",     "restrict to issues where field matches value" },
        { "status:blocked",  "e.g. only blocked tickets" },
        { "assignee:john",   "by display name or email (prefix match ok)" },
        { "priority:high",   "by priority name" },
        { "platforms:ios",   "by platform" },
        { "team:ledger",     "by team name" },
        { "type:bug",        "by issue type (alias for issuetype)" },
        { "automated:lld",   "by automation target" },
        { "free text",       "also fuzzy-matches key + status + summary" },
        { "prefix ok",       "assigne:, sta:, pri:… resolve when unambiguous" },
      },
    },
    {
      name = "Detail (right pane)",
      bindings = {
        { "<Esc>",                   "back to search pane" },
        { "q",                       "close picker" },
        { "<Tab>/<Right>",           "focus next editable field" },
        { "<S-Tab>/<Left>",          "focus previous editable field" },
        { "<CR>/<LeftMouse>",        "edit focused field" },
        { "i",                       "insert ticket at cursor" },
        { "y",                       "yank ticket key" },
        { "b",                       "open in browser" },
        { "<C-l>",                   "force redraw (clears ghost paint)" },
        { "?",                       "toggle this help" },
      },
    },
  }
end

function M.float_bindings()
  return {
    {
      name = "Edit navigation",
      bindings = {
        { "<Tab>/<Right>",    "focus next editable field" },
        { "<S-Tab>/<Left>",   "focus previous editable field" },
        { "<CR>/<LeftMouse>", "edit focused field" },
      },
    },
    {
      name = "Ticket actions",
      bindings = {
        { "b",     "open in browser" },
      },
    },
    {
      name = "Window",
      bindings = {
        { "?",     "toggle this help" },
        { "q",     "close" },
        { "<Esc>", "close" },
      },
    },
  }
end

function M.is_open()
  return _state.win and vim.api.nvim_win_is_valid(_state.win)
end

function M.close()
  local fn = _state.close
  _state.close = nil
  _state.win = nil
  if fn then pcall(fn) end
end

function M.open(kind)
  if M.is_open() then
    M.close()
    return
  end

  local float = require("ledger.xray.float")
  local title, sections
  if kind == "float" then
    title = icons.ACTION.preview .. "  Xray ticket — keybindings"
    sections = M.float_bindings()
  else
    title = icons.ACTION.search .. "  Xray search — keybindings"
    sections = M.search_bindings()
  end
  local content = render(title, sections)
  local _, win, close = float.open("Help", content, {
    is_help = true,
    noenter = true,
    zindex = 250,
  })
  _state.close = close
  _state.win = win
end

return M
