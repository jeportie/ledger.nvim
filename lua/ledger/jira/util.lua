local M = {}

local config = require("ledger.jira.config")

function M.ticket_url(key)
  local creds = config.credentials()
  local base = creds and creds.url or ""
  return base .. "/browse/" .. key
end

function M.open_url(url)
  local cmd
  if vim.fn.has("mac") == 1 then
    cmd = { "open", url }
  elseif vim.fn.has("unix") == 1 then
    cmd = { "xdg-open", url }
  else
    cmd = { "cmd.exe", "/c", "start", url }
  end
  vim.system(cmd, { detach = true })
end

function M.screen_cursor_anchor(outer_w, outer_h)
  local sr = vim.fn.screenrow()
  local sc = vim.fn.screencol()
  local cols = vim.o.columns
  local lines = vim.o.lines
  local fits_below = (lines - sr - 2) >= outer_h
  local row
  if fits_below then
    row = sr
  else
    row = math.max(0, sr - outer_h - 1)
  end
  local col = math.max(0, math.min(cols - outer_w, sc - 1))
  return { relative = "editor", row = row, col = col }
end

function M.clean_float_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].statuscolumn = ""
  vim.wo[win].colorcolumn = ""
  vim.wo[win].cursorline = false
  vim.wo[win].cursorcolumn = false
  vim.wo[win].wrap = false
  vim.wo[win].list = false
  vim.wo[win].spell = false
  vim.wo[win].winbar = ""
  vim.wo[win].scrolloff = 0
  vim.wo[win].sidescrolloff = 0
  pcall(function()
    vim.wo[win].scrollbind = false
  end)
  pcall(function()
    vim.wo[win].cursorbind = false
  end)
  pcall(function()
    vim.wo[win].showbreak = ""
  end)
  pcall(function()
    vim.wo[win].breakindent = false
  end)
  pcall(function()
    vim.wo[win].smoothscroll = false
  end)
  pcall(function()
    vim.wo[win].linebreak = false
  end)
  pcall(function()
    vim.wo[win].virtualedit = ""
  end)
  pcall(vim.api.nvim_win_call, win, function()
    pcall(vim.fn.winrestview, { leftcol = 0 })
  end)
end

function M.disable_completion(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  pcall(function()
    vim.bo[buf].complete = ""
  end)
  pcall(function()
    vim.bo[buf].omnifunc = ""
  end)
  pcall(function()
    vim.b[buf].completion = false
  end)
  pcall(function()
    vim.b[buf].cmp_enabled = false
  end)
  pcall(function()
    vim.b[buf].blink_cmp_enabled = false
  end)
  pcall(function()
    vim.b[buf].copilot_enabled = false
  end)
  -- Smooth-scroll plugins (snacks.scroll, neoscroll, etc.) animate the viewport
  -- by rendering the buffer at both old and new positions during the animation.
  -- That animation leaks into adjacent floats and persists across window
  -- lifecycle — opt out at the buffer level.
  pcall(function()
    vim.b[buf].snacks_scroll = false
  end)
  pcall(function()
    vim.b[buf].miniindentscope_disable = true
  end)
  pcall(function()
    vim.b[buf].ibl_disabled = true
  end)
end

return M
