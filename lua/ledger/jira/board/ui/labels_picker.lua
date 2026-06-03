local M = {}

local api = vim.api
local jira_api = require("ledger.jira.api")
local jutil = require("ledger.jira.util")
local hl = require("ledger.jira.board.ui.hl")

-- Simple comma-separated labels editor.
-- cb(new_labels | nil) where nil means the user cancelled.
function M.open(issue_key, current_labels, cb)
  if not issue_key then return end
  current_labels = current_labels or {}

  local initial = table.concat(current_labels, ", ")

  local screen_w = vim.o.columns
  local screen_h = vim.o.lines
  local w = math.min(60, screen_w - 6)
  local h = 1
  local row = math.floor((screen_h - h) / 2) - 1
  local col = math.floor((screen_w - w) / 2)

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, { initial })

  local win = api.nvim_open_win(buf, true, {
    relative = "editor", row = row, col = col,
    width = w, height = h,
    style = "minimal", border = "rounded",
    zindex = 220,
    title = " Labels (comma-separated) — <CR> save, <Esc> cancel ",
    title_pos = "left",
  })
  jutil.clean_float_window(win)
  vim.wo[win].winhighlight =
    "NormalFloat:JiraBoardNormal,FloatBorder:JiraBoardBorder,FloatTitle:JiraBoardTitle"

  local ns = api.nvim_create_namespace("jira_board_labels_picker")
  hl.define(ns)
  api.nvim_win_set_hl_ns(win, ns)
  api.nvim_set_hl(ns, "FloatBorder", { link = "JiraBoardBorder" })
  api.nvim_set_hl(ns, "Normal",      { link = "JiraBoardNormal" })

  vim.cmd("startinsert!")

  local closed = false
  local function close_picker(save)
    if closed then return end
    closed = true
    local line = api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    if api.nvim_win_is_valid(win) then pcall(api.nvim_win_close, win, true) end
    if api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end

    if not save then
      if cb then pcall(cb, nil) end
      return
    end

    local new_labels = {}
    for tok in string.gmatch(line, "[^,%s]+") do
      table.insert(new_labels, tok)
    end

    jira_api.update_field(issue_key, "labels", new_labels, function(_, err)
      vim.schedule(function()
        if err then
          vim.notify("jira-board: set labels failed — " .. tostring(err), vim.log.levels.ERROR)
          if cb then pcall(cb, nil) end
        else
          vim.notify("jira-board: " .. issue_key .. " labels updated")
          if cb then pcall(cb, new_labels) end
        end
      end)
    end)
  end

  vim.keymap.set({ "n", "i" }, "<CR>",  function() close_picker(true) end,
    { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<Esc>", function() close_picker(false) end,
    { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "q", function() close_picker(false) end,
    { buffer = buf, nowait = true, silent = true })
end

return M
