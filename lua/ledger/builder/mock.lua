-- ledger.builder.mock
--
-- TEMPORARY visual-review scaffolding. Per-target sample data for the Stats
-- panes so the History / Build-time / Pass-rate columns can be eyeballed before
-- any real runs exist. Gated by config `builder.mock_stats`; remove this module
-- (and the flag) once the Stats layout is approved.
--
-- Shapes mirror ledger.builder.history:
--   recent(target)          -> list (newest-last) of { time, label, code }
--   build_durations(target) -> list of seconds (oldest -> newest)
--   pass_rate(target)       -> rate(0-100), n

local M = {}

local function ago(mins)
  return os.time() - mins * 60
end

-- Distinct, realistic-looking data per target.
local DATA = {
  desktop = {
    recent = {
      { time = ago(64), label = "desktop · swap full flow", code = 1 },
      { time = ago(48), label = "desktop · receive bitcoin", code = 0 },
      { time = ago(33), label = "desktop · send ethereum", code = 0 },
      { time = ago(21), label = "desktop · account add", code = 0 },
      { time = ago(12), label = "desktop · settings", code = 0 },
      { time = ago(3), label = "desktop · swap full flow", code = 0 },
    },
    durations = { 318, 305, 332, 297, 311, 326, 301 },
    rate = { 88, 41 },
  },
  ios = {
    recent = {
      { time = ago(58), label = "ios · onboarding", code = 0 },
      { time = ago(40), label = "ios · send solana", code = 1 },
      { time = ago(27), label = "ios · receive", code = 1 },
      { time = ago(15), label = "ios · swap", code = 0 },
      { time = ago(4), label = "ios · onboarding", code = 0 },
    },
    durations = { 512, 498, 540, 521, 559, 505 },
    rate = { 72, 33 },
  },
  android = {
    recent = {
      { time = ago(70), label = "android · onboarding", code = 0 },
      { time = ago(52), label = "android · send", code = 0 },
      { time = ago(36), label = "android · receive", code = 1 },
      { time = ago(19), label = "android · account add", code = 0 },
      { time = ago(6), label = "android · onboarding", code = 0 },
    },
    durations = { 408, 421, 399, 437, 412 },
    rate = { 80, 25 },
  },
}

local function data(target)
  return DATA[target] or DATA.desktop
end

function M.recent(target)
  return vim.deepcopy(data(target).recent)
end

function M.build_durations(target)
  return vim.deepcopy(data(target).durations)
end

function M.pass_rate(target)
  local r = data(target).rate
  return r[1], r[2]
end

return M
