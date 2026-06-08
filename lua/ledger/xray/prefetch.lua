local M = {}

local cache = require("ledger.xray.cache")
local util = require("ledger.xray.util")

local pattern = util.id_pattern

local scanned = {}

local function scan_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local seen, out = {}, {}
  for _, line in ipairs(lines) do
    for id in line:gmatch(pattern) do
      if not seen[id] then
        seen[id] = true
        table.insert(out, id)
      end
    end
  end
  return out
end

local function debounced_scan(buf)
  scanned[buf] = (scanned[buf] or 0) + 1
  local tick = scanned[buf]
  vim.defer_fn(function()
    if scanned[buf] ~= tick then
      return
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local keys = scan_buffer(buf)
    if #keys == 0 then
      return
    end
    cache.fetch_batch(keys, nil)
  end, 400)
end

function M.setup()
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = vim.api.nvim_create_augroup("xray_prefetch", { clear = true }),
    callback = function(args)
      local buf = args.buf
      if not vim.api.nvim_buf_is_loaded(buf) then
        return
      end
      if vim.bo[buf].buftype ~= "" then
        return
      end
      debounced_scan(buf)
    end,
  })

  vim.schedule(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
        debounced_scan(buf)
      end
    end
  end)
end

return M
