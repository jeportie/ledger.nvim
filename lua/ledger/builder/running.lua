-- ledger.builder.running
--
-- Detects whether a pipeline step's build command is currently running in ANY
-- terminal — not just a task this Builder launched — so the dashboard can show
-- cross-session "in progress". A single `ps` scan (memoised, injectable) is
-- matched against each step's `match` signature. When a repo `root` is given, a
-- match only counts if the process is running UNDER that root, so two
-- ledger-live checkouts don't show each other's builds as in-progress (#61).

local uv = vim.uv or vim.loop

local M = {}

-- Default runner: PID + full command line of every process. BSD `ps axww` works
-- on macOS; procps accepts the same flags on Linux. Returns "" on any failure.
local function ps_runner()
  local ok, res = pcall(function()
    return vim.system({ "sh", "-c", "ps axww -o pid=,command=" }, { text = true }):wait()
  end)
  if ok and res and res.stdout then
    return res.stdout
  end
  return ""
end

-- The runner used by the memoised default path. Swappable so the TTL memo can
-- be unit-tested without a real `ps` (an explicitly-injected runner on the
-- public API still bypasses the memo entirely — see `listing_for`).
local default_runner = ps_runner

-- `running_steps` is called twice per refresh cycle (status pass + runtime
-- poll). The `ps axww` shell-out is the expensive part, so the listing is
-- memoised for a short TTL: repeated scans inside the window reuse it (the
-- pattern matching itself is cheap and always re-runs against the cached text).
local TTL_MS = 1500
local cache = { listing = nil, at = 0 }

local function now_ms()
  return (uv and uv.now and uv.now()) or (os.clock() * 1000)
end

-- Resolve the process listing. An explicitly-injected `runner` always runs
-- (callers that pass one — the unit tests — want deterministic, per-call
-- control). The default path is memoised for a short TTL so the twin per-cycle
-- scans share one shell-out.
local function listing_for(runner)
  if runner then
    return runner() or ""
  end
  local t = now_ms()
  if cache.listing ~= nil and (t - cache.at) < TTL_MS then
    return cache.listing
  end
  cache.listing = default_runner() or ""
  cache.at = t
  return cache.listing
end

-- Reset the listing memo (a manual refresh forces a fresh scan; tests use it to
-- isolate cases).
function M.invalidate()
  cache.listing = nil
  cache.at = 0
end

-- Test seam: swap the runner behind the memoised default path (pass nil to
-- restore the real `ps` scan). Lets the TTL memo be exercised deterministically.
function M._set_default_runner(fn)
  default_runner = fn or ps_runner
  M.invalidate()
end

-- Does `match` (a Lua pattern, or a list of patterns — any one hitting wins)
-- occur in `text`? Patterns (not plain substrings) so signatures like
-- "pnpm%S* i" catch `pnpm i`, `node …/pnpm.cjs i` and the proto shim.
local function matches(text, match)
  if type(match) == "table" then
    for _, pat in ipairs(match) do
      if pat ~= "" and text:find(pat) then
        return true
      end
    end
    return false
  end
  return match ~= "" and text:find(match) ~= nil
end

-- Resolve a process's working directory. Linux: the /proc cwd symlink (no
-- shell). macOS/BSD: `lsof -a -d cwd`. Returns nil when unknown.
local function default_cwd_of(pid)
  if not pid then
    return nil
  end
  local link = uv.fs_readlink and uv.fs_readlink("/proc/" .. pid .. "/cwd")
  if link and link ~= "" then
    return link
  end
  local ok, res = pcall(function()
    return vim.system({ "lsof", "-a", "-d", "cwd", "-p", tostring(pid), "-Fn" }, { text = true }):wait()
  end)
  if ok and res and res.stdout then
    -- field output: a `p<pid>` line then an `n<path>` line for the cwd fd
    return res.stdout:match("[\r\n]n([^\r\n]+)") or res.stdout:match("^n([^\r\n]+)")
  end
  return nil
end

-- Is `cwd` the same as, or nested under, `root`?
local function under(cwd, root)
  if not cwd or not root or root == "" then
    return false
  end
  root = root:gsub("/+$", "") -- tolerate a trailing slash on the configured root
  return cwd == root or cwd:sub(1, #root + 1) == root .. "/"
end

-- A set { [step_id] = true } for every step whose `match` signature appears in
-- the current process listing. When `root` is given, a match only counts if the
-- matching process's cwd is under `root` (so a build in another checkout doesn't
-- bleed in). `runner` (→ listing string) and `cwd_of` (pid → path) are injectable
-- for tests. With no `root`, matches unscoped against the whole listing (legacy).
function M.running_steps(steps, root, runner, cwd_of)
  local listing = listing_for(runner)
  if not root then
    local out = {}
    for _, step in ipairs(steps or {}) do
      if step.match and matches(listing, step.match) then
        out[step.id] = true
      end
    end
    return out
  end
  cwd_of = cwd_of or default_cwd_of
  local out = {}
  local cwd_cache = {}
  for line in listing:gmatch("[^\r\n]+") do
    local pid, cmd = line:match("^%s*(%d+)%s+(.*)$")
    if not pid then
      cmd = line -- a listing line without a leading pid: match, but cwd unknown
    end
    for _, step in ipairs(steps or {}) do
      if not out[step.id] and step.match and matches(cmd, step.match) then
        local cwd
        if pid then
          if cwd_cache[pid] == nil then
            cwd_cache[pid] = cwd_of(pid) or false
          end
          cwd = cwd_cache[pid] or nil
        end
        if under(cwd, root) then
          out[step.id] = true
        end
      end
    end
  end
  return out
end

return M
