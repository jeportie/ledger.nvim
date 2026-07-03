-- ledger.builder.settings
--
-- A tiny persisted overlay for the Builder's visual/behaviour options. `setup{}`
-- config (lua/ledger/config.lua → M.get().builder) is read-only; this module is
-- the runtime layer stacked on top of it so the `S` settings menu can flip a
-- toggle and have it survive an nvim restart.
--
-- Only USER-OVERRIDDEN builder keys are stored (a flat table keyed by the same
-- names as M.defaults.builder), so the file stays minimal and the overlay in
-- builder.init's cfg() is a clean vim.tbl_deep_extend over the config table.
-- Persisted as JSON under stdpath('data'). Modelled on ledger.builder.history.

local M = {}

local function path()
  return vim.fn.stdpath("data") .. "/ledger_builder_settings.json"
end

-- in-memory cache (loaded lazily)
M._overrides = nil

function M.load()
  if M._overrides then
    return M._overrides
  end
  M._overrides = {}
  local p = path()
  if vim.fn.filereadable(p) == 1 then
    local ok, decoded = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(p), "\n"))
    end)
    if ok and type(decoded) == "table" then
      M._overrides = decoded
    end
  end
  return M._overrides
end

local function save()
  local p = path()
  local ok, encoded = pcall(vim.json.encode, M._overrides or {})
  if ok then
    pcall(vim.fn.writefile, { encoded }, p)
  end
end

-- The persisted override for `key`, or nil if the user hasn't set it (in which
-- case the config default applies through the overlay).
function M.get(key)
  return M.load()[key]
end

-- Persist a single override and return it. Passing nil clears the override so
-- the config default takes over again.
function M.set(key, val)
  local o = M.load()
  o[key] = val
  save()
  return val
end

-- Test-only helpers (mirror history.lua).
function M._reset()
  M._overrides = {}
  save()
end

function M._path()
  return path()
end

return M
