-- ledger.builder.ui.panes
--
-- Pure-ish renderers: each returns a list of volt lines (a line is a list of
-- { text, hlgroup, action? } segments — a 3rd element makes the segment
-- mouse-clickable / <CR>-activatable via volt). The controller (builder.init)
-- owns state and supplies on_* callbacks. Focus is 2D: state.focus = {col, idx}.

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

-- Header: title + platform toggle + repo/branch + mock/device.
function M.header(st)
  local function tog(p, label)
    local on = st.platform == p
    local seg = { (on and "● " or "○ ") .. label, on and "LedgerBuilderOn" or "LedgerBuilderOff" }
    if st.on_platform then
      seg[3] = function()
        st.on_platform(p)
      end
    end
    return seg
  end
  local repo = st.root and ("repo: " .. vim.fn.fnamemodify(st.root, ":t")) or "no ledger-live repo (set monorepo_root)"
  local branch = st.branch and ("  @" .. st.branch) or ""
  local meta = {
    { "  " },
    { "MOCK=" .. (st.mock or "0"), "LedgerBuilderDim" },
    { "   " },
    { st.device or "nanoSP", "LedgerBuilderDim" },
  }
  if st.platform == "mobile" then
    meta[#meta + 1] = { "   " }
    meta[#meta + 1] = { st.config, "LedgerBuilderKey" }
  end
  return {
    { { "  Ledger Builder", "LedgerBuilderTitle" } },
    {
      { "  " },
      tog("desktop", "Desktop"),
      { "   " },
      tog("mobile", "Mobile"),
      { "      " },
      { repo, "LedgerBuilderDim" },
      { branch, "LedgerBuilderDim" },
    },
    meta,
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
    local label_seg = { " " .. step.label, focused and "LedgerBuilderTitle" or "Normal" }
    if st.on_step then
      label_seg[3] = function()
        st.on_step(i)
      end
    end
    local row = {
      focus_gutter(focused),
      { tostring(i) .. " ", "LedgerBuilderDim" },
      { g, hl },
      label_seg,
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
  local function btn(text, hl, cb)
    return cb and { text, hl, cb } or { text, hl }
  end
  lines[#lines + 1] = {
    { "  " },
    btn("⏎", "LedgerBuilderKey", st.on_run),
    { " run  " },
    btn("B", "LedgerBuilderKey", st.on_build),
    { " build  " },
    btn("R", "LedgerBuilderKey", st.on_refresh),
    { " refresh" },
  }
  return lines
end

-- Processes column content.
function M.processes_content(st)
  local lines = {}
  for i, p in ipairs(st.procs or {}) do
    local focused = st.focus and st.focus.col == "processes" and st.focus.idx == i
    local dot = { p.alive and "●" or "○", p.alive and "LedgerStateDone" or "LedgerStatePending" }
    local label_seg = { " " .. p.label, focused and "LedgerBuilderTitle" or "Normal" }
    if st.on_proc then
      label_seg[3] = function()
        st.on_proc(i)
      end
      dot[3] = label_seg[3]
    end
    local row = { focus_gutter(focused), dot, label_seg }
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
  local function btn(text, hl, cb)
    return cb and { text, hl, cb } or { text, hl }
  end
  lines[#lines + 1] = {
    { "  " },
    btn("⏎", "LedgerBuilderKey", st.on_proc_toggle),
    { " start/stop  " },
    btn("x", "LedgerBuilderKey", st.on_kill),
    { " kill" },
  }
  return lines
end

-- Logs column content: tail of the focused step's task (or last started).
-- `height` controls how many lines are shown.
function M.logs_content(st, height)
  local tasks = require("ledger.tasks")
  local id
  if st.focus and st.focus.col == "pipeline" then
    local step = (st.steps or {})[st.focus.idx]
    id = step and step.template or nil
  end
  id = id or tasks.last_started
  local tail = id and tasks.log_tail(id, height or 6) or {}
  if #tail == 0 then
    return { { { "  (no output yet — run a step)", "LedgerBuilderDim" } } }
  end
  local lines = {}
  for _, l in ipairs(tail) do
    local txt = l:gsub("\t", "  ")
    if #txt > 40 then
      txt = txt:sub(1, 39) .. "…"
    end
    local hl = "LedgerBuilderDim"
    if txt:match("[Ee]rror") or txt:match("✗") then
      hl = "LedgerStateFailed"
    elseif txt:match("✓") or txt:match("[Dd]one") then
      hl = "LedgerStateDone"
    end
    lines[#lines + 1] = { { "  " .. txt, hl } }
  end
  return lines
end

-- Cheatsheet content: every action, the key, what it does, and the command /
-- purpose. Rendered (boxed) by the controller when `?` is toggled.
function M.cheatsheet()
  local function row(key, desc, detail)
    return {
      { "  " },
      { key, "LedgerBuilderKey" },
      { string.rep(" ", math.max(1, 10 - #key)) },
      { desc },
      { detail and ("   " .. detail) or "", "LedgerBuilderDim" },
    }
  end
  return {
    { { "  Navigation", "LedgerBuilderTitle" } },
    row("h / ←", "focus the pipeline column"),
    row("l / →", "focus the processes column"),
    row("j k ↑↓ ⇥", "move within a column"),
    row("mouse", "click any step / process / button"),
    {},
    { { "  Pipeline", "LedgerBuilderTitle" } },
    row("⏎", "run the focused step", "→ pnpm task (background)"),
    row("B", "build", "→ desktop build:testing / detox build"),
    row("R", "refresh", "recompute staleness + process liveness"),
    {},
    { { "  Processes", "LedgerBuilderTitle" } },
    row("⏎", "start / stop the focused process"),
    row("x", "kill the focused process", "lsof kill / docker rm -f"),
    row("s", "start the focused process", "Metro / dev:lld templates"),
    {},
    { { "  View", "LedgerBuilderTitle" } },
    row("D / M", "switch desktop / mobile platform"),
    row("+ / -", "grow / shrink the LOGS pane"),
    row("?", "toggle this help"),
    row("q / Esc", "close the dashboard"),
  }
end

-- Footer: nav + action hints.
function M.footer(st)
  if st.help then
    return {
      {},
      { { "  " }, { "?", "LedgerBuilderKey" }, { " close help   " }, { "q", "LedgerBuilderKey" }, { " close" } },
    }
  end
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
      { "+/-", "LedgerBuilderKey" },
      { " logs   " },
      { "?", "LedgerBuilderKey" },
      { " help   " },
      { "q", "LedgerBuilderKey" },
      { " close" },
    },
  }
end

return M
