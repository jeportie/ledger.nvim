local M = {}

local config = require("ledger.xray.config")
local jira_util = require("ledger.jira.util")

M.ticket_url          = jira_util.ticket_url
M.open_url            = jira_util.open_url
M.screen_cursor_anchor = jira_util.screen_cursor_anchor
M.clean_float_window  = jira_util.clean_float_window
M.disable_completion  = jira_util.disable_completion

M.id_pattern = "B2CQA%-%d+"

function M.extract_id(s)
  if not s or s == "" then return nil end
  return s:match(M.id_pattern)
end

function M.cword_id()
  local word = vim.fn.expand("<cWORD>")
  local id = M.extract_id(word)
  if id then return id end
  return M.extract_id(vim.fn.expand("<cword>"))
end

local function is_ledger_live_root(dir)
  if vim.fn.isdirectory(dir .. "/apps/ledger-live-desktop") == 1 then
    return true
  end
  local pkg = dir .. "/package.json"
  if vim.fn.filereadable(pkg) == 1 then
    local ok, lines = pcall(vim.fn.readfile, pkg, "", 30)
    if ok and lines then
      for _, line in ipairs(lines) do
        if line:match('"name"%s*:%s*"ledger%-live"') then
          return true
        end
      end
    end
  end
  return false
end

function M.classify_path(path)
  if path:find("/ledger%-live%-desktop/", 1) or path:find("/e2e/desktop/", 1) then
    return "desktop"
  elseif path:find("/ledger%-live%-mobile/", 1) or path:find("/e2e/mobile/", 1) then
    return "mobile"
  else
    return "other"
  end
end

function M.find_ledger_live_root(start)
  if config.options.ledger_live_root then
    return config.options.ledger_live_root
  end

  start = start or vim.fn.getcwd()
  local dir = vim.fn.fnamemodify(start, ":p")
  dir = dir:gsub("/+$", "")

  for _ = 1, 12 do
    if dir == "" or dir == "/" then break end
    if is_ledger_live_root(dir) then return dir end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end

  return nil
end

return M
