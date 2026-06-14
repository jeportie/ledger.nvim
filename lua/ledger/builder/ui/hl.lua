-- ledger.builder.ui.hl
--
-- Highlight groups for the Builder dashboard. Two layers:
--   * global accent aliases (LedgerState*, LedgerBuilder*) linked to volt's
--     Ex* groups so colours track the theme: done=green, running=blue,
--     failed=red, stale=yellow, pending/dim=grey.
--   * an opaque, slightly-tinted panel background (LedgerBuilderNormal) derived
--     from the theme's Normal/NormalFloat bg, applied to the float via a
--     window-local namespace so the dashboard is solid even under a
--     transparent colorscheme. Pulse variants give running items a heartbeat.

local M = {}

-- window-local highlight namespace (created lazily)
M.ns = nil

local function hexbg(name, fallback)
  local h = vim.api.nvim_get_hl(0, { name = name, link = false })
  if h and h.bg then
    return string.format("#%06x", h.bg)
  end
  return fallback
end

local function hexfg(name, fallback)
  local h = vim.api.nvim_get_hl(0, { name = name, link = false })
  if h and h.fg then
    return string.format("#%06x", h.fg)
  end
  return fallback
end

-- Resolve the opaque panel background: prefer Normal's real bg, else
-- NormalFloat, else a sensible dark fallback; lightened slightly so the panel
-- reads as a distinct surface.
local function panel_bg()
  local bg = hexbg("Normal", nil) or hexbg("NormalFloat", nil) or "#1e1e2e"
  local ok, lighten = pcall(function()
    return require("volt.color").change_hex_lightness
  end)
  if ok and lighten then
    return lighten(bg, 3)
  end
  return bg
end

-- Global accent aliases (theme-tracking).
M.groups = {
  LedgerBuilderTitle = { link = "ExBlue" },
  LedgerBuilderDim = { link = "Comment" },
  LedgerBuilderKey = { link = "ExYellow" },
  LedgerBuilderOn = { link = "ExGreen" },
  LedgerBuilderOff = { link = "Comment" },
  LedgerStateDone = { link = "ExGreen" },
  LedgerStateRunning = { link = "ExBlue" },
  LedgerStatePending = { link = "Comment" },
  LedgerStateStale = { link = "ExYellow" },
  LedgerStateFailed = { link = "ExRed" },
}

-- Define global aliases + the ns-local opaque panel + tinted accents + pulse
-- variants. `transparent` skips the opaque bg (see-through panel).
function M.setup(opts)
  opts = opts or {}
  for name, def in pairs(M.groups) do
    pcall(vim.api.nvim_set_hl, 0, name, vim.tbl_extend("force", { default = true }, def))
  end

  M.ns = M.ns or vim.api.nvim_create_namespace("ledger_builder_hl")
  local ns = M.ns

  local bg = opts.transparent and nil or panel_bg()
  local fg = hexfg("Normal", "#cdd6f4")

  if bg then
    vim.api.nvim_set_hl(0, "LedgerBuilderNormal", { bg = bg, fg = fg })
    vim.api.nvim_set_hl(ns, "Normal", { link = "LedgerBuilderNormal" })
    vim.api.nvim_set_hl(ns, "NormalFloat", { link = "LedgerBuilderNormal" })
  else
    vim.api.nvim_set_hl(0, "LedgerBuilderNormal", { link = "Normal" })
  end
  vim.api.nvim_set_hl(ns, "FloatBorder", { link = "LedgerBuilderTitle" })

  -- pulse variants for running items: cycle bright→dim by tick. Mix the blue
  -- accent toward the panel bg at a few strengths.
  local mix
  local ok = pcall(function()
    mix = require("volt.color").mix
  end)
  local blue = hexfg("ExBlue", "#89b4fa")
  local base = bg or hexbg("Normal", "#1e1e2e")
  if ok and mix and base then
    vim.api.nvim_set_hl(0, "LedgerPulse0", { fg = blue })
    vim.api.nvim_set_hl(0, "LedgerPulse1", { fg = mix(blue, base, 45) })
    vim.api.nvim_set_hl(0, "LedgerPulse2", { fg = mix(blue, base, 70) })
    -- tabs: active = bright fg on a tinted bg; inactive = dim
    vim.api.nvim_set_hl(0, "LedgerTabActive", { fg = blue, bg = mix(blue, base, 78), bold = true })
    vim.api.nvim_set_hl(0, "LedgerTabInactive", { link = "Comment" })
    vim.api.nvim_set_hl(0, "LedgerScan", { bg = mix(blue, base, 88) })
  else
    vim.api.nvim_set_hl(0, "LedgerPulse0", { link = "LedgerStateRunning" })
    vim.api.nvim_set_hl(0, "LedgerPulse1", { link = "LedgerStateRunning" })
    vim.api.nvim_set_hl(0, "LedgerPulse2", { link = "LedgerBuilderDim" })
    vim.api.nvim_set_hl(0, "LedgerTabActive", { link = "LedgerBuilderTitle" })
    vim.api.nvim_set_hl(0, "LedgerTabInactive", { link = "Comment" })
    vim.api.nvim_set_hl(0, "LedgerScan", { link = "LedgerBuilderDim" })
  end
end

-- Pulse highlight name for a given tick (heartbeat 0→1→2→1→0…).
function M.pulse(tick)
  local seq = { 0, 1, 2, 1 }
  return "LedgerPulse" .. seq[(math.floor(tick / 2) % #seq) + 1]
end

return M
