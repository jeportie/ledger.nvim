-- ledger.builder.ui.panes
--
-- Renderers returning volt lines (a line = list of { text, hl, action? }
-- segments; a 3rd element makes the segment mouse-clickable). The controller
-- (builder.init) owns state + supplies on_* callbacks and boxes the section
-- content into the two cycling panes. No inline shortcut hints — shortcuts live
-- in the `?` cheatsheet only.

local M = {}

local function glyph(s, tick, hlmod)
  if s == "in_progress" or s == "running" then
    local cfg = require("ledger.config").get().builder or {}
    local name = (cfg.spinner and cfg.spinner.pipeline) or "dots"
    local frame = require("ledger.builder.ui.spin").frame(name, tick)
    return frame, hlmod and hlmod(tick) or "LedgerStateRunning"
  elseif s == "done" then
    return "✓", "LedgerStateDone"
  elseif s == "needs_update" or s == "stale" then
    return "~", "LedgerStateStale"
  elseif s == "failed" then
    return "✗", "LedgerStateFailed"
  end
  return "○", "LedgerStatePending" -- missing / pending
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

  -- Centered title as a filled bar — only when there's no window border to
  -- carry it. Every segment uses the LedgerTitleBar bg so it reads as a rectangle.
  if not cfg.border then
    local title = "Ledger Builder"
    local tw = vim.fn.strdisplaywidth(title)
    local lpad = math.max(0, math.floor((width - tw) / 2))
    local rpad = math.max(0, width - tw - lpad)
    lines[#lines + 1] = {
      { string.rep(" ", lpad), "LedgerTitleBar" },
      { title, "LedgerTitleBar" },
      { string.rep(" ", rpad), "LedgerTitleBar" },
    }
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
    local on_env = st.on_env and function()
      st.on_env()
    end or nil
    meta[#meta + 1] = { "   build: ", "LedgerBuilderDim" }
    meta[#meta + 1] = { st.desktop_build or "testing", "LedgerBuilderKey", on_env }
    meta[#meta + 1] = { "   MOCK: ", "LedgerBuilderDim" }
    meta[#meta + 1] = { st.mock or "0", "LedgerBuilderKey", on_env }
    meta[#meta + 1] = { "   PWDEBUG: ", "LedgerBuilderDim" }
    meta[#meta + 1] = {
      st.pwdebug or "0",
      "LedgerBuilderKey",
      st.on_pwdebug and function()
        st.on_pwdebug()
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
  -- Nx watcher chip (both platforms)
  meta[#meta + 1] = { "   watch: ", "LedgerBuilderDim" }
  meta[#meta + 1] = {
    st.watching and "on" or "off",
    st.watching and "LedgerStateDone" or "LedgerBuilderDim",
    st.on_watch and function()
      st.on_watch()
    end or nil,
  }
  lines[#lines + 1] = meta
  lines[#lines + 1] = {}
  return lines
end

-- ── ring sections (content only; controller boxes them) ─────────────────────

local STATE_WORD = {
  done = "done",
  in_progress = "in progress",
  needs_update = "needs update",
  missing = "missing",
  -- legacy aliases (in case any old status leaks through)
  running = "in progress",
  stale = "needs update",
  failed = "missing",
  pending = "missing",
  ready = "missing",
}

-- Colour-coded target-state word for the pipeline header line.
local TARGET_WORD = {
  ready = { "READY", "LedgerStateDone" },
  in_progress = { "IN PROGRESS", "LedgerStateRunning" },
  not_ready = { "NOT READY", "LedgerStateStale" },
}

-- A loading-bar sweep for the process activity bars (0→100 by tick when alive).
local function sweep_pct(alive, tick)
  if not alive then
    return 0
  end
  return (tick * 7) % 100
end

-- Pipeline: a leading blank, a progress bar + count, then a bordered table
-- (Step · State · Dur). The Step cell leads with ✶ (▶ when focused; the running
-- step's star animates via the configured spinner); the State cell carries the
-- status glyph + word.
-- Left-pad to display width `w` (truncate if longer) — used to left-align cells.
local function lpad(s, w)
  local d = vim.fn.strdisplaywidth(s)
  if d >= w then
    return vim.fn.strcharpart(s, 0, w)
  end
  return s .. string.rep(" ", w - d)
end

-- Is the Playwright browser installed (once per machine)?
local function pw_installed()
  local cfg = require("ledger.config").get().builder or {}
  local p = vim.fn.expand(cfg.pw_browsers_path or "~/.cache/ms-playwright")
  return (vim.uv or vim.loop).fs_stat(p) ~= nil
end

-- The "Run tests" button below the pipeline table; gated on the target being
-- READY, and on desktop the Playwright browser being installed.
function M.runtests_button(st, tstate)
  local cb = st.on_runtests and function()
    st.on_runtests()
  end or nil
  if tstate ~= "ready" then
    return { { "  ▶ Run tests", "LedgerStatePending", cb }, { "   (build the target first)", "LedgerBuilderDim" } }
  end
  if st.platform == "desktop" and not pw_installed() then
    return {
      { "  ⚠ Install Playwright browser", "LedgerStateStale", cb },
      { "   (one-time, per machine)", "LedgerBuilderDim" },
    }
  end
  return { { "  ▶ Run tests", "LedgerStateDone", cb }, { "   r", "LedgerBuilderKey" } }
end

function M.pipeline_content(st, inner_w)
  local hl = require("ledger.builder.ui.hl")
  local ui = require("volt.ui")
  local spin = require("ledger.builder.ui.spin")
  inner_w = inner_w or 44
  local cfg = require("ledger.config").get().builder or {}
  local step_spinner = (cfg.spinner and cfg.spinner.step) or "star"
  local steps = st.steps or {}
  local durs = require("ledger.builder.store").get(st.root) -- persisted per-template durations

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

  -- A hand-rolled table with FIXED column widths (identical across targets) and
  -- LEFT-aligned Step/State cells. (voltui.table centers + auto-sizes per content,
  -- which varied by target — so we lay it out ourselves; the pane box is the frame.)
  local dur_w, state_w = 6, 15
  local step_w = math.max(10, inner_w - state_w - dur_w - 2) -- 2 single-space gutters

  local function header()
    return {
      { " " .. lpad("Step", step_w - 1), "LedgerBuilderTitle" },
      { " " },
      { lpad("State", state_w), "LedgerBuilderTitle" },
      { " " },
      { lpad("Dur", dur_w), "LedgerBuilderTitle" },
    }
  end
  local function rule()
    return { { string.rep("─", step_w + state_w + dur_w + 2), "LedgerSeparator" } }
  end

  local tbl = { header(), rule() }
  for i, step in ipairs(steps) do
    local state = (st.statuses or {})[step.id] or "missing"
    local g, ghl = glyph(state, st.tick or 0, state == "in_progress" and hl.pulse or nil)
    local focused = st.focus and st.focus.col == "pipeline" and st.focus.idx == i
    local bullet, bhl
    if focused then
      bullet, bhl = "▶", "LedgerBuilderKey"
    elseif state == "in_progress" then
      bullet, bhl = spin.frame(step_spinner, st.tick or 0), "LedgerYellow0"
    else
      bullet, bhl = "✶", "LedgerYellow0"
    end
    local bw = vim.fn.strdisplaywidth(bullet)
    local gw = vim.fn.strdisplaywidth(g)
    local d = durs[step.template]
    local dur = d and fmt_dur(d.duration) or "-"
    tbl[#tbl + 1] = {
      { bullet .. " ", bhl }, -- Step column (left-aligned)
      { lpad(tostring(i) .. " " .. step.label, step_w - bw - 1), "Normal" },
      { " " },
      { g .. " ", ghl }, -- State column (left-aligned)
      { lpad(STATE_WORD[state] or state, state_w - gw - 1), ghl },
      { " " },
      { lpad(dur, dur_w), "LedgerBuilderDim" },
    }
  end

  -- global target state line (desktop · READY / IN PROGRESS / NOT READY)
  local target = st.platform == "desktop" and "desktop" or st.platform_flag
  local tstate = require("ledger.builder.pipeline").target_state(steps, st.statuses or {})
  local tword = TARGET_WORD[tstate] or TARGET_WORD.not_ready
  local target_line = { { "  " .. target .. " · ", "LedgerBuilderDim" }, { tword[1], tword[2] } }

  local lines = { {}, target_line, {}, bar, {} } -- blank + target + blank + bar + blank
  for _, l in ipairs(tbl) do
    lines[#lines + 1] = l
  end
  -- the Run-tests button lives below the table (testing is a separate action)
  lines[#lines + 1] = {}
  lines[#lines + 1] = M.runtests_button(st, tstate)
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
  inner_w = inner_w or 44
  height = height or 12
  local procs = st.procs or {}

  if #procs == 0 then
    local out = { {}, { { "  (no processes for this platform)", "LedgerBuilderDim" } } }
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
    local activity = ui.progressbar({
      w = math.max(6, col_inner - 2),
      val = sweep_pct(p.alive, st.tick or 0),
      icon = { on = "▰", off = "▱" },
      hl = { on = p.alive and "LedgerBlue0" or "LedgerSeparator", off = "LedgerSeparator" },
    })

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
  local avail = height - 1 -- reserve one line for the leading blank
  local base = math.floor(avail / R)
  local extra = avail - base * R

  local out, idx = { {} }, 1 -- leading blank for breathing room
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

function M.logs_content(st, height, width)
  local tasks = require("ledger.tasks")
  width = width or 50
  local id
  if st.focus and st.focus.col == "pipeline" then
    local step = (st.steps or {})[st.focus.idx]
    id = step and step.template or nil
  end
  id = id or tasks.last_started
  -- scroll window: offset 0 = newest tail; st.log_offset scrolls older
  local win = id and tasks.log_window(id, st.log_offset or 0, height or 12) or {}
  if #win == 0 then
    return { { { "(no output yet — run a step)", "LedgerBuilderDim" } } }
  end
  local maxw = math.max(8, width - 2)
  local lines = {}
  for _, l in ipairs(win) do
    local txt = l:gsub("\t", "  ")
    if vim.fn.strdisplaywidth(txt) > maxw then
      txt = vim.fn.strcharpart(txt, 0, maxw - 1) .. "…"
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

-- TEMP: seed empty Stats with per-target mock data when builder.mock_stats is on.
local function mock_on()
  return (require("ledger.config").get().builder or {}).mock_stats == true
end

function M.stats_history(st, inner_w)
  local history = require("ledger.builder.history")
  local target = stats_target(st)
  local recent = history.recent(8, nil, target)
  if #recent == 0 and mock_on() then
    recent = require("ledger.builder.mock").recent(target)
  end
  if #recent == 0 then
    return { {}, { { "no runs yet", "LedgerBuilderDim" } } }
  end
  local maxlabel = math.max(4, (inner_w or 24) - 11)
  local lines = { {} } -- top breathing room
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
  local target = stats_target(st)
  local durs = history.build_durations(12, target)
  if #durs == 0 and mock_on() then
    durs = require("ledger.builder.mock").build_durations(target)
  end
  if #durs == 0 then
    return { {}, { { "no builds yet", "LedgerBuilderDim" } } }
  end
  local maxd = 1
  for _, d in ipairs(durs) do
    maxd = math.max(maxd, d)
  end
  -- fixed, rounded axis (stable labels) instead of a moving per-window max
  local fixed_max = math.max(120, math.ceil(maxd / 60) * 60)
  local norm = {}
  for _, d in ipairs(durs) do
    norm[#norm + 1] = math.floor((d / fixed_max) * 100)
  end
  -- fill the card: size each bar from the available width (label gutter ≈ 8)
  local bw = math.max(1, math.floor(((inner_w or 24) - 8) / #norm))
  local bars = ui.graphs.bar({
    val = norm,
    footer_label = { "last " .. #durs },
    format_labels = function(x)
      return tostring(math.floor((x / 100) * fixed_max)) .. "s"
    end,
    baropts = {
      w = bw,
      gap = 0,
      format_hl = function(x)
        if x > 80 then
          return "LedgerStateFailed"
        elseif x > 50 then
          return "LedgerStateStale"
        end
        return "LedgerStateDone"
      end,
    },
  })
  table.insert(bars, 1, {}) -- top breathing room
  return bars
end

function M.stats_passrate(st, inner_w)
  local history = require("ledger.builder.history")
  local ui = require("volt.ui")
  local target = stats_target(st)
  local rate, n = history.pass_rate(50, target)
  if not rate and mock_on() then
    rate, n = require("ledger.builder.mock").pass_rate(target)
  end
  if not rate then
    return { {}, { { "no test runs yet", "LedgerBuilderDim" } } }
  end
  local bar = ui.progressbar({
    w = math.max(8, (inner_w or 24) - 10),
    val = rate,
    icon = { on = "█", off = "░" },
    hl = { on = rate >= 80 and "LedgerStateDone" or "LedgerStateStale", off = "LedgerBuilderDim" },
  })
  return { {}, bar, {}, { { rate .. "%  (" .. n .. " runs)", "LedgerBuilderDim" } } }
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

-- Help tab bar (Shortcuts / Cheatsheet), highlighting the active tab.
function M.help_tabs(st)
  local active = st.help_tab or "shortcuts"
  local function t(label, key)
    return { " " .. label .. " ", active == key and "LedgerTabActive" or "LedgerTabInactive" }
  end
  return {
    { "  " },
    t("Shortcuts", "shortcuts"),
    { " " },
    t("Cheatsheet", "commands"),
    { "      Tab switches", "LedgerBuilderDim" },
  }
end

-- Shortcuts tab: every key, what it does, the command/purpose.
function M.help_shortcuts()
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
    row("Tab", "switch Desktop / Mobile", "(switches help tabs while help is open)"),
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
    row("A", "run all (build)", "Run all · Clean + reinstall"),
    row("r", "run tests", "active when target is READY"),
    row("w", "toggle Nx watcher", "auto-rebuild libs on change"),
    row("B", "build", "→ desktop build:* / detox e2e:build"),
    row("x / s", "kill / start focused process"),
    row("e", "env dropdown", "desktop: build/MOCK · mobile: detox config"),
    row("p", "toggle PWDEBUG (desktop)"),
    row("d", "Speculos device dropdown"),
    row("F", "fix / maintenance", "reinstall · iOS pods · clean"),
    row("R", "refresh staleness + liveness"),
    {},
    { { "  View", "LedgerBuilderTitle" } },
    row("wheel / C-u C-d", "scroll the Logs pane"),
    row("?", "toggle this help"),
    row("q / Esc", "hide (state preserved)"),
  }
end

-- Cheatsheet tab: curated per-command docs + the repo's package.json scripts
-- grouped by section.
function M.help_commands(st, inner_w)
  local commands = require("ledger.builder.commands")
  inner_w = inner_w or 100
  local lines = {}
  local function title(t)
    lines[#lines + 1] = { { "  " .. t, "LedgerBuilderTitle" } }
  end
  local function item(a, b)
    local cmd = b or ""
    local budget = math.max(10, inner_w - 8 - vim.fn.strdisplaywidth(a))
    if vim.fn.strdisplaywidth(cmd) > budget then
      cmd = vim.fn.strcharpart(cmd, 0, budget - 1) .. "…"
    end
    lines[#lines + 1] = { { "    " }, { a, "LedgerBuilderKey" }, { "  " }, { cmd, "LedgerBuilderDim" } }
  end

  for _, sec in ipairs(commands.builder_docs(st.platform, st.platform_flag)) do
    title(sec.title)
    for _, it in ipairs(sec.items) do
      item(it[1], it[2])
    end
    lines[#lines + 1] = {}
  end

  title("package.json scripts")
  local groups = commands.parse_scripts(st.root)
  if #groups == 0 then
    lines[#lines + 1] = { { "    (no package.json at the repo root)", "LedgerBuilderDim" } }
    return lines
  end
  local RELEVANT = { build = true, e2e = true, test = true, dev = true, clean = true, mobile = true, desktop = true }
  for _, g in ipairs(groups) do
    if RELEVANT[g.section] then
      lines[#lines + 1] = { { "  " .. g.section .. ":", "LedgerYellow0" } }
      for k, it in ipairs(g.items) do
        if k > 6 then
          lines[#lines + 1] = { { "      … (" .. (#g.items - 6) .. " more)", "LedgerBuilderDim" } }
          break
        end
        item(it.name, it.cmd)
      end
    end
  end
  return lines
end

return M
