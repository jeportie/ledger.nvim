local M = {}

local util = require("ledger.xray.util")

local ns = vim.api.nvim_create_namespace("xray_float")

local function compute_size(lines)
  local content_w = 0
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > content_w then content_w = w end
  end
  local min_w = 40
  local max_w = math.max(min_w, math.floor(vim.o.columns * 0.9))
  local width = math.max(min_w, math.min(max_w, content_w + 4))

  local min_h = math.min(#lines + 2, 5)
  local max_h = math.max(min_h, math.floor(vim.o.lines * 0.85))
  local height = math.max(min_h, math.min(max_h, #lines + 2))

  return width, height
end

local function normalize(arg)
  if type(arg) == "table" and arg.lines then
    return arg.lines, arg.highlights or {}
  end
  return arg, {}
end

function M.update(buf, content)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local lines, highlights = normalize(content)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  M.apply_highlights(buf, highlights)
  local content_tbl = type(content) == "table" and content or {}
  if content_tbl.regions then
    require("ledger.xray.editor").update(buf, content_tbl.regions)
  end
end

function M.apply_highlights(buf, highlights)
  if not highlights or #highlights == 0 then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(highlights) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.line, h.col_start, {
      end_col = h.col_end,
      hl_group = h.hl_group,
    })
  end
end

function M.open(title, content, opts)
  opts = opts or {}
  local lines, highlights = normalize(content)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  M.apply_highlights(buf, highlights)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = opts.filetype or "xray"
  util.disable_completion(buf)

  local width, height = compute_size(lines)
  local win_config = {
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "left",
    focusable = true,
    zindex = opts.zindex or 50,
  }

  if opts.anchor == "cursor" then
    local screenrow = vim.fn.screenrow()
    local fits_below = (vim.o.lines - screenrow - 2) >= height
    win_config.relative = "cursor"
    win_config.col = 0
    if fits_below then
      win_config.row = 1
      win_config.anchor = "NW"
    else
      win_config.row = 0
      win_config.anchor = "SW"
    end
  else
    win_config.relative = "editor"
    win_config.row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
    win_config.col = math.max(0, math.floor((vim.o.columns - width) / 2))
  end

  local enter = not opts.noenter
  local win = vim.api.nvim_open_win(buf, enter, win_config)

  util.clean_float_window(win)
  vim.wo[win].winhighlight = "FloatBorder:XrayBorder,FloatTitle:XrayTitleFloat,NormalFloat:XrayNormal"

  local function close()
    if not opts.is_help then
      pcall(function() require("ledger.xray.help").close() end)
    end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  local function map(keys, fn)
    for _, k in ipairs(keys) do
      vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true })
    end
  end

  map({ "q", "<Esc>" }, close)

  for _, k in ipairs({
    "<2-LeftMouse>", "<3-LeftMouse>", "<4-LeftMouse>",
    "<RightMouse>", "<2-RightMouse>",
    "<MiddleMouse>",
    "<LeftDrag>", "<LeftRelease>",
  }) do
    vim.keymap.set("n", k, "<Nop>", { buffer = buf, nowait = true, silent = true })
  end

  if not opts.is_help then
    map({ "?" }, function()
      require("ledger.xray.help").open("float")
    end)
  end

  if opts.key and not opts.is_help then
    map({ "b" }, function()
      util.open_url(util.ticket_url(opts.key))
    end)
  end

  local content_tbl = type(content) == "table" and content or {}
  if content_tbl.regions and #content_tbl.regions > 0 and not opts.is_help then
    require("ledger.xray.editor").attach(buf, win, content_tbl.regions, {
      key = opts.key,
      on_activate = opts.on_activate or function(r)
        vim.notify("xray: edit " .. (r.field or "?") .. " (not wired yet)", vim.log.levels.INFO)
      end,
    })
  end

  if opts.on_enter then
    map({ "<CR>" }, function()
      local line = vim.api.nvim_get_current_line()
      local lnum = vim.api.nvim_win_get_cursor(win)[1]
      close()
      opts.on_enter(line, lnum)
    end)
  end

  return buf, win, close
end

return M
