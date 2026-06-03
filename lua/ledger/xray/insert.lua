local M = {}

local function cursor_in_quotes(line, col)
  local in_quote = false
  local quote_char = nil
  local start_col = nil

  for i = 1, col do
    local c = line:sub(i, i)
    local prev = i > 1 and line:sub(i - 1, i - 1) or ""
    if (c == '"' or c == "'") and prev ~= "\\" then
      if not in_quote then
        in_quote = true
        quote_char = c
        start_col = i
      elseif c == quote_char then
        in_quote = false
        quote_char = nil
        start_col = nil
      end
    end
  end

  if not in_quote then return false end

  local end_col
  local i = col + 1
  while i <= #line do
    local c = line:sub(i, i)
    local prev = line:sub(i - 1, i - 1)
    if c == quote_char and prev ~= "\\" then
      end_col = i
      break
    end
    i = i + 1
  end

  if not end_col then return false end
  return true, quote_char, start_col, end_col
end

function M.smart_insert(key)
  if not key or key == "" then return end

  local buf = vim.api.nvim_get_current_buf()
  if not vim.bo[buf].modifiable or vim.bo[buf].buftype ~= "" then
    vim.fn.setreg("+", key)
    vim.fn.setreg('"', key)
    vim.notify(
      "xray: buffer not modifiable — yanked " .. key .. " to clipboard",
      vim.log.levels.INFO
    )
    return
  end

  local line = vim.api.nvim_get_current_line()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1], pos[2]

  local in_q, _, qs, qe = cursor_in_quotes(line, col)

  if in_q then
    local inside = line:sub(qs + 1, qe - 1)
    local trimmed = inside:gsub("%s+$", "")
    local new_inside
    if trimmed == "" then
      new_inside = key
    else
      new_inside = trimmed .. ", " .. key
    end
    local new_line = line:sub(1, qs) .. new_inside .. line:sub(qe)
    vim.api.nvim_set_current_line(new_line)
    vim.api.nvim_win_set_cursor(0, { row, qs + #new_inside })
  else
    local inserted = '"' .. key .. '"'
    local new_line = line:sub(1, col) .. inserted .. line:sub(col + 1)
    vim.api.nvim_set_current_line(new_line)
    vim.api.nvim_win_set_cursor(0, { row, col + #inserted })
  end
end

return M
