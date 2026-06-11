-- ledger.builder.staleness
--
-- v1 mtime gate: a build artifact is "stale" if any source file under the
-- declared source dirs is newer than it (or if the artifact is missing).
-- Uses `find -newer` (fast, stops at the first newer file). The runner is
-- injectable so the logic is unit-testable. (nx-affected detection is the v2
-- upgrade — see LN-030.)

local uv = vim.uv or vim.loop

local M = {}

local function default_runner(cmd)
  local res = vim.system(cmd, { text = true }):wait()
  return res.stdout or ""
end

-- Is `artifact` (absolute path) stale relative to `sources` (list of absolute
-- paths to scan)? Missing artifact = stale. `runner(cmd_list) -> stdout`.
function M.is_stale(artifact, sources, runner)
  runner = runner or default_runner
  if not uv.fs_stat(artifact) then
    return true
  end
  for _, src in ipairs(sources or {}) do
    if uv.fs_stat(src) then
      local out = runner({ "find", src, "-type", "f", "-newer", artifact, "-print", "-quit" })
      if out and out:gsub("%s+", "") ~= "" then
        return true
      end
    end
  end
  return false
end

-- Convenience: freshness label for an artifact, or nil if the step has no
-- artifact to check.
function M.freshness(artifact, sources, runner)
  if not artifact then
    return nil
  end
  if not uv.fs_stat(artifact) then
    return "missing"
  end
  return M.is_stale(artifact, sources, runner) and "stale" or "fresh"
end

return M
