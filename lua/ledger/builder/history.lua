-- ledger.builder.history
--
-- A small persisted log of build/test runs that feeds the Builder dashboard's
-- Stats pane (HISTORY table, BUILD-TIME graph, PASS-RATE bar). Entries:
--   { time=<os.time>, label, kind="build"|"test"|..., code, duration }
-- Persisted as JSON under stdpath('data'); capped to MAX entries.

local M = {}

local MAX = 100

local function path()
  return vim.fn.stdpath("data") .. "/ledger_builder_history.json"
end

-- in-memory cache (loaded lazily)
M._entries = nil

local function load()
  if M._entries then
    return M._entries
  end
  M._entries = {}
  local p = path()
  if vim.fn.filereadable(p) == 1 then
    local ok, decoded = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(p), "\n"))
    end)
    if ok and type(decoded) == "table" then
      M._entries = decoded
    end
  end
  return M._entries
end

local function save()
  local p = path()
  local ok, encoded = pcall(vim.json.encode, M._entries or {})
  if ok then
    pcall(vim.fn.writefile, { encoded }, p)
  end
end

-- Record a finished run. Returns the stored entry.
function M.record(entry)
  local list = load()
  local e = {
    time = entry.time or os.time(),
    label = entry.label or "?",
    kind = entry.kind or "task",
    code = entry.code,
    duration = entry.duration,
    platform = entry.platform, -- "desktop" | "ios" | "android" | nil
  }
  list[#list + 1] = e
  while #list > MAX do
    table.remove(list, 1)
  end
  save()
  return e
end

-- Most recent `n` entries, newest last (chronological), optionally filtered by
-- kind and/or platform.
function M.recent(n, kind, platform)
  local list = load()
  local filtered = {}
  for _, e in ipairs(list) do
    if (not kind or e.kind == kind) and (not platform or e.platform == platform) then
      filtered[#filtered + 1] = e
    end
  end
  n = n or 8
  local out = {}
  local start = math.max(1, #filtered - n + 1)
  for i = start, #filtered do
    out[#out + 1] = filtered[i]
  end
  return out
end

-- Pass rate (0-100) over the last `n` test runs, or nil if none.
function M.pass_rate(n, platform)
  local tests = M.recent(n or 50, "test", platform)
  if #tests == 0 then
    return nil
  end
  local pass = 0
  for _, e in ipairs(tests) do
    if e.code == 0 then
      pass = pass + 1
    end
  end
  return math.floor((pass / #tests) * 100), #tests
end

-- Recent build durations (seconds), oldest→newest.
function M.build_durations(n, platform)
  local out = {}
  for _, e in ipairs(M.recent(n or 12, "build", platform)) do
    out[#out + 1] = e.duration or 0
  end
  return out
end

-- Test-only helpers.
function M._reset()
  M._entries = {}
  save()
end

function M._path()
  return path()
end

return M
