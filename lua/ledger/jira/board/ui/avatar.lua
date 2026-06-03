local M = {}

local function cache_dir()
  local d = vim.fn.stdpath("cache") .. "/jira-board/avatars"
  vim.fn.mkdir(d, "p")
  return d
end

local function cache_path(account_id)
  local safe = (account_id or "me"):gsub("[^%w_%-]", "_")
  return cache_dir() .. "/" .. safe .. ".png"
end

local function circle_path(account_id)
  local safe = (account_id or "me"):gsub("[^%w_%-]", "_")
  return cache_dir() .. "/" .. safe .. ".circle32.png"
end

local function magick_bin()
  for _, name in ipairs({ "magick", "convert" }) do
    if vim.fn.executable(name) == 1 then return name end
  end
  return nil
end

-- Produce a circular-cropped PNG next to the raw avatar. Returns the cropped
-- path (or the original if imagemagick is unavailable / the crop fails).
local function ensure_circle(raw_path, account_id, cb)
  local out = circle_path(account_id)
  if vim.fn.filereadable(out) == 1 then return cb(out) end
  local bin = magick_bin()
  if not bin then return cb(raw_path) end
  local size = 32
  local args = {
    bin, raw_path,
    "-resize", size .. "x" .. size .. "^",
    "-gravity", "center",
    "-extent", size .. "x" .. size,
    "(", "-size", size .. "x" .. size, "xc:none",
         "-fill", "white",
         "-draw", string.format("circle %d,%d %d,0", size / 2, size / 2, size / 2),
    ")",
    "-compose", "CopyOpacity", "-composite",
    out,
  }
  vim.system(args, { text = true }, function(res)
    vim.schedule(function()
      if res and res.code == 0 and vim.fn.filereadable(out) == 1 then
        cb(out)
      else
        pcall(os.remove, out)
        cb(raw_path)
      end
    end)
  end)
end

local function snacks_image()
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks or not snacks.image then return nil end
  return snacks.image
end

local function auth_header()
  local cfg = require("ledger.jira.config")
  local creds = cfg.credentials()
  if not creds then return nil end
  local raw = creds.email .. ":" .. creds.token
  local b64
  if vim.base64 and vim.base64.encode then
    b64 = vim.base64.encode(raw)
  else
    local ok, plen = pcall(require, "plenary.base64")
    if not ok then return nil end
    b64 = plen.encode(raw)
  end
  return "Basic " .. b64
end

-- Download avatar URL to cache and produce a circle-cropped copy.
-- cb(path) on success, cb(nil) on failure.
function M.ensure_cached(account_id, url, cb)
  if not (account_id and url and url ~= "") then return cb(nil) end
  local raw = cache_path(account_id)
  local circle = circle_path(account_id)

  if vim.fn.filereadable(circle) == 1 then return cb(circle) end
  if vim.fn.filereadable(raw) == 1 then
    return ensure_circle(raw, account_id, cb)
  end

  local ok, curl = pcall(require, "plenary.curl")
  if not ok then return cb(nil) end
  local auth = auth_header()
  if not auth then return cb(nil) end
  curl.get(url, {
    output = raw,
    headers = { Authorization = auth, Accept = "image/png,image/*" },
    callback = function(res)
      vim.schedule(function()
        if res and (res.status or 0) >= 200 and (res.status or 0) < 300 and vim.fn.filereadable(raw) == 1 then
          ensure_circle(raw, account_id, cb)
        else
          pcall(os.remove, raw)
          cb(nil)
        end
      end)
    end,
  })
end

-- Place an image at (row, col). Returns placement or nil on failure.
-- row/col are 1-based row and 0-based col.
function M.place(buf, path, row, col, width)
  local img = snacks_image()
  if not img then return nil end
  if not (path and vim.fn.filereadable(path) == 1) then return nil end
  local ok, placement = pcall(function()
    return img.placement.new(buf, path, {
      inline = true,
      conceal = true,
      pos = { row, col },
      range = { row, col, row, col + (width or 2) },
    })
  end)
  if ok then return placement end
  return nil
end

function M.close(placement)
  if placement and type(placement.close) == "function" then
    pcall(function() placement:close() end)
  end
end

return M
