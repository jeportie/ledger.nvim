local M = {}

local cache = require("ledger.xray.cache")
local float = require("ledger.xray.float")
local format = require("ledger.xray.format")
local util = require("ledger.xray.util")

-- Stack of nested hovers. The root frame (stack[1]) owns the origin autocmd.
-- Each frame: { win, buf, key, close, origin_buf }
local stack = {}
local origin_autocmd_id = nil

local function clear_origin_autocmd()
  if origin_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, origin_autocmd_id)
    origin_autocmd_id = nil
  end
end

local function top_frame()
  return stack[#stack]
end

local function is_open()
  local t = top_frame()
  return t and t.win and vim.api.nvim_win_is_valid(t.win) or false
end

function M.close()
  clear_origin_autocmd()
  for _ = #stack, 1, -1 do
    local frame = table.remove(stack)
    if frame and frame.close then pcall(frame.close) end
  end
end

local function pop_one()
  if #stack == 0 then return end
  local frame = table.remove(stack)
  if frame and frame.close then pcall(frame.close) end
  if #stack == 0 then
    clear_origin_autocmd()
    return
  end
  local new_top = top_frame()
  if new_top and new_top.win and vim.api.nvim_win_is_valid(new_top.win) then
    pcall(vim.api.nvim_set_current_win, new_top.win)
  end
end

local function find_frame(key)
  for i, f in ipairs(stack) do
    if f.key == key then return i end
  end
  return nil
end

local function collapse_to(idx)
  clear_origin_autocmd()
  for _ = #stack, idx + 1, -1 do
    local frame = table.remove(stack)
    if frame and frame.close then pcall(frame.close) end
  end
  local t = stack[idx]
  if t and t.win and vim.api.nvim_win_is_valid(t.win) then
    pcall(vim.api.nvim_set_current_win, t.win)
  end
end

local function open_peek(key, issue, origin_buf, opts)
  opts = opts or {}
  local content = format.ticket_lines(issue)
  local buf, win, close

  local function refresh()
    cache.fetch(key, function(fresh, ferr)
      if ferr or not fresh then return end
      if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
      float.update(buf, format.ticket_lines(fresh))
    end)
  end

  buf, win, close = float.open(key, content, {
    key = key,
    noenter = not opts.focus,
    anchor = "cursor",
    zindex = 100 + #stack,
    on_activate = function(r)
      require("ledger.xray.edit").dispatch(r, {
        key = key,
        anchor = "cursor",
        on_refresh = refresh,
      })
    end,
  })

  local km = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "K", "<Nop>", km)
  vim.keymap.set("n", "<Esc>", pop_one, km)
  vim.keymap.set("n", "q", pop_one, km)

  table.insert(stack, {
    win = win,
    buf = buf,
    key = key,
    close = close,
    origin_buf = origin_buf,
  })

  if #stack == 1 and origin_buf and vim.api.nvim_buf_is_valid(origin_buf) then
    origin_autocmd_id = vim.api.nvim_create_autocmd(
      { "CursorMoved", "CursorMovedI", "BufLeave", "InsertEnter", "WinScrolled" },
      {
        buffer = origin_buf,
        callback = function()
          M.close()
        end,
      }
    )
  end
end

local function fetch_and_show(key, origin_buf, opts)
  cache.fetch(key, function(issue, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    if #stack == 0 and vim.api.nvim_get_current_buf() ~= origin_buf then
      return
    end
    open_peek(key, issue, origin_buf, opts)
  end)
end

function M.trigger(key, opts)
  key = key or util.cword_id()
  if not key then return false end
  opts = opts or {}

  local idx = find_frame(key)
  if idx then
    collapse_to(idx)
    return true
  end

  if #stack == 0 then
    local origin_buf = vim.api.nvim_get_current_buf()
    fetch_and_show(key, origin_buf, opts)
    return true
  end

  local origin_buf = stack[1].origin_buf
  fetch_and_show(key, origin_buf, opts)
  return true
end

function M.hover_or_lsp()
  if M.trigger() then return end
  pcall(vim.lsp.buf.hover)
end

return M
