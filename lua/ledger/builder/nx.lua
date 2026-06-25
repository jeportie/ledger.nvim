-- ledger.builder.nx
--
-- Reads build outcomes + logs straight from the monorepo's Nx cache, so the
-- Builder reflects builds run in ANOTHER terminal (not just ones it launched).
-- Nx 22 persists, on disk:
--   * .nx/workspace-data/<UUID>.db  — SQLite; `task_history` keeps the exit
--     `code` (+ `hash`) per project/target across runs, joinable to
--     `task_details`.
--   * .nx/cache/terminalOutputs/<hash> — that task's captured stdout (with ANSI).
--
-- `build_result` takes an injectable `runner` (like running.lua / proc.lua) so
-- it's unit-testable without a real sqlite3 or DB. Everything degrades to nil /
-- {} when sqlite3, the DB, or the log file is absent.

local M = {}

-- The SQLite workspace DB (filename is a UUID), or nil.
function M.db_path(root)
  if not root then
    return nil
  end
  local hits = vim.fn.glob(root .. "/.nx/workspace-data/*.db", true, true)
  return hits[1]
end

-- Default runner: query the DB with the `sqlite3` CLI. The DB is WAL-mode, and
-- Nx runs daemonless, so after a build there's often no -wal/-shm sidecar —
-- plain `-readonly` then fails (SQLITE_CANTOPEN). `immutable=1` opens it as a
-- static file (no shm needed); the build process has already exited by the time
-- we read, so there's no concurrent writer. Returns "" on any failure (no
-- sqlite3, transient error, etc.) → callers fall back gracefully.
local function default_runner(db, sql)
  local ok, res = pcall(function()
    return vim.system({ "sqlite3", "file:" .. db .. "?immutable=1", sql }, { text = true }):wait()
  end)
  if ok and res and res.code == 0 and res.stdout then
    return res.stdout
  end
  return ""
end

-- Parse sqlite3's pipe-separated `code|hash` row.
local function parse_row(out)
  local code, hash = (out or ""):match("^%s*(%-?%d+)|(%S+)")
  if not code then
    return nil
  end
  return { code = tonumber(code), hash = hash }
end

-- Latest build result for an Nx project: { code, hash } | nil. `code == 0` ⇒
-- success; the `hash` keys the terminal-output log. Covers builder-launched AND
-- external builds (both go through Nx). `runner(db, sql) -> string` is injectable.
function M.build_result(root, project, runner)
  if not root or not project or project == "" then
    return nil
  end
  local db = M.db_path(root)
  if not db then
    return nil
  end
  local sql = string.format(
    "SELECT th.code, th.hash FROM task_history th "
      .. "JOIN task_details td ON th.hash = td.hash "
      .. "WHERE td.project = '%s' AND td.target = 'build' "
      .. "ORDER BY th.id DESC LIMIT 1;",
    project
  )
  return parse_row((runner or default_runner)(db, sql))
end

-- The captured terminal output for a task hash, ANSI-stripped, last `max` lines.
function M.log_lines(root, hash, max)
  if not root or not hash then
    return {}
  end
  local ok, raw = pcall(vim.fn.readfile, root .. "/.nx/cache/terminalOutputs/" .. hash)
  if not ok or type(raw) ~= "table" then
    return {}
  end
  local strip = require("ledger.tasks").strip_ansi
  local lines = {}
  for _, line in ipairs(raw) do
    local s = strip(line)
    if s ~= "" then
      lines[#lines + 1] = s
    end
  end
  max = max or 1000
  if #lines > max then
    local out = {}
    for i = #lines - max + 1, #lines do
      out[#out + 1] = lines[i]
    end
    return out
  end
  return lines
end

return M
