local M = {}

local icons = require("ledger.jira.icons")
local util = require("ledger.jira.util")

local _state = { buf = nil, win = nil, parent_win = nil, autocmd_id = nil, closing = false }

local function is_open()
  return _state.win and vim.api.nvim_win_is_valid(_state.win)
end

local function do_close(restore)
  if _state.closing then
    return
  end
  _state.closing = true
  local buf = _state.buf
  local win = _state.win
  local parent_win = _state.parent_win
  local autocmd_id = _state.autocmd_id
  _state = { buf = nil, win = nil, parent_win = nil, autocmd_id = nil, closing = false }
  if autocmd_id then
    pcall(vim.api.nvim_del_autocmd, autocmd_id)
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if restore ~= false and parent_win and vim.api.nvim_win_is_valid(parent_win) then
    pcall(vim.api.nvim_set_current_win, parent_win)
  end
end

local function make_line(opt, checked, is_platform_like)
  local box = checked and "[x]" or "[ ]"
  local icon = is_platform_like and icons.platform(opt) or ""
  if icon ~= "" then
    return string.format("  %s  %s %s", box, icon, opt)
  end
  return string.format("  %s  %s", box, opt)
end

local function render(buf, ns, options, selected, selected_idx, is_platform_like)
  local lines = {}
  for _, o in ipairs(options) do
    table.insert(lines, make_line(o, selected[o] == true, is_platform_like))
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if selected_idx >= 1 and selected_idx <= #options then
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, selected_idx - 1, 0, {
      line_hl_group = "XraySelected",
    })
  end
  for i, o in ipairs(options) do
    if selected[o] then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 2, {
        end_col = 5,
        hl_group = "XrayStatusOk",
      })
    end
  end
end

function M.close()
  do_close()
end

-- opts: { title, options, current, on_done, is_platform_like }
-- on_done(selected_list | nil, err)
function M.open(opts)
  if is_open() then
    do_close()
  end
  local parent_win = vim.api.nvim_get_current_win()
  local title = opts.title or "Select"
  local options = opts.options or {}
  local current = opts.current or {}
  local on_done = opts.on_done
  local is_platform_like = opts.is_platform_like or false

  local selected = {}
  for _, v in ipairs(current) do
    selected[v] = true
  end

  local selected_idx = 1

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "xray"
  util.disable_completion(buf)

  local ns = vim.api.nvim_create_namespace("xray_multi_select")

  local max_w = vim.fn.strdisplaywidth(title) + 4
  for _, o in ipairs(options) do
    local w = vim.fn.strdisplaywidth(make_line(o, true, is_platform_like))
    if w > max_w then
      max_w = w
    end
  end
  local width = max_w + 4
  local footer_h = 1
  local height = math.min(#options + footer_h, 14)

  local row, col
  if opts.anchor == "cursor" then
    local a = util.screen_cursor_anchor(width + 2, height + 2)
    row, col = a.row, a.col
  else
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
    col = math.max(0, math.floor((vim.o.columns - width) / 2))
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "left",
    footer = " <Space> toggle  <CR> confirm  q cancel ",
    footer_pos = "right",
    zindex = 260,
  })
  util.clean_float_window(win)
  vim.wo[win].winhighlight =
    "FloatBorder:XrayBorder,FloatTitle:XrayTitleFloat,FloatFooter:XrayFooter,NormalFloat:XrayNormal"

  _state = { buf = buf, win = win, parent_win = parent_win, closing = false }

  render(buf, ns, options, selected, selected_idx, is_platform_like)
  pcall(vim.api.nvim_win_set_cursor, win, { selected_idx, 0 })

  local function move(delta)
    selected_idx = math.max(1, math.min(#options, selected_idx + delta))
    render(buf, ns, options, selected, selected_idx, is_platform_like)
    pcall(vim.api.nvim_win_set_cursor, win, { selected_idx, 0 })
  end

  local function toggle()
    local opt = options[selected_idx]
    if not opt then
      return
    end
    selected[opt] = not selected[opt] or nil
    render(buf, ns, options, selected, selected_idx, is_platform_like)
  end

  local function confirm()
    local result = {}
    for _, o in ipairs(options) do
      if selected[o] then
        table.insert(result, o)
      end
    end
    local cb = on_done
    on_done = nil
    do_close()
    if cb then
      pcall(cb, result, nil)
    end
  end

  local function cancel()
    local cb = on_done
    on_done = nil
    do_close()
    if cb then
      pcall(cb, nil, nil)
    end
  end

  _state.autocmd_id = vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    callback = function()
      vim.schedule(function()
        local cb = on_done
        on_done = nil
        do_close(false)
        if cb then
          pcall(cb, nil, nil)
        end
      end)
    end,
  })

  local km = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", cancel, km)
  vim.keymap.set("n", "<Esc>", cancel, km)
  vim.keymap.set("n", "j", function()
    move(1)
  end, km)
  vim.keymap.set("n", "k", function()
    move(-1)
  end, km)
  vim.keymap.set("n", "<Down>", function()
    move(1)
  end, km)
  vim.keymap.set("n", "<Up>", function()
    move(-1)
  end, km)
  vim.keymap.set("n", "<ScrollWheelDown>", function()
    move(1)
  end, km)
  vim.keymap.set("n", "<ScrollWheelUp>", function()
    move(-1)
  end, km)
  vim.keymap.set("n", "<Space>", toggle, km)
  vim.keymap.set("n", "x", toggle, km)
  vim.keymap.set("n", "<CR>", confirm, km)
  vim.keymap.set("n", "<LeftMouse>", function()
    local pos = vim.fn.getmousepos()
    if not pos or pos.winid ~= win then
      return
    end
    if pos.line and pos.line >= 1 and pos.line <= #options then
      selected_idx = pos.line
      toggle()
    end
  end, km)
end

return M
