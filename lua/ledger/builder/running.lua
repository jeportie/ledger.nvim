-- ledger.builder.running
--
-- Detects whether a pipeline step's build command is currently running in ANY
-- terminal — not just a task this Builder launched — so the dashboard can show
-- cross-session "in progress". Mirrors the proc.lua pattern: ONE process scan
-- via an injectable runner, matched against each step's `match` signature.

local M = {}

-- Default runner: the full command line of every process. BSD `ps axww` works
-- on macOS; procps accepts the same flags on Linux. Returns "" on any failure.
local function default_runner()
  local ok, res = pcall(function()
    return vim.system({ "sh", "-c", "ps axww -o command=" }, { text = true }):wait()
  end)
  if ok and res and res.stdout then
    return res.stdout
  end
  return ""
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
  local listing = (runner or default_runner)() or ""
  local out = {}
  for _, step in ipairs(steps or {}) do
    if step.match and matches(listing, step.match) then
      out[step.id] = true
    end
  end
  return out
end

return M
