local M = {}

local api = require("ledger.jira.api")
local util = require("ledger.jira.util")

local _state = nil

local function is_open()
  return _state and _state.win and vim.api.nvim_win_is_valid(_state.win)
end

local function destroy(restore)
  if not _state then
    return
  end
  local buf = _state.buf
  local win = _state.win
  local parent_win = _state.parent_win
  _state = nil
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

local function cancel_and_close(restore)
  if not _state then
    return
  end
  local on_done = _state.on_done
  _state.on_done = nil
  destroy(restore)
  if on_done then
    pcall(on_done, nil, nil)
  end
end

local function text_to_adf(text)
  local paragraphs = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" then
      table.insert(paragraphs, { type = "paragraph" })
    else
      table.insert(paragraphs, {
        type = "paragraph",
        content = { { type = "text", text = line } },
      })
    end
  end
  while #paragraphs > 0 and not paragraphs[#paragraphs].content do
    table.remove(paragraphs)
  end
  if #paragraphs == 0 then
    return nil
  end
  return { type = "doc", version = 1, content = paragraphs }
end

local function submit()
  if not _state then
    return
  end
  local buf = _state.buf
  local key = _state.key

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local joined = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if joined == "" then
    vim.notify("xray: comment is empty", vim.log.levels.WARN)
    return
  end

  local adf = text_to_adf(joined)
  if not adf then
    vim.notify("xray: comment is empty", vim.log.levels.WARN)
    return
  end

  local on_done = _state.on_done
  _state.on_done = nil
  destroy()

  api.add_comment(key, adf, function(_, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      if on_done then
        pcall(on_done, nil, err)
      end
      return
    end
    vim.notify("xray: comment added to " .. key, vim.log.levels.INFO)
    if on_done then
      pcall(on_done, true, nil)
    end
  end)
end

function M.close()
  cancel_and_close()
end

-- on_done(true, nil) on success, (nil, err) on failure, (nil, nil) on cancel
function M.open(key, on_done, opts)
  opts = opts or {}
  if is_open() then
    destroy()
  end
  local parent_win = vim.api.nvim_get_current_win()
  _state = { key = key, on_done = on_done, parent_win = parent_win }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  util.disable_completion(buf)
  _state.buf = buf

  local width = math.min(80, math.max(50, math.floor(vim.o.columns * 0.6)))
  local height = 10
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
    title = " Add comment — " .. key .. " ",
    title_pos = "left",
    footer = " <C-s> submit   <Esc>/q/<C-c> cancel ",
    footer_pos = "right",
    zindex = 260,
  })
  _state.win = win
  util.clean_float_window(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight =
    "FloatBorder:XrayBorder,FloatTitle:XrayTitleFloat,FloatFooter:XrayFooter,NormalFloat:XrayNormal"

  local km = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set({ "i", "n" }, "<C-s>", submit, km)
  vim.keymap.set({ "i", "n" }, "<C-c>", cancel_and_close, km)
  vim.keymap.set("n", "<Esc>", cancel_and_close, km)
  vim.keymap.set("n", "q", cancel_and_close, km)

  local aug = vim.api.nvim_create_augroup("xray_comment_compose_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug,
    callback = function(args)
      if not _state then
        return
      end
      if tonumber(args.match) == _state.win then
        vim.schedule(cancel_and_close)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = aug,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if not _state then
          return
        end
        cancel_and_close(false)
      end)
    end,
  })

  vim.cmd("startinsert")
end

return M
