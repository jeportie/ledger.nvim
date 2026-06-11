-- ledger.builder.ui.panes
--
-- Pure-ish renderers: each returns a list of volt lines (a line is a list of
-- { text, hlgroup } segments). The controller (builder.init) owns state and
-- composes these into volt sections. Focus is 2D: state.focus = {col, idx}.

local M = {}

local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

M.spin = SPIN

local function glyph(s, tick)
  if s == "running" then
    return SPIN[(tick % #SPIN) + 1], "LedgerStateRunning"
  elseif s == "done" then
    return "✓", "LedgerStateDone"
  elseif s == "stale" then
    return "~", "LedgerStateStale"
  elseif s == "failed" then
    return "✗", "LedgerStateFailed"
  end
  return "○", "LedgerStatePending"
end

local function fmt_dur(secs)
  if not secs then
    return nil
  end
  if secs >= 60 then
    return string.format("%dm%02d", math.floor(secs / 60), secs % 60)
  end
  return secs .. "s"
end

local function focus_gutter(focused)
  if focused then
    return { "▶ ", "LedgerBuilderKey" }
  end
  return { "  ", "LedgerBuilderDim" }
end

-- Titled bordered box around `content` lines, fixed inner width `inner_w`.
-- (volt.ui.border has no title support, so we build it here.)
function M.box(title, content, inner_w, hl)
  hl = hl or "LedgerBuilderDim"
  local ui = require("volt.ui")
  local tlen = vim.fn.strchars(title)
  local fill = math.max(0, inner_w - tlen)
  local out = {
    { { "┌ ", hl }, { title, "LedgerBuilderTitle" }, { " " .. string.rep("─", fill) .. "┐", hl } },
  }
  for _, line in ipairs(content) do
    local w = ui.line_w(line)
    local pad = math.max(0, inner_w - w)
    local row = { { "│ ", hl } }
    for _, seg in ipairs(line) do
      row[#row + 1] = seg
    end
    row[#row + 1] = { string.rep(" ", pad) .. " │", hl }
    out[#out + 1] = row
  end
  out[#out + 1] = { { "└" .. string.rep("─", inner_w + 2) .. "┘", hl } }
  return out
end

-- Header: title + platform toggle + repo/config.
function M.header(st)
  local function tog(p, label)
    local on = st.platform == p
    return { (on and "● " or "○ ") .. label, on and "LedgerBuilderOn" or "LedgerBuilderOff" }
  end
  local repo = st.root and ("repo: " .. vim.fn.fnamemodify(st.root, ":t")) or "no ledger-live repo (set monorepo_root)"
  local env = st.platform == "mobile" and ("  " .. st.config) or ""
  return {
    { { "  Ledger Builder", "LedgerBuilderTitle" } },
    {
      { "  " },
      tog("desktop", "Desktop"),
      { "   " },
      tog("mobile", "Mobile"),
      { "      " },
      { repo, "LedgerBuilderDim" },
      { env, "LedgerBuilderKey" },
    },
    {},
  }
end

-- Pipeline column content (step rows + action hint).
function M.pipeline_content(st)
  local tasks = require("ledger.tasks")
  local lines = {}
  for i, step in ipairs(st.steps or {}) do
    local state = (st.statuses or {})[step.id] or "pending"
    local g, hl = glyph(state, st.tick or 0)
    local focused = st.focus and st.focus.col == "pipeline" and st.focus.idx == i
    local row = {
      focus_gutter(focused),
      { tostring(i) .. " ", "LedgerBuilderDim" },
      { g, hl },
      { " " .. step.label },
    }
    if state == "stale" then
      row[#row + 1] = { "  stale", "LedgerStateStale" }
    elseif state == "running" then
      row[#row + 1] = { "  …", "LedgerStateRunning" }
    else
      local res = step.template and tasks.last_result(step.template) or nil
      if res then
        local d = fmt_dur(res.duration)
        row[#row + 1] = { "  " .. (d or ""), res.code == 0 and "LedgerStateDone" or "LedgerStateFailed" }
      end
    end
    lines[#lines + 1] = row
  end
  lines[#lines + 1] = {}
  lines[#lines + 1] = {
    { "  " },
    { "⏎", "LedgerBuilderKey" },
    { " run  " },
    { "B", "LedgerBuilderKey" },
    { " build  " },
    { "R", "LedgerBuilderKey" },
    { " refresh" },
  }
  return lines
end

-- Processes column content.
function M.processes_content(st)
  local lines = {}
  for i, p in ipairs(st.procs or {}) do
    local focused = st.focus and st.focus.col == "processes" and st.focus.idx == i
    local row = {
      focus_gutter(focused),
      { p.alive and "●" or "○", p.alive and "LedgerStateDone" or "LedgerStatePending" },
      { " " .. p.label },
    }
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
    { "⏎", "LedgerBuilderKey" },
    { " start/stop  " },
    { "x", "LedgerBuilderKey" },
    { " kill" },
  }
  return lines
end

-- Logs column content: tail of the focused step's task (or last started).
function M.logs_content(st)
  local tasks = require("ledger.tasks")
  local id
  if st.focus and st.focus.col == "pipeline" then
    local step = (st.steps or {})[st.focus.idx]
    id = step and step.template or nil
  end
  id = id or tasks.last_started
  local tail = id and tasks.log_tail(id, 6) or {}
  if #tail == 0 then
    return { { { "  (no output yet — run a step)", "LedgerBuilderDim" } } }
  end
  local lines = {}
  for _, l in ipairs(tail) do
    -- trim to keep within the box; colour error-ish lines
    local txt = l:gsub("\t", "  ")
    if #txt > 40 then
      txt = txt:sub(1, 39) .. "…"
    end
    local hl = txt:match("[Ee]rror") and "LedgerStateFailed" or "LedgerBuilderDim"
    lines[#lines + 1] = { { "  " .. txt, hl } }
  end
  return lines
end

-- Footer: nav + action hints.
function M.footer(st)
  return {
    {},
    {
      { "  " },
      { "hjkl/↹", "LedgerBuilderKey" },
      { " move   " },
      { "D", "LedgerBuilderKey" },
      { "/" },
      { "M", "LedgerBuilderKey" },
      { " platform   " },
      { "R", "LedgerBuilderKey" },
      { " refresh   " },
      { "q", "LedgerBuilderKey" },
      { " close" },
    },
  }
end

return M
