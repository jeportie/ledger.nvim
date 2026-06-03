local M = {}

local api = vim.api
local volt = require("volt")
local jira_api = require("ledger.jira.api")
local jutil = require("ledger.jira.util")
local hl = require("ledger.jira.board.ui.hl")
local icons = require("ledger.jira.icons")

local PRIORITIES = { "Highest", "High", "Medium", "Low", "Lowest" }

local function dw(s) return vim.fn.strdisplaywidth(s or "") end
local function pad_right(s, w)
  local n = w - dw(s)
  if n <= 0 then return s end
  return s .. string.rep(" ", n)
end

function M.open(issue_key, current, on_done)
  if not issue_key then return end
  local inner_w = 28
  local lines = {}
  local row_map = {} -- 1-based buffer row → priority name

  local function row(segs) table.insert(lines, segs) end

  row({
    { string.rep(" ", math.floor((inner_w - dw("Priority")) / 2)), "JiraBoardNormal" },
    { "Priority", "JiraBoardTitle" },
    { string.rep(" ",
        inner_w - math.floor((inner_w - dw("Priority")) / 2) - dw("Priority")),
      "JiraBoardNormal" },
  })
  row({ { string.rep("─", inner_w), "JiraBoardColRule" } })

  for i, p in ipairs(PRIORITIES) do
    local marker = (current == p) and "● " or "  "
    local icon = icons.priority(p) or " "
    local click = function() M._select(issue_key, p) end
    row({
      { " ",                                                "JiraBoardNormal", { click = click } },
      { marker,                                             "JiraBoardCardKey", { click = click } },
      { icon .. " ",                                        hl.priority_hl(p), { click = click } },
      { pad_right(p, inner_w - 1 - dw(marker) - dw(icon) - 2), hl.priority_hl(p), { click = click } },
      { " ",                                                "JiraBoardNormal", { click = click } },
    })
    row_map[#lines] = p
  end

  local screen_w = vim.o.columns
  local screen_h = vim.o.lines
  local w = inner_w
  local h = #lines
  local pos_row = math.floor((screen_h - h) / 2) - 1
  local pos_col = math.floor((screen_w - w) / 2)

  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor", row = pos_row, col = pos_col,
    width = w, height = h,
    style = "minimal", border = "single",
    zindex = 220,
    title = " Priority ", title_pos = "left",
  })
  jutil.clean_float_window(win)
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight =
    "NormalFloat:JiraBoardNormal,FloatBorder:JiraBoardBorder,FloatTitle:JiraBoardTitle"

  local ns = api.nvim_create_namespace("jira_board_pri_picker")
  hl.define(ns)
  api.nvim_win_set_hl_ns(win, ns)
  api.nvim_set_hl(ns, "FloatBorder", { link = "JiraBoardBorder" })
  api.nvim_set_hl(ns, "Normal",      { link = "JiraBoardNormal" })

  M._state = { buf = buf, win = win, ns = ns, on_done = on_done, issue_key = issue_key, row_map = row_map }

  local layout = { { name = "body", lines = function() return lines end } }
  volt.gen_data({ { buf = buf, xpad = 0, layout = layout, ns = ns } })
  volt.set_empty_lines(buf, #lines, w)
  volt.run(buf, { h = #lines, w = w })

  require("volt.events").add(buf)
  if not vim.g.extmarks_events then
    require("volt.events").enable()
  end

  local function kmap(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  local function cancel()
    if M._state and on_done then pcall(on_done, false) end
    M.close()
  end
  kmap("q", cancel); kmap("<Esc>", cancel)
  for i, p in ipairs(PRIORITIES) do
    kmap(tostring(i), function() M._select(issue_key, p) end)
  end
  -- Arrow-key navigation + Enter to pick is a nice-to-have; for now rely on
  -- click or the 1..5 shortcuts.
end

function M._select(issue_key, priority_name)
  local state = M._state
  local on_done = state and state.on_done
  jira_api.update_field(issue_key, "priority", { name = priority_name }, function(_, err)
    vim.schedule(function()
      if err then
        vim.notify("jira-board: set priority failed — " .. tostring(err), vim.log.levels.ERROR)
        if on_done then pcall(on_done, false) end
      else
        vim.notify("jira-board: " .. issue_key .. " priority → " .. priority_name)
        if on_done then pcall(on_done, true) end
      end
      M.close()
    end)
  end)
end

function M.close()
  local s = M._state
  if not s then return end
  if s.win and api.nvim_win_is_valid(s.win) then
    pcall(api.nvim_win_close, s.win, true)
  end
  if s.buf and api.nvim_buf_is_valid(s.buf) then
    pcall(api.nvim_buf_delete, s.buf, { force = true })
  end
  M._state = nil
end

return M
