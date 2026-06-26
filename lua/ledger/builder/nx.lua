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

-- Read a file, ANSI-strip each line, drop blanks. {} on any failure.
local function read_stripped(path)
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or type(raw) ~= "table" then
    return {}
  end
  local strip = require("ledger.tasks").strip_ansi
  local out = {}
  for _, line in ipairs(raw) do
    local s = strip(line)
    if s ~= "" then
      out[#out + 1] = s
    end
  end
  return out
end

-- Keep the last `max` lines (the tail — where build summaries / errors land).
local function tail(lines, max)
  max = max or 2000
  if #lines <= max then
    return lines
  end
  local out = {}
  for i = #lines - max + 1, #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

-- The captured output for a SINGLE task hash (the leaf-task fallback),
-- ANSI-stripped, last `max` lines.
function M.log_lines(root, hash, max)
  if not root or not hash then
    return {}
  end
  return tail(read_stripped(root .. "/.nx/cache/terminalOutputs/" .. hash), max or 1000)
end

-- The most recent `nx` invocation, from .nx/cache/run.json, IF it targeted
-- `project` (run.command names it). Returns { id, hashes }: `id` (the run's
-- endTime) changes when a new build completes; `hashes` are the run's task
-- hashes ordered by start time. nil otherwise (latest run is a different
-- project, or no run.json). One cheap JSON read.
function M.run_meta(root, project)
  if not root or not project or project == "" then
    return nil
  end
  local ok0, raw = pcall(vim.fn.readfile, root .. "/.nx/cache/run.json")
  if not ok0 or type(raw) ~= "table" or #raw == 0 then
    return nil
  end
  local ok, data = pcall(vim.json.decode, table.concat(raw, "\n"))
  if not ok or type(data) ~= "table" or type(data.run) ~= "table" then
    return nil
  end
  if not (data.run.command or ""):find(project, 1, true) then
    return nil
  end
  local ordered = {}
  for _, t in ipairs(data.tasks or {}) do
    if t.hash then
      ordered[#ordered + 1] = { hash = t.hash, at = t.startTime or "" }
    end
  end
  table.sort(ordered, function(a, b)
    return a.at < b.at
  end)
  local hashes = {}
  for _, t in ipairs(ordered) do
    hashes[#hashes + 1] = t.hash
  end
  if #hashes == 0 then
    return nil
  end
  return { id = tostring(data.run.endTime or data.run.startTime or #hashes), hashes = hashes }
end

-- Concatenate the per-task logs for a whole `nx run-many` build (each file
-- self-labels with `> nx run <taskId>`), ANSI-stripped, last `max` lines.
function M.concat_logs(root, hashes, max)
  if not root or type(hashes) ~= "table" then
    return {}
  end
  local lines = {}
  for _, hash in ipairs(hashes) do
    for _, s in ipairs(read_stripped(root .. "/.nx/cache/terminalOutputs/" .. hash)) do
      lines[#lines + 1] = s
    end
  end
  return tail(lines, max or 2000)
end

-- Project graph (project-graph.json): name → root, for the project picker and
-- file→project mapping. Cached per root, re-decoded only when the file's mtime
-- changes; we keep just the {name, root} pairs (the graph file is multi-MB),
-- sorted longest-root-first so prefix matching picks the most specific project.
local _proj_cache = {}

function M.projects(root)
  if not root then
    return {}
  end
  local path = root .. "/.nx/workspace-data/project-graph.json"
  local st = (vim.uv or vim.loop).fs_stat(path)
  if not st then
    return {}
  end
  local cached = _proj_cache[root]
  if cached and cached.mtime == st.mtime.sec then
    return cached.list
  end
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or type(raw) ~= "table" then
    return {}
  end
  local ok2, data = pcall(vim.json.decode, table.concat(raw, "\n"))
  if not ok2 or type(data) ~= "table" or type(data.nodes) ~= "table" then
    return {}
  end
  local list = {}
  for name, node in pairs(data.nodes) do
    local r = node and node.data and node.data.root
    if type(r) == "string" and r ~= "" then
      local targets = node.data.targets
      list[#list + 1] = { name = name, root = r, has_build = type(targets) == "table" and targets.build ~= nil }
    end
  end
  table.sort(list, function(a, b)
    if #a.root ~= #b.root then
      return #a.root > #b.root
    end
    return a.name < b.name
  end)
  _proj_cache[root] = { mtime = st.mtime.sec, list = list }
  return list
end

-- The nx project record owning `abspath` (longest root prefix), or nil.
local function record_for_file(root, abspath)
  if not root or not abspath then
    return nil
  end
  local prefix = root:gsub("/+$", "") .. "/"
  if abspath:sub(1, #prefix) ~= prefix then
    return nil
  end
  local rel = abspath:sub(#prefix + 1)
  for _, p in ipairs(M.projects(root)) do -- sorted longest-root-first
    local pr = p.root:gsub("/+$", "")
    if pr ~= "" and (rel == pr or rel:sub(1, #pr + 1) == pr .. "/") then
      return p
    end
  end
  return nil
end

-- The nx project owning `abspath`, or nil.
function M.project_for_file(root, abspath)
  local p = record_for_file(root, abspath)
  return p and p.name or nil
end

-- Same, but only when the owning project has a `build` target (so saving a
-- non-buildable file doesn't spawn a no-op rebuild).
function M.buildable_project_for_file(root, abspath)
  local p = record_for_file(root, abspath)
  return (p and p.has_build) and p.name or nil
end

return M
