local M = {}

local api = vim.api
local volt = require("volt")
local hl = require("ledger.jira.board.ui.hl")
local jutil = require("ledger.jira.util")

local function dw(s) return vim.fn.strdisplaywidth(s or "") end

local KEYS = {
  { "Navigation", {
    { "h  /  <S-Tab>",  "previous column" },
    { "l  /  <Tab>",    "next column" },
    { "j  /  k",        "next / previous card" },
    { "<LeftMouse>",    "select card" },
  } },
  { "Actions", {
    { "<CR>",           "preview ticket" },
    { "p",              "preview ticket" },
    { "b",              "open ticket in browser" },
    { "<2-LeftMouse>",  "preview ticket" },
    { "y",              "yank ticket key" },
    { "t",              "transition status" },
    { "m",              "assign to me" },
    { "a",              "assign to someone…" },
    { "u",              "unassign" },
    { "<RightMouse>",   "context menu" },
  } },
  { "View", {
    { "A",              "toggle assignee filter (me ↔ all)" },
    { "B",              "toggle Backlog column" },
    { "z",              "collapse / expand epic at cursor" },
    { "Z",              "collapse all epics" },
    { "<S-Z>",          "expand all epics" },
    { "f",              "filter picker" },
    { "R",              "refresh board" },
    { "<C-l>",          "redraw" },
  } },
  { "Window", {
    { "?",              "this help" },
    { "q / <Esc>",      "close" },
  } },
}

local _state = { buf = nil, win = nil, ns = nil }

local function close()
  local s = _state
  if s.win and api.nvim_win_is_valid(s.win) then
    pcall(api.nvim_win_close, s.win, true)
  end
  if s.buf and api.nvim_buf_is_valid(s.buf) then
    pcall(api.nvim_buf_delete, s.buf, { force = true })
  end
  _state = { buf = nil, win = nil, ns = nil }
end

local function build_lines(inner_w)
  local lines = {}

  local function row_raw(segs) table.insert(lines, segs) end

  -- Title line (centered)
  local title = "Jira Board — Keymaps"
  local tpad = math.floor((inner_w - dw(title)) / 2)
  row_raw({
    { string.rep(" ", tpad), "JiraBoardNormal" },
    { title, "JiraBoardTitle" },
    { string.rep(" ", inner_w - tpad - dw(title)), "JiraBoardNormal" },
  })
  row_raw({ { string.rep(" ", inner_w), "JiraBoardNormal" } })

  for _, section in ipairs(KEYS) do
    local name = section[1]
    local entries = section[2]
    row_raw({
      { "  ", "JiraBoardNormal" },
      { name, "JiraBoardColHdr" },
      { string.rep(" ", inner_w - 2 - dw(name)), "JiraBoardNormal" },
    })
    row_raw({
      { "  ", "JiraBoardNormal" },
      { string.rep("─", inner_w - 4), "JiraBoardColRule" },
      { "  ", "JiraBoardNormal" },
    })
    for _, entry in ipairs(entries) do
      local keystr = entry[1]
      local desc = entry[2]
      local chip = " " .. keystr .. " "
      local mid = inner_w - 4 - dw(chip) - dw(desc)
      if mid < 1 then mid = 1 end
      row_raw({
        { "  ", "JiraBoardNormal" },
        { chip, "JiraBoardKeyChip" },
        { string.rep(" ", mid), "JiraBoardNormal" },
        { desc, "JiraBoardKeyDesc" },
        { "  ", "JiraBoardNormal" },
      })
    end
    row_raw({ { string.rep(" ", inner_w), "JiraBoardNormal" } })
  end

  return lines
end

function M.toggle()
  if _state.win and api.nvim_win_is_valid(_state.win) then
    close(); return
  end

  local inner_w = 52
  local lines = build_lines(inner_w)
  local inner_h = #lines

  local screen_w = vim.o.columns
  local screen_h = vim.o.lines
  local w = math.min(inner_w, screen_w - 4)
  local h = math.min(inner_h, screen_h - 4)
  local row = math.floor((screen_h - h) / 2) - 1
  local col = math.floor((screen_w - w) / 2)

  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor", row = row, col = col,
    width = w, height = h,
    style = "minimal", border = "single",
    zindex = 150,
  })
  jutil.clean_float_window(win)
  vim.wo[win].cursorline = false
  vim.bo[buf].filetype = "jira-board-help"

  local ns = api.nvim_create_namespace("jira_board_help_hl")
  hl.define(ns)
  api.nvim_win_set_hl_ns(win, ns)
  api.nvim_set_hl(ns, "FloatBorder", { link = "JiraBoardBorder" })
  api.nvim_set_hl(ns, "Normal",      { link = "JiraBoardNormal" })

  _state.buf = buf
  _state.win = win
  _state.ns = ns

  local layout = {
    { name = "body", lines = function() return lines end },
  }
  volt.gen_data({ { buf = buf, xpad = 0, layout = layout, ns = ns } })
  volt.set_empty_lines(buf, inner_h, w)
  volt.run(buf, { h = inner_h, w = w, custom_empty_lines = function()
    volt.set_empty_lines(buf, inner_h, w)
  end })

  local function map(lhs) vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, silent = true }) end
  map("q"); map("<Esc>"); map("?")

  local function noop(lhs)
    vim.keymap.set("n", lhs, function() end, { buffer = buf, nowait = true, silent = true })
  end
  noop("<ScrollWheelUp>")
  noop("<ScrollWheelDown>")
  noop("<ScrollWheelLeft>")
  noop("<ScrollWheelRight>")
end

return M
