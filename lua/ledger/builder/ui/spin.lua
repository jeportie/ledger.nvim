-- ledger.builder.ui.spin
--
-- Thin accessor over xieyonn/spinner.nvim's pattern catalogue
-- (`require("spinner.pattern")` → `{ name = { interval, frames }, ... }`). We
-- drive our own volt timers, so we only need the frame data — the spinner
-- engine is never started. Falls back to a builtin dotsCircle when the plugin
-- is absent, so the Builder animates fine without it.

local M = {}

-- dotsCircle (byte-for-byte the upstream pattern) — the safety net.
local FALLBACK = {
  interval = 80,
  frames = { "⢎ ", "⠎⠁", "⠊⠑", "⠈⠱", " ⡱", "⢀⡰", "⢄⡠", "⢆⡀" },
}

local cache = nil
local function catalogue()
  if cache ~= nil then
    return cache
  end
  local ok, pat = pcall(require, "spinner.pattern")
  cache = (ok and type(pat) == "table") and pat or false
  return cache
end

-- The pattern table `{ interval, frames }` for `name`, or the fallback when the
-- name is unknown / the plugin is missing.
function M.get(name)
  local cat = catalogue()
  local p = cat and name and cat[name]
  if type(p) == "table" and type(p.frames) == "table" and #p.frames > 0 then
    return p
  end
  return FALLBACK
end

-- The frame string for `name` at `tick` (0-based, wraps). Pass tick 0 to freeze
-- on the first frame (used when animation is disabled).
function M.frame(name, tick)
  local frames = M.get(name).frames
  return frames[((tick or 0) % #frames) + 1]
end

return M
