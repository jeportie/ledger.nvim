-- ledger.builder.running
--
-- Detects whether a pipeline step's build command is currently running in ANY
-- terminal — not just a task this Builder launched — so the dashboard can show
-- cross-session "in progress". Mirrors the proc.lua pattern: ONE process scan
-- via an injectable runner, matched against each step's `match` signature.

local uv = vim.uv or vim.loop

local M = {}

-- Default runner: the full command line of every process. BSD `ps axww` works
-- on macOS; procps accepts the same flags on Linux. Returns "" on any failure.
local function ps_runner()
  local ok, res = pcall(function()
    return vim.system({ "sh", "-c", "ps axww -o command=" }, { text = true }):wait()
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
-- (callers that pass one — the existing unit tests — want deterministic,
-- per-call control). The default path is memoised for a short TTL so the twin
-- per-cycle scans share one shell-out.
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
-- occur in the process listing? Patterns (not plain substrings) so signatures
-- like "pnpm%S* i" catch `pnpm i`, `node …/pnpm.cjs i` and the proto shim.
local function matches(listing, match)
  if type(match) == "table" then
    for _, pat in ipairs(match) do
      if pat ~= "" and listing:find(pat) then
        return true
      end
    end
    return false
  end
  return match ~= "" and listing:find(match) ~= nil
end

-- A set { [step_id] = true } for every step whose `match` (pattern or list of
-- patterns) appears in the current process listing. `runner` (injectable for
-- tests) returns that listing as a string.
function M.running_steps(steps, runner)
  local listing = listing_for(runner)
  local out = {}
  for _, step in ipairs(steps or {}) do
    if step.match and matches(listing, step.match) then
      out[step.id] = true
    end
  end
  return out
end

return M
