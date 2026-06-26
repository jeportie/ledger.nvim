-- ledger.builder.store
--
-- Per-repo, per-template result store so the pipeline's statuses + durations
-- survive closing nvim and are shared across concurrent vim/terminal sessions.
-- Unlike history.lua (a single in-memory-cached global array), this RE-READS
-- the file on every `get` so a build finished in one session shows up in
-- another. Shape:
--   { [repo_root] = { [template] = { code, duration, time } } }

local uv = vim.uv or vim.loop
local M = {}

local function path()
  return vim.fn.stdpath("data") .. "/ledger_builder_state.json"
end

local function read()
  local p = path()
  if not uv.fs_stat(p) then
    return {}
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(p), "\n"))
  end)
  return (ok and type(data) == "table") and data or {}
end

local function write(data)
  pcall(vim.fn.writefile, { vim.json.encode(data) }, path())
end

-- All persisted results for a repo (re-read fresh for cross-session liveness).
function M.get(root)
  if not root or root == "" then
    return {}
  end
  return read()[root] or {}
end

-- Record one template's result for a repo (read-modify-write; per-template
-- granularity keeps concurrent writers from clobbering each other's steps).
function M.record(root, template, code, duration)
  if not root or root == "" or not template then
    return
  end
  local data = read()
  data[root] = data[root] or {}
  data[root][template] = { code = code, duration = duration, time = os.time() }
  write(data)
end

function M._reset()
  write({})
end

function M._path()
  return path()
end

return M
