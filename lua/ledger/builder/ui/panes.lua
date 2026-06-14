-- ledger.builder.ui.panes
--
-- Renderers returning volt lines (a line = list of { text, hl, action? }
-- segments; a 3rd element makes the segment mouse-clickable). The controller
-- (builder.init) owns state + supplies on_* callbacks and boxes the section
-- content into the two cycling panes. No inline shortcut hints — shortcuts live
-- in the `?` cheatsheet only.

local M = {}

local function glyph(s, tick, hlmod)
  if s == "running" then
    local cfg = require("ledger.config").get().builder or {}
    local name = (cfg.spinner and cfg.spinner.pipeline) or "dots"
    local frame = require("ledger.builder.ui.spin").frame(name, tick)
    return frame, hlmod and hlmod(tick) or "LedgerStateRunning"
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

-- Titled bordered box around `content`, fixed inner width. `title_hl` colours
-- the title text (defaults to the section-title group; process cards pass a
-- state colour).
function M.box(title, content, inner_w, hl, title_hl)
  hl = hl or "LedgerBuilderDim"
  title_hl = title_hl or "LedgerBuilderTitle"
  local ui = require("volt.ui")
  local tlen = vim.fn.strchars(title)
  local fill = math.max(0, inner_w - tlen)
  local out = {
    { { "┌ ", hl }, { title, title_hl }, { " " .. string.rep("─", fill) .. "┐", hl } },
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

-- Header: a centered title (when borderless), clickable Desktop/Mobile tabs (+
-- iOS/Android subtabs on mobile), repo name, and a clickable device/env chip.
-- Each tab has its own hue. A blank line replaces the subtab row on desktop so
-- the header is always the same height (window doesn't jump when toggling).
function M.header(st)
  local cfg = require("ledger.config").get().builder or {}
  local width = st.full_inner or (st.W and st.W - 4) or 76
  local function tab(label, active, active_hl, cb)
    local seg = { " " .. label .. " ", active and active_hl or "LedgerTabInactive" }
    if cb then
      seg[3] = cb
    end
    return seg
  end

  local lines = { {} } -- top margin (breathing room)

  -- Centered title — only when there's no window border to carry it.
  if not cfg.border then
    local title = "Ledger Builder"
    local pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(title)) / 2))
    lines[#lines + 1] = { { string.rep(" ", pad) .. title, "LedgerTitle" } }
  end

  lines[#lines + 1] = {
    { "  " },
    tab("Desktop", st.platform == "desktop", "LedgerTabDesktop", st.on_platform and function()
      st.on_platform("desktop")
    end),
    { " " },
    tab("Mobile", st.platform == "mobile", "LedgerTabMobile", st.on_platform and function()
      st.on_platform("mobile")
    end),
  }

  if st.platform == "mobile" then
    lines[#lines + 1] = {
      { "    " },
      tab("iOS", st.platform_flag == "ios", "LedgerTabIos", st.on_subplatform and function()
        st.on_subplatform("ios")
      end),
      { " " },
      tab("Android", st.platform_flag == "android", "LedgerTabAndroid", st.on_subplatform and function()
        st.on_subplatform("android")
      end),
    }
  else
    lines[#lines + 1] = {} -- keep desktop the same height as mobile
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
  if st.platform == "desktop" then
    meta[#meta + 1] = { "   PWDEBUG: ", "LedgerBuilderDim" }
    meta[#meta + 1] = {
      st.pwdebug or "0",
      "LedgerBuilderKey",
      st.on_env and function()
        st.on_env()
      end or nil,
    }
  else
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

local STATE_WORD =
  { done = "done", running = "running", stale = "stale", failed = "failed", pending = "pending", ready = "ready" }

-- Distribute `rows` over `target` lines by spreading blank lines after rows
-- (even cumulative rounding) so short content still fills the pane height.
local function distribute(rows, target)
  local n = #rows
  if target <= n then
    return rows
  end
  local slack = target - n
  local out = {}
  for i, r in ipairs(rows) do
    out[#out + 1] = r
    local g = math.floor(slack * i / n) - math.floor(slack * (i - 1) / n)
    for _ = 1, g do
      out[#out + 1] = {}
    end
  end
  return out
end

local function pad_str(s, w)
  local d = vim.fn.strdisplaywidth(s)
  if d >= w then
    return s
  end
  return s .. string.rep(" ", w - d)
end

-- Pipeline: a progress bar on top, then the steps as evenly-distributed rows
-- that fill the pane height. Each step leads with ✶ (▶ when focused) in the
-- Step column; the State column carries the status glyph + word (the running
-- step animates via the configured spinner). No inner border — the pane box is
-- the single frame.
function M.pipeline_content(st, inner_w, height)
  local tasks = require("ledger.tasks")
  local hl = require("ledger.builder.ui.hl")
  local ui = require("volt.ui")
  inner_w = inner_w or 44
  height = height or 14
  local steps = st.steps or {}

  local done = 0
  for _, s in ipairs(steps) do
    if (st.statuses or {})[s.id] == "done" then
      done = done + 1
    end
  end
  local pct = #steps > 0 and math.floor((done / #steps) * 100) or 0
  local bar = ui.progressbar({
    w = math.max(8, inner_w - 12),
    val = pct,
    icon = { on = "┃", off = "┃" },
    hl = { on = "LedgerGreen0", off = "LedgerSeparator" },
  })
  table.insert(bar, 1, { "  " })
  bar[#bar + 1] = { "  " .. done .. "/" .. #steps, "LedgerLabel" }

  local dur_w, state_w = 7, 13
  local step_w = math.max(10, inner_w - state_w - dur_w)

  local step_rows = {}
  for i, step in ipairs(steps) do
    local state = (st.statuses or {})[step.id] or "pending"
    local g, ghl = glyph(state, st.tick or 0, state == "running" and hl.pulse or nil)
    local focused = st.focus and st.focus.col == "pipeline" and st.focus.idx == i
    local bullet = focused and "▶ " or "✶ "
    local bullet_hl = focused and "LedgerBuilderKey" or "LedgerYellow0"
    local opt = step.optional and " ○" or ""
    local label = tostring(i) .. " " .. step.label .. opt
    local dur = "-"
    if step.template then
      local res = tasks.last_result(step.template)
      if res then
        dur = fmt_dur(res.duration) or "-"
      end
    end
    step_rows[#step_rows + 1] = {
      { bullet, bullet_hl },
      { pad_str(label, step_w - 2), "Normal" },
      { g .. " ", ghl },
      { pad_str(STATE_WORD[state] or state, state_w - 2), ghl },
      { dur, "LedgerBuilderDim" },
    }
  end

  local lines = { bar, {} }
  for _, l in ipairs(distribute(step_rows, math.max(#step_rows, height - 2))) do
    lines[#lines + 1] = l
  end
  return lines
end

-- Tiling: cards per row for n processes (cards grow to fill the pane).
-- 1→[1]  2→[2]  3→[2,1]  4→[2,2]  then rows of 2 with a lone last card.
local function tile(n)
  if n <= 1 then
    return { 1 }
  elseif n == 2 then
    return { 2 }
  elseif n == 3 then
    return { 2, 1 }
  elseif n == 4 then
    return { 2, 2 }
  end
  local rows, rem = {}, n
  while rem > 0 do
    if rem == 1 then
      rows[#rows + 1] = 1
      rem = 0
    else
      rows[#rows + 1] = 2
      rem = rem - 2
    end
  end
  return rows
end

-- Processes as a grid of per-process cards that grow to fill the pane (w × h):
-- title = name (state-colored, ▶ when focused), body = status, port/containers,
-- and an activity bar animated with the configured spinner for alive procs.
function M.processes_content(st, inner_w, height)
  local ui = require("volt.ui")
  local spin = require("ledger.builder.ui.spin")
  inner_w = inner_w or 44
  height = height or 12
  local cfg = require("ledger.config").get().builder or {}
  local proc_spinner = (cfg.spinner and cfg.spinner.process) or "aesthetic"
  local procs = st.procs or {}

  if #procs == 0 then
    local out = { { { "  (no processes for this platform)", "LedgerBuilderDim" } } }
    while #out < height do
      out[#out + 1] = {}
    end
    return out
  end

  local function card(i, p, col_inner, card_h)
    local focused = st.focus and st.focus.col == "processes" and st.focus.idx == i
    local state_hl = p.alive and "LedgerStateDone" or "LedgerStatePending"
    local title = (focused and "▶ " or "") .. (p.label or "?")
    local title_hl = focused and "LedgerTitle" or state_hl

    local meta = {}
    if p.port then
      meta[#meta + 1] = ":" .. p.port
    end
    if p.count and p.count > 0 then
      meta[#meta + 1] = p.count .. " ctr"
    end
    local activity
    if p.alive then
      activity = { { spin.frame(proc_spinner, st.tick or 0), "LedgerBlue0" } }
    else
      activity = { { string.rep("▱", 7), "LedgerSeparator" } }
    end

    local body = {
      { { p.alive and "● running" or "○ down", state_hl } },
      { { #meta > 0 and table.concat(meta, "  ") or "—", "LedgerLabel" } },
      {},
      activity,
    }
    local inner_h = math.max(1, card_h - 2)
    while #body < inner_h do
      body[#body + 1] = {}
    end
    while #body > inner_h do
      table.remove(body)
    end
    return M.box(title, body, col_inner, "LedgerSeparator", title_hl)
  end

  local rows = tile(#procs)
  local R = #rows
  local base = math.floor(height / R)
  local extra = height - base * R

  local out, idx = {}, 1
  for r = 1, R do
    local card_h = base + (r <= extra and 1 or 0)
    local ncol = rows[r]
    local col_inner = math.max(12, ncol == 1 and (inner_w - 4) or (math.floor(inner_w / ncol) - 4))
    if ncol == 1 then
      for _, l in ipairs(card(idx, procs[idx], col_inner, card_h)) do
        out[#out + 1] = l
      end
      idx = idx + 1
    else
      local cols = {}
      for _ = 1, ncol do
        cols[#cols + 1] = { lines = card(idx, procs[idx], col_inner, card_h), w = col_inner + 4 }
        idx = idx + 1
      end
      for _, l in ipairs(ui.grid_col(cols)) do
        out[#out + 1] = l
      end
    end
  end
  return out
end

-- Content for the per-process popup. `info` = { label, command, alive, port,
-- count, uptime, log }.
function M.process_popup_content(info)
  local lines = {
    {
      { info.label, "LedgerBuilderTitle" },
      { info.alive and "   ● running" or "   ○ down", info.alive and "LedgerStateDone" or "LedgerBuilderDim" },
    },
    {},
    { { "command  ", "LedgerBuilderDim" }, { info.command or "—" } },
  }
  if info.port then
    lines[#lines + 1] = { { "port     ", "LedgerBuilderDim" }, { ":" .. info.port } }
  end
  if info.count and info.count > 0 then
    lines[#lines + 1] = { { "docker   ", "LedgerBuilderDim" }, { info.count .. " container(s)" } }
  end
  if info.uptime then
    lines[#lines + 1] = { { "uptime   ", "LedgerBuilderDim" }, { info.uptime } }
  end
  lines[#lines + 1] = {}
  lines[#lines + 1] = {
    {
      "── log ──────────────────────────────",
      "LedgerBuilderDim",
    },
  }
  local log = info.log or {}
  if #log == 0 then
    lines[#lines + 1] = { { "(no captured output)", "LedgerBuilderDim" } }
  else
    for _, l in ipairs(log) do
      local txt = l:gsub("\t", "  ")
      if #txt > 56 then
        txt = txt:sub(1, 55) .. "…"
      end
      local hl = "LedgerBuilderDim"
      if txt:match("[Ee]rror") or txt:match("✗") then
        hl = "LedgerStateFailed"
      elseif txt:match("✓") then
        hl = "LedgerStateDone"
      end
      lines[#lines + 1] = { { txt, hl } }
    end
  end
  lines[#lines + 1] = {}
  lines[#lines + 1] = {
    { "  " },
    { "s", "LedgerBuilderKey" },
    { " start   " },
    { "x", "LedgerBuilderKey" },
    { " kill   " },
    { "R", "LedgerBuilderKey" },
    { " restart   " },
    { "q", "LedgerBuilderKey" },
    { " close" },
  }
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

-- Stats, filtered to the active target (desktop / ios / android), split into
-- three column renderers the controller boxes side by side: History ·
-- Build-time · Pass-rate. Each returns inner content (no own title/border).
local function stats_target(st)
  return st.platform == "desktop" and "desktop" or st.platform_flag
end

function M.stats_history(st, inner_w)
  local history = require("ledger.builder.history")
  local recent = history.recent(8, nil, stats_target(st))
  if #recent == 0 then
    return { { { "no runs yet", "LedgerBuilderDim" } } }
  end
  local maxlabel = math.max(4, (inner_w or 24) - 11)
  local lines = {}
  for _, e in ipairs(recent) do
    local ok = e.code == 0
    local label = (e.label or "?"):gsub("^%S+%s*·%s*", "")
    if vim.fn.strdisplaywidth(label) > maxlabel then
      label = vim.fn.strcharpart(label, 0, maxlabel - 1) .. "…"
    end
    lines[#lines + 1] = {
      { os.date("%H:%M ", e.time), "LedgerBuilderDim" },
      { ok and "✓ " or "✗ ", ok and "LedgerStateDone" or "LedgerStateFailed" },
      { label, "Normal" },
    }
  end
  return lines
end

function M.stats_buildtime(st, inner_w)
  local history = require("ledger.builder.history")
  local ui = require("volt.ui")
  local durs = history.build_durations(12, stats_target(st))
  if #durs == 0 then
    return { { { "no builds yet", "LedgerBuilderDim" } } }
  end
  local maxd = 1
  for _, d in ipairs(durs) do
    maxd = math.max(maxd, d)
  end
  local norm = {}
  for _, d in ipairs(durs) do
    norm[#norm + 1] = math.floor((d / maxd) * 100)
  end
  return ui.graphs.bar({
    val = norm,
    footer_label = { "last " .. #durs },
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
end

function M.stats_passrate(st, inner_w)
  local history = require("ledger.builder.history")
  local ui = require("volt.ui")
  local rate, n = history.pass_rate(50, stats_target(st))
  if not rate then
    return { { { "no test runs yet", "LedgerBuilderDim" } } }
  end
  local bar = ui.progressbar({
    w = math.max(8, (inner_w or 24) - 10),
    val = rate,
    icon = { on = "█", off = "░" },
    hl = { on = rate >= 80 and "LedgerStateDone" or "LedgerStateStale", off = "LedgerBuilderDim" },
  })
  return { bar, {}, { { rate .. "%  (" .. n .. " runs)", "LedgerBuilderDim" } } }
end

-- Combined stats (vertical fallback / single column).
function M.stats_content(st, inner_w)
  local lines = { { { "  target: ", "LedgerBuilderDim" }, { stats_target(st), "LedgerBuilderTitle" } }, {} }
  local function append(title, fn)
    lines[#lines + 1] = { { "  " .. title, "LedgerBuilderTitle" } }
    for _, l in ipairs(fn(st, inner_w)) do
      lines[#lines + 1] = l
    end
    lines[#lines + 1] = {}
  end
  append("History", M.stats_history)
  append("Build time", M.stats_buildtime)
  append("Pass rate", M.stats_passrate)
  return lines
end

-- Bottom-row indicator: which view (logs / stats) is showing; < / > switches.
function M.bottom_indicator(st)
  local logs_on = st.bottom ~= "stats"
  return {
    { "  " },
    { " logs ", logs_on and "LedgerTabActive" or "LedgerTabInactive" },
    { " " },
    { " stats ", (not logs_on) and "LedgerTabActive" or "LedgerTabInactive" },
    { "     < / > to switch", "LedgerBuilderDim" },
  }
end

-- Wrong-folder banner (cwd is not inside a LedgerHQ-ledger-live checkout).
function M.wrong_folder_content(cwd)
  return {
    {},
    { { "  ⚠ not inside a LedgerHQ-ledger-live repo", "LedgerStateFailed" } },
    {},
    { { "  cwd: ", "LedgerBuilderDim" }, { cwd or "?", "LedgerStateFailed" } },
    {},
    { { "  Builder actions are disabled.", "LedgerBuilderDim" } },
    { { "  cd into a ledger-live checkout and reopen.", "LedgerBuilderDim" } },
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
    { { "  Tabs / layout", "LedgerBuilderTitle" } },
    row("Tab", "switch Desktop / Mobile"),
    row("D / M", "desktop / mobile platform"),
    row("i / a", "iOS / Android subtab (mobile)"),
    row("< / >", "bottom view", "Logs ▸ Stats (Pipeline+Processes always shown)"),
    {},
    { { "  Navigation", "LedgerBuilderTitle" } },
    row("h / l / ←→", "focus Pipeline / Processes"),
    row("j k ↑↓", "move within a column"),
    row("mouse", "click any item / tab / button"),
    {},
    { { "  Actions", "LedgerBuilderTitle" } },
    row("⏎", "run focused step / toggle process", "→ background pnpm task"),
    row("r", "run tests", "All · spec file · by name · by ticket"),
    row("B", "build", "→ build:testing / detox build"),
    row("x / s", "kill / start focused process"),
    row("e", "env dropdown", "desktop: PWDEBUG · mobile: detox config"),
    row("d", "Speculos device dropdown"),
    row("F", "fix / maintenance", "reinstall · iOS pods · clean"),
    row("R", "refresh staleness + liveness"),
    {},
    { { "  View", "LedgerBuilderTitle" } },
    row("?", "toggle this help"),
    row("q / Esc", "close"),
  }
end

return M
