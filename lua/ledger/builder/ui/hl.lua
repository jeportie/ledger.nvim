-- ledger.builder.ui.hl
--
-- Window-local highlight namespace modelled on wrapped.nvim's ui/hl.lua: an
-- opaque (border-aware) panel + intensity-leveled accent colours
-- Ledger{Red,Green,Blue,Yellow}{0..3} mixed into the panel bg via volt.color,
-- plus Title/Label/Separator and the state/tab/pulse aliases the panes use.
-- Bound to the float with nvim_win_set_hl_ns so it stays solid under a
-- transparent colorscheme without touching global highlights.

local api = vim.api
local M = {}

M.ns = nil

local function get_hl(name)
  return require("volt.utils").get_hl(name)
end
local function lighten(hex, pct)
  return require("volt.color").change_hex_lightness(hex, pct)
end
local function mix(a, b, pct)
  return require("volt.color").mix(a, b, pct)
end

local function panel_bg()
  if vim.g.base46_cache then
    local ok, colors = pcall(dofile, vim.g.base46_cache .. "colors")
    if ok and colors and colors.black then
      return colors.black
    end
  end
  return get_hl("Normal").bg
end

-- Define all builder groups inside `ns`. `opts.border` / `opts.transparent`
-- shape the panel bg (matches wrapped.nvim).
function M.apply_float(ns)
  if not get_hl("ExBlue").fg then
    require("volt.highlights")
  end
  local cfg = require("ledger.config").get().builder or {}
  local border = cfg.border
  local transparent = cfg.transparent

  local bg = panel_bg()
  local has_bg = bg ~= nil and not transparent
  local fallback = bg or "#1e1e2e"
  local win_bg_col = has_bg and bg or fallback
  local win_bg = (not has_bg) and "NONE" or (border and win_bg_col or lighten(win_bg_col, 2))
  local text = get_hl("Normal").fg or "#cdd6f4"
  local comment = get_hl("Comment").fg or "#6c7086"

  local set = function(group, o)
    pcall(api.nvim_set_hl, ns, group, o)
  end

  set("Normal", { bg = win_bg, fg = text })
  set("NormalFloat", { bg = win_bg, fg = text })
  set("FloatBorder", {
    fg = border and lighten(fallback, 15) or win_bg_col,
    bg = (not has_bg) and "NONE" or win_bg,
  })
  set("LedgerTitle", { fg = get_hl("ExBlue").fg, bold = true })
  set("LedgerLabel", { fg = lighten(comment, 20) })
  set("LedgerSeparator", { fg = mix(comment, win_bg_col, 60) })

  -- intensity-leveled accents (0 brightest … 3 dimmest)
  local sources = {
    Red = get_hl("ExRed").fg,
    Green = get_hl("ExGreen").fg,
    Blue = get_hl("ExBlue").fg,
    Yellow = get_hl("ExYellow").fg,
  }
  local levels = { 10, 40, 60, 80 }
  for name, fg in pairs(sources) do
    for i, pct in ipairs(levels) do
      set(("Ledger%s%d"):format(name, i - 1), { fg = mix(fg, win_bg_col, pct) })
    end
  end

  -- semantic / builder aliases used throughout the panes
  local aliases = {
    LedgerStateDone = "LedgerGreen0",
    LedgerStateRunning = "LedgerBlue0",
    LedgerStateStale = "LedgerYellow0",
    LedgerStateFailed = "LedgerRed0",
    LedgerStatePending = "LedgerSeparator",
    LedgerBuilderTitle = "LedgerTitle",
    LedgerBuilderDim = "LedgerLabel",
    LedgerBuilderKey = "LedgerYellow0",
    LedgerBuilderOn = "LedgerGreen0",
    LedgerBuilderOff = "LedgerSeparator",
    LedgerTabInactive = "LedgerSeparator",
    LedgerPulse0 = "LedgerBlue0",
    LedgerPulse1 = "LedgerBlue1",
    LedgerPulse2 = "LedgerBlue2",
  }
  for group, target in pairs(aliases) do
    set(group, { link = target })
  end
  set("LedgerTabActive", { fg = get_hl("ExBlue").fg, bg = mix(get_hl("ExBlue").fg, win_bg_col, 78), bold = true })
  set("LedgerScan", { bg = mix(get_hl("ExBlue").fg, win_bg_col, 88) })
end

-- Pulse highlight name for a given tick (heartbeat 0→1→2→1→0…).
function M.pulse(tick)
  local seq = { 0, 1, 2, 1 }
  return "LedgerPulse" .. seq[(math.floor(tick / 2) % #seq) + 1]
end

-- Compatibility entry point: ensure ns exists and groups are defined.
function M.setup()
  M.ns = M.ns or api.nvim_create_namespace("ledger_builder_hl")
  M.apply_float(M.ns)
  return M.ns
end

return M
