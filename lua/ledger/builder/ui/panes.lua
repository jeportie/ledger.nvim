-- ledger.builder.ui.panes
--
-- Renderers returning volt lines (a line = list of { text, hl, action? }
-- segments; a 3rd element makes the segment mouse-clickable). The controller
-- (builder.init) owns state + supplies on_* callbacks and boxes the section
-- content into the two cycling panes. No inline shortcut hints — shortcuts live
-- in the `?` cheatsheet only.

local M = {}

local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
M.spin = SPIN

local function glyph(s, tick, hlmod)
  if s == "running" then
    return SPIN[(tick % #SPIN) + 1], hlmod and hlmod(tick) or "LedgerStateRunning"
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

-- Titled bordered box around `content`, fixed inner width.
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

-- Header: clickable Desktop/Mobile tabs (+ iOS/Android subtabs on mobile),
-- repo name, and a clickable device/env chip. No window title (the border has
-- it) and no shortcut hints (those live under `?`).
function M.header(st)
  local function tab(label, active, cb)
    local seg = { " " .. label .. " ", active and "LedgerTabActive" or "LedgerTabInactive" }
    if cb then
      seg[3] = cb
    end
    return seg
  end

  local tabs_line = {
    { "  " },
    tab("Desktop", st.platform == "desktop", st.on_platform and function()
      st.on_platform("desktop")
    end),
    { " " },
    tab("Mobile", st.platform == "mobile", st.on_platform and function()
      st.on_platform("mobile")
    end),
  }

  local lines = { tabs_line }

  if st.platform == "mobile" then
    lines[#lines + 1] = {
      { "    " },
      tab("iOS", st.platform_flag == "ios", st.on_subplatform and function()
        st.on_subplatform("ios")
      end),
      { " " },
      tab("Android", st.platform_flag == "android", st.on_subplatform and function()
        st.on_subplatform("android")
      end),
    }
  end

  local repo = st.root and vim.fn.fnamemodify(st.root, ":t") or "no ledger-live repo"
  local meta = {
    { "  " },
    { "󰉋 " .. repo, "LedgerBuilderDim" },
    { "    " },
    { "device: ", "LedgerBuilderDim" },
    {
      st.device or "nanoSP",
      "LedgerBuilderKey",
      st.on_device and function()
        st.on_device()
      end or nil,
    },
  }
  if st.platform == "mobile" then
    meta[#meta + 1] = { "   env: ", "LedgerBuilderDim" }
    meta[#meta + 1] = {
      st.config,
      "LedgerBuilderKey",
      st.on_env and function()
        st.on_env()
      end or nil,
    }
  end
  lines[#lines + 1] = meta
  lines[#lines + 1] = {}
  return lines
end

-- ── ring sections (content only; controller boxes them) ─────────────────────

function M.pipeline_content(st)
  local tasks = require("ledger.tasks")
  local hl = require("ledger.builder.ui.hl")
  local lines = {}
  for i, step in ipairs(st.steps or {}) do
    local state = (st.statuses or {})[step.id] or "pending"
    local g, ghl = glyph(state, st.tick or 0, state == "running" and hl.pulse or nil)
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
      { g, ghl },
      label_seg,
    }
    if state == "stale" then
      row[#row + 1] = { "  stale", "LedgerStateStale" }
    elseif state == "running" then
      row[#row + 1] = { "  …", ghl }
    else
      local res = step.template and tasks.last_result(step.template) or nil
      if res then
        row[#row + 1] =
          { "  " .. (fmt_dur(res.duration) or ""), res.code == 0 and "LedgerStateDone" or "LedgerStateFailed" }
      end
    end
    lines[#lines + 1] = row
  end
  return lines
end

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
  return lines
end

function M.logs_content(st, height)
  local tasks = require("ledger.tasks")
  local id
  if st.focus and st.focus.col == "pipeline" then
    local step = (st.steps or {})[st.focus.idx]
    id = step and step.template or nil
  end
  id = id or tasks.last_started
  local tail = id and tasks.log_tail(id, height or 12) or {}
  if #tail == 0 then
    return { { { "(no output yet — run a step)", "LedgerBuilderDim" } } }
  end
  local lines = {}
  for _, l in ipairs(tail) do
    local txt = l:gsub("\t", "  ")
    if #txt > 50 then
      txt = txt:sub(1, 49) .. "…"
    end
    local hl = "LedgerBuilderDim"
    if txt:match("[Ee]rror") or txt:match("✗") then
      hl = "LedgerStateFailed"
    elseif txt:match("✓") or txt:match("[Dd]one") then
      hl = "LedgerStateDone"
    end
    lines[#lines + 1] = { { txt, hl } }
  end
  return lines
end

-- Stats: HISTORY table + BUILD-TIME bar graph + PASS-RATE bar.
function M.stats_content(st, inner_w)
  local history = require("ledger.builder.history")
  local ui = require("volt.ui")
  local lines = {}

  -- HISTORY (last 8, newest last)
  local recent = history.recent(8)
  local tb = { { "time", "task", "dur", "ok" } }
  for _, e in ipairs(recent) do
    tb[#tb + 1] = {
      os.date("%H:%M", e.time),
      (e.label or "?"):gsub("^%S+%s*·%s*", ""),
      fmt_dur(e.duration) or "-",
      e.code == 0 and "✓" or "✗",
    }
  end
  if #recent == 0 then
    tb[#tb + 1] = { "—", "no runs yet", "—", "—" }
  end
  local tbl = ui.table(tb, "fit", "LedgerBuilderTitle", { "  History" })
  for _, l in ipairs(tbl) do
    lines[#lines + 1] = l
  end
  lines[#lines + 1] = {}

  -- BUILD TIME bar graph (recent build durations, normalised to 0-100)
  local durs = history.build_durations(12)
  if #durs > 0 then
    local maxd = 1
    for _, d in ipairs(durs) do
      maxd = math.max(maxd, d)
    end
    local norm = {}
    for _, d in ipairs(durs) do
      norm[#norm + 1] = math.floor((d / maxd) * 100)
    end
    local bars = ui.graphs.bar({
      val = norm,
      footer_label = { "  build time (last " .. #durs .. ")" },
      format_labels = function(x)
        return tostring(math.floor((x / 100) * maxd)) .. "s"
      end,
      baropts = {
        w = 2,
        gap = 1,
        format_hl = function(x)
          if x > 80 then
            return "LedgerStateFailed"
          elseif x > 50 then
            return "LedgerStateStale"
          end
          return "LedgerStateDone"
        end,
      },
      w = inner_w,
    })
    for _, l in ipairs(bars) do
      lines[#lines + 1] = l
    end
  else
    lines[#lines + 1] = { { "  build time: no builds yet", "LedgerBuilderDim" } }
  end
  lines[#lines + 1] = {}

  -- PASS RATE bar
  local rate, n = history.pass_rate(50)
  if rate then
    local bar = ui.progressbar({
      w = math.max(10, inner_w - 18),
      val = rate,
      icon = { on = "█", off = "░" },
      hl = { on = rate >= 80 and "LedgerStateDone" or "LedgerStateStale", off = "LedgerBuilderDim" },
    })
    table.insert(bar, 1, { "  pass " })
    bar[#bar + 1] = { "  " .. rate .. "%  (" .. n .. ")", "LedgerBuilderDim" }
    lines[#lines + 1] = bar
  else
    lines[#lines + 1] = { { "  pass rate: no test runs yet", "LedgerBuilderDim" } }
  end

  return lines
end

-- Wrong-folder banner (not inside a LedgerHQ-ledger-live checkout).
function M.wrong_folder_content()
  return {
    {},
    { { "  ⚠ not inside a LedgerHQ-ledger-live checkout", "LedgerStateFailed" } },
    {},
    { { "  Builder actions are disabled.", "LedgerBuilderDim" } },
    { { "  cd into the monorepo, or set ", "LedgerBuilderDim" }, { "monorepo_root", "LedgerBuilderKey" } },
    { { "  in require('ledger').setup{}.", "LedgerBuilderDim" } },
  }
end

-- Cheatsheet (the `?` overlay): every key, what it does, the command/purpose.
function M.cheatsheet()
  local function row(key, desc, detail)
    return {
      { "  " },
      { key, "LedgerBuilderKey" },
      { string.rep(" ", math.max(1, 12 - #key)) },
      { desc, "Normal" },
      { detail and ("   " .. detail) or "", "LedgerBuilderDim" },
    }
  end
  return {
    { { "  Tabs / panes", "LedgerBuilderTitle" } },
    row("D / M", "desktop / mobile platform"),
    row("i / a", "iOS / Android subtab (mobile)"),
    row("Ctrl-t", "cycle the visible panes", "Pipeline▸Processes▸Logs▸Stats"),
    {},
    { { "  Navigation", "LedgerBuilderTitle" } },
    row("h / l / ←→", "switch focus column"),
    row("j k ↑↓ ⇥", "move within a column"),
    row("mouse", "click any item / tab / button"),
    {},
    { { "  Actions", "LedgerBuilderTitle" } },
    row("⏎", "run focused step / toggle process", "→ background pnpm task"),
    row("B", "build", "→ build:testing / detox build"),
    row("x / s", "kill / start focused process"),
    row("R", "refresh staleness + liveness"),
    row("e", "device / env dropdown"),
    {},
    { { "  View", "LedgerBuilderTitle" } },
    row("?", "toggle this help"),
    row("q / Esc", "close"),
  }
end

return M
