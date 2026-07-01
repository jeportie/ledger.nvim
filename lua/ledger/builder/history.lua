-- ledger.builder.history
--
-- A small persisted log of build/test runs that feeds the Builder dashboard's
-- Stats pane (HISTORY table, BUILD-TIME graph, PASS-RATE bar). Entries:
--   { time=<os.time>, label, kind="build"|"test"|..., code, duration, log? }
-- Persisted as JSON under stdpath('data'); capped to MAX entries. Each entry
-- may carry a `log` path pointing at a sidecar file (under the log dir) holding
-- that run's captured output, so a past run's full log survives an nvim restart.

local M = {}

local MAX = 100

local function path()
  return vim.fn.stdpath("data") .. "/ledger_builder_history.json"
end

-- Directory holding the per-run sidecar log files.
local function log_dir()
  return vim.fn.stdpath("data") .. "/ledger_builder_logs"
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

-- Write a run's captured output to a sidecar file and return its path (nil on
-- empty input). The name is `<time>-<sanitized-id>.log`; the id's non-alphanumerics
-- collapse to `_` so any task key is filesystem-safe.
function M.write_log(time, id, lines)
  if not lines or #lines == 0 then
    return nil
  end
  local dir = log_dir()
  vim.fn.mkdir(dir, "p")
  local safe = tostring(id or "task"):gsub("[^%w]", "_")
  local p = dir .. "/" .. tostring(time or os.time()) .. "-" .. safe .. ".log"
  local ok = pcall(vim.fn.writefile, lines, p)
  return ok and p or nil
end

-- Read back a stored entry's sidecar log; {} when absent or unreadable.
function M.log_lines(entry)
  local p = entry and entry.log
  if not p or vim.fn.filereadable(p) ~= 1 then
    return {}
  end
  local ok, lines = pcall(vim.fn.readfile, p)
  return (ok and lines) or {}
end

-- Record a finished run. Returns the stored entry. `entry.log` (optional) is a
-- sidecar path from M.write_log; entries without it stay valid (back-compat).
function M.record(entry)
  local list = load()
  local e = {
    time = entry.time or os.time(),
    label = entry.label or "?",
    kind = entry.kind or "task",
    code = entry.code,
    duration = entry.duration,
    platform = entry.platform, -- "desktop" | "ios" | "android" | nil
    log = entry.log, -- sidecar log path (optional)
  }
  list[#list + 1] = e
  -- Drop the oldest entries beyond MAX, deleting each evicted sidecar so the
  -- log dir stays bounded (history is capped at MAX runs on disk too).
  while #list > MAX do
    local dropped = table.remove(list, 1)
    if dropped and dropped.log then
      pcall(vim.fn.delete, dropped.log)
    end
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

function M._log_dir()
  return log_dir()
end

return M
