-- ledger.builder.menus
--
-- Reusable floating pickers for the Builder controller (extracted from init.lua
-- so the controller stays focused on state/layout/nav). No builder state here —
-- callers pass choices + an on_pick callback.

local M = {}

-- A small centered float listing `choices` (the `current` one marked); <CR>
-- fires `on_pick(choice)`, q / <Esc> dismiss.
function M.open_menu(title, choices, current, on_pick)
  if not choices or #choices == 0 then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local width = vim.fn.strdisplaywidth(title) + 2
  local cur_line = 1
  local lines = {}
  for i, c in ipairs(choices) do
    local marked = (c == current)
    lines[i] = (marked and " ● " or "   ") .. c
    if marked then
      cur_line = i
    end
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]) + 2)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local height = math.min(#choices, math.max(1, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.min(width, vim.o.columns - 4),
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    zindex = 250,
  })
  vim.wo[win].cursorline = true
  pcall(vim.api.nvim_win_set_cursor, win, { cur_line, 0 })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  local function pick()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    close()
    local choice = choices[row]
    if choice then
      on_pick(choice)
    end
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", pick, opts)
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
end

-- Pick one nx project (from `root`'s project graph) via vim.ui.select, which
-- routes to the user's configured picker UI (e.g. Telescope). `cb(name)`.
function M.pick_project(root, prompt, cb)
  local projects = require("ledger.builder.nx").projects(root)
  if #projects == 0 then
    vim.notify("Builder: no nx project graph yet — build once, then retry", vim.log.levels.WARN)
    return
  end
  local names = {}
  for _, p in ipairs(projects) do
    names[#names + 1] = p.name
  end
  table.sort(names)
  vim.ui.select(names, { prompt = prompt }, function(choice)
    if choice and choice ~= "" then
      cb(choice)
    end
  end)
end

return M
