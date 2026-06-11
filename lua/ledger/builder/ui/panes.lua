-- ledger.builder.ui.panes
--
-- Pure-ish renderers: each returns a list of volt lines (a line is a list of
-- { text, hlgroup } segments). The controller (builder.init) owns state and
-- composes these into volt sections.

local M = {}

local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- glyph + hl for a step/proc state. `running` animates with `tick`.
local function glyph(state, tick)
  if state == "running" then
    return SPIN[(tick % #SPIN) + 1], "LedgerStateRunning"
  elseif state == "done" then
    return "✓", "LedgerStateDone"
  elseif state == "stale" then
    return "~", "LedgerStateStale"
  elseif state == "failed" then
    return "✗", "LedgerStateFailed"
  end
  return "○", "LedgerStatePending"
end

M.spin = SPIN

-- Header: title, platform toggle, repo/profile.
function M.header(st)
  local function tog(p, label)
    local on = st.platform == p
    return { (on and "● " or "○ ") .. label, on and "LedgerBuilderOn" or "LedgerBuilderOff" }
  end
  local repo = st.root and ("repo: " .. vim.fn.fnamemodify(st.root, ":t")) or "no ledger-live repo"
  return {
    { { "  Ledger Builder", "LedgerBuilderTitle" } },
    {
      { "  " },
      tog("desktop", "Desktop"),
      { "   " },
      tog("mobile", "Mobile"),
      { "      " },
      { repo, "LedgerBuilderDim" },
      { st.platform == "mobile" and ("   " .. st.config) or "", "LedgerBuilderDim" },
    },
    {},
  }
end

-- Pipeline column lines (includes its own title row).
function M.pipeline(st)
  local lines = { { { "PIPELINE", "LedgerBuilderDim" } } }
  for i, step in ipairs(st.steps or {}) do
    local state = st.statuses and st.statuses[step.id] or "pending"
    local g, hl = glyph(state, st.tick or 0)
    local row = {
      { " " },
      { tostring(i) .. " ", "LedgerBuilderDim" },
      { g, hl },
      { " " .. step.label },
    }
    if state == "stale" then
      row[#row + 1] = { "  stale", "LedgerStateStale" }
    elseif state == "running" then
      row[#row + 1] = { "  running", "LedgerStateRunning" }
    end
    lines[#lines + 1] = row
  end
  lines[#lines + 1] = {}
  lines[#lines + 1] = {
    { "  " },
    { "B", "LedgerBuilderKey" },
    { "uild  " },
    { "R", "LedgerBuilderKey" },
    { "un  " },
    { "1-9", "LedgerBuilderKey" },
    { " step", "LedgerBuilderDim" },
  }
  return lines
end

-- Processes column lines.
function M.processes(st)
  local lines = { { { "PROCESSES", "LedgerBuilderDim" } } }
  for _, p in ipairs(st.procs or {}) do
    local g = p.alive and "●" or "○"
    local hl = p.alive and "LedgerStateDone" or "LedgerStatePending"
    local row = { { " " }, { g, hl }, { " " .. p.label } }
    if p.port then
      row[#row + 1] = { "  :" .. p.port, "LedgerBuilderDim" }
    end
    if p.count and p.count > 0 then
      row[#row + 1] = { "  " .. p.count .. " ctr", "LedgerBuilderDim" }
    end
    if not p.alive then
      row[#row + 1] = { "  down", "LedgerBuilderDim" }
    end
    lines[#lines + 1] = row
  end
  lines[#lines + 1] = {}
  lines[#lines + 1] = {
    { "  " },
    { "x", "LedgerBuilderKey" },
    { " kill  " },
    { "s", "LedgerBuilderKey" },
    { " start", "LedgerBuilderDim" },
  }
  return lines
end

-- Footer hints.
function M.footer(st)
  return {
    {},
    {
      { "  " },
      { "D", "LedgerBuilderKey" },
      { "/" },
      { "M", "LedgerBuilderKey" },
      { " platform   " },
      { "R", "LedgerBuilderKey" },
      { " refresh   " },
      { "q", "LedgerBuilderKey" },
      { " close", "LedgerBuilderDim" },
    },
  }
end

return M
