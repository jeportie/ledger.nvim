local M = {}

local api = require("ledger.jira.api")
local icons = require("ledger.jira.icons")
local util = require("ledger.jira.util")

local _state = { buf = nil, win = nil, close = nil, parent_win = nil, autocmd_id = nil, closing = false }

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
  _state = { buf = nil, win = nil, close = nil, parent_win = nil, autocmd_id = nil, closing = false }
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

local function render(buf, ns, transitions, selected_idx)
  local lines = {}
  for _, t in ipairs(transitions) do
    local to_name = (t.to and t.to.name) or t.name
    table.insert(lines, string.format("  %s %s", icons.status(to_name), to_name))
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if selected_idx >= 1 and selected_idx <= #transitions then
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, selected_idx - 1, 0, {
      line_hl_group = "XraySelected",
    })
  end
end

function M.close()
  do_close()
end

function M.open(key, current_status, on_done, opts)
  opts = opts or {}
  if is_open() then
    do_close()
  end
  local parent_win = vim.api.nvim_get_current_win()

  api.get_transitions(key, function(data, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    local transitions = (data and data.transitions) or {}
    if #transitions == 0 then
      vim.notify("xray: no transitions available for " .. key, vim.log.levels.WARN)
      return
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "xray"
    util.disable_completion(buf)

    local ns = vim.api.nvim_create_namespace("xray_status_picker")
    local selected_idx = 1
    for i, t in ipairs(transitions) do
      local to_name = (t.to and t.to.name) or t.name
      if to_name == current_status then
        selected_idx = i
        break
      end
    end

    local max_w = 28
    for _, t in ipairs(transitions) do
      local to_name = (t.to and t.to.name) or t.name
      local w = vim.fn.strdisplaywidth("  " .. icons.status(to_name) .. " " .. to_name)
      if w > max_w then
        max_w = w
      end
    end
    local width = max_w + 4
    local height = math.min(#transitions, 12)

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
      title = " Transition " .. key .. " ",
      title_pos = "left",
      zindex = 260,
    })
    util.clean_float_window(win)
    vim.wo[win].winhighlight = "FloatBorder:XrayBorder,FloatTitle:XrayTitleFloat,NormalFloat:XrayNormal"

    _state = { buf = buf, win = win, parent_win = parent_win, closing = false }

    _state.autocmd_id = vim.api.nvim_create_autocmd("WinLeave", {
      buffer = buf,
      callback = function()
        vim.schedule(function()
          do_close(false)
        end)
      end,
    })

    render(buf, ns, transitions, selected_idx)
    pcall(vim.api.nvim_win_set_cursor, win, { selected_idx, 0 })

    local function move(delta)
      selected_idx = math.max(1, math.min(#transitions, selected_idx + delta))
      render(buf, ns, transitions, selected_idx)
      pcall(vim.api.nvim_win_set_cursor, win, { selected_idx, 0 })
    end

    local function confirm()
      local t = transitions[selected_idx]
      if not t then
        return
      end
      local to_name = (t.to and t.to.name) or t.name
      do_close()
      api.do_transition(key, t.id, function(_, derr)
        if derr then
          vim.notify(derr, vim.log.levels.ERROR)
          if on_done then
            pcall(on_done, nil, derr)
          end
          return
        end
        vim.notify(string.format("xray: %s → %s", key, to_name), vim.log.levels.INFO)
        if on_done then
          pcall(on_done, to_name, nil)
        end
      end)
    end

    local opts = { buffer = buf, nowait = true, silent = true }
    vim.keymap.set("n", "q", do_close, opts)
    vim.keymap.set("n", "<Esc>", do_close, opts)
    vim.keymap.set("n", "j", function()
      move(1)
    end, opts)
    vim.keymap.set("n", "k", function()
      move(-1)
    end, opts)
    vim.keymap.set("n", "<Down>", function()
      move(1)
    end, opts)
    vim.keymap.set("n", "<Up>", function()
      move(-1)
    end, opts)
    vim.keymap.set("n", "<ScrollWheelDown>", function()
      move(1)
    end, opts)
    vim.keymap.set("n", "<ScrollWheelUp>", function()
      move(-1)
    end, opts)
    vim.keymap.set("n", "<CR>", confirm, opts)
    vim.keymap.set("n", "<LeftMouse>", function()
      local pos = vim.fn.getmousepos()
      if not pos or pos.winid ~= win then
        return
      end
      if pos.line and pos.line >= 1 and pos.line <= #transitions then
        selected_idx = pos.line
        render(buf, ns, transitions, selected_idx)
        pcall(vim.api.nvim_win_set_cursor, win, { selected_idx, 0 })
        confirm()
      end
    end, opts)
  end)
end

return M
