local M = {}

local api = vim.api
local jutil = require("ledger.jira.util")
local hl = require("ledger.jira.board.ui.hl")

-- Minimal full-screen-ish text editor for description / comment bodies.
-- opts = { title, initial, on_save(text) }
function M.open(opts)
  opts = opts or {}
  local title = opts.title or "Editor"
  local initial = opts.initial or ""
  local on_save = opts.on_save

  local screen_w = vim.o.columns
  local screen_h = vim.o.lines
  local w = math.min(100, screen_w - 6)
  local h = math.min(22, screen_h - 6)
  local row = math.floor((screen_h - h) / 2) - 1
  local col = math.floor((screen_w - w) / 2)

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local lines = {}
  for line in (initial .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  if #lines == 0 then
    lines = { "" }
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = w,
    height = h,
    style = "minimal",
    border = "rounded",
    zindex = 240,
    title = " " .. title .. " — <C-s> save, <Esc> cancel ",
    title_pos = "left",
  })
  jutil.clean_float_window(win)
  vim.wo[win].winhighlight = "NormalFloat:JiraBoardNormal,FloatBorder:JiraBoardBorder,FloatTitle:JiraBoardTitle"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local ns = api.nvim_create_namespace("jira_board_text_editor")
  hl.define(ns)
  api.nvim_win_set_hl_ns(win, ns)
  api.nvim_set_hl(ns, "FloatBorder", { link = "JiraBoardBorder" })
  api.nvim_set_hl(ns, "Normal", { link = "JiraBoardNormal" })

  vim.cmd("stopinsert")

  local closed = false
  local function close(save)
    if closed then
      return
    end
    closed = true
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
    if save and on_save then
      pcall(on_save, text)
    end
  end

  local function map(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map({ "n", "i" }, "<C-s>", function()
    close(true)
  end)
  map({ "n", "i" }, "<Esc>", function()
    close(false)
  end)
  map("n", "q", function()
    close(false)
  end)
end

return M
