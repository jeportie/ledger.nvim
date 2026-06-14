-- ledger.builder
--
-- The Builder dashboard (LN-006). A large, opaque volt float modelled on the
-- typr stats screen:
--   * Desktop / Mobile tabs (Mobile reveals iOS / Android subtabs) that change
--     the whole pipeline / device / actions.
--   * Two large panes side-by-side cycling a ring [Pipeline ▸ Processes ▸ Logs
--     ▸ Stats] with Ctrl-t (right shifts to left, next appears right).
--   * Background task execution, mouse clicks on every action, device/env
--     dropdowns (nvzone/menu), a `?` cheatsheet overlay, and a wrong-folder
--     guard when not inside a LedgerHQ-ledger-live checkout.

local uv = vim.uv or vim.loop

local M = {}

local SPIN_MS = 120
local PROC_REFRESH_EVERY = 16 -- ticks (~2s) between process liveness polls
local RING = { "pipeline", "processes", "logs", "stats" }
local TITLES = { pipeline = "PIPELINE", processes = "PROCESSES", logs = "LOGS", stats = "STATS" }
local DEVICES = { "nanoS", "nanoSP", "nanoX", "stax", "flex" }
local IOS_CONFIGS = { "ios.sim.debug", "ios.sim.release", "ios.sim.staging", "ios.sim.prerelease" }
-- android.emu.debug is broken locally (Detox/Espresso) — release is the working path.
local ANDROID_CONFIGS = { "android.emu.release", "android.emu.prerelease" }

local state = nil

local function cfg()
  local ok, c = pcall(function()
    return require("ledger.config").get().builder or {}
  end)
  return ok and c or {}
end

local function default_config(flag)
  return flag == "android" and "android.emu.release" or "ios.sim.debug"
end

-- ── ring / focus helpers ────────────────────────────────────────────────────

local function left_view()
  return RING[state.pane_i]
end
local function right_view()
  return RING[(state.pane_i % #RING) + 1]
end
local function focused_view()
  return state.side == "right" and right_view() or left_view()
end

local function view_len(view)
  if view == "pipeline" then
    return #(state.steps or {})
  elseif view == "processes" then
    return #(state.procs or {})
  end
  return 0
end

-- Push the resolved focus (view name + idx) onto state so panes can mark it.
local function sync_focus()
  local v = focused_view()
  local len = view_len(v)
  if len == 0 then
    state.focus_idx = 1
  else
    state.focus_idx = math.max(1, math.min(state.focus_idx or 1, len))
  end
  state.focus = { col = v, idx = state.focus_idx }
end

-- ── status / metadata refresh ───────────────────────────────────────────────

local function refresh_meta()
  state.device = state.device or os.getenv("SPECULOS_DEVICE") or "nanoSP"
  state.mock = os.getenv("MOCK") or "0"
end

local function refresh_statuses()
  if not state then
    return
  end
  if not state.root then
    state.steps, state.procs, state.statuses = {}, {}, {}
    return
  end
  local pipeline = require("ledger.builder.pipeline")
  local staleness = require("ledger.builder.staleness")
  local proc = require("ledger.builder.proc")
  local tasks = require("ledger.tasks")
  local detox = require("ledger.detox")

  state.steps = pipeline.steps(state.platform, { platform_flag = state.platform_flag })
  state.procs = proc.for_platform(state.platform, state.platform_flag)
  local alive = {}
  for _, p in ipairs(state.procs) do
    alive[p.name] = p.alive
  end
  local ctx = {
    root = state.root,
    config = state.config,
    detox_binary = function(c)
      return detox.binary_paths[c]
    end,
    artifact_exists = function(path)
      return uv.fs_stat(path) ~= nil
    end,
    is_stale = function(path, sources)
      return staleness.is_stale(path, sources)
    end,
    proc_alive = function(name)
      return alive[name] or false
    end,
  }
  state.statuses = {}
  for _, step in ipairs(state.steps) do
    if step.template and tasks.is_running(step.template) then
      state.statuses[step.id] = "running"
    else
      state.statuses[step.id] = pipeline.status(step, ctx)
    end
  end
  sync_focus()
end

local function refresh_runtime()
  if not state or not state.root then
    return
  end
  local proc = require("ledger.builder.proc")
  local tasks = require("ledger.tasks")
  state.procs = proc.for_platform(state.platform, state.platform_flag)
  for _, step in ipairs(state.steps or {}) do
    if step.template and tasks.is_running(step.template) then
      state.statuses[step.id] = "running"
    elseif state.statuses[step.id] == "running" then
      state.statuses[step.id] = "ready"
    end
  end
end

-- ── layout ──────────────────────────────────────────────────────────────────

local function pad_to(content, n)
  local out = vim.deepcopy(content)
  while #out < n do
    out[#out + 1] = {}
  end
  return out
end

local function render_view(view, inner_w, height)
  local panes = require("ledger.builder.ui.panes")
  local content
  if view == "pipeline" then
    content = panes.pipeline_content(state)
  elseif view == "processes" then
    content = panes.processes_content(state)
  elseif view == "logs" then
    content = panes.logs_content(state, height)
  else
    content = panes.stats_content(state, inner_w)
  end
  return panes.box(TITLES[view], pad_to(content, height), inner_w)
end

local function divider(n)
  local out = {}
  for _ = 1, n do
    out[#out + 1] = { { "│", "LedgerBuilderDim" } }
  end
  return out
end

local function sections()
  local panes = require("ledger.builder.ui.panes")
  local ui = require("volt.ui")
  return {
    {
      name = "header",
      lines = function()
        return panes.header(state)
      end,
    },
    {
      name = "body",
      lines = function()
        local pane_inner = state.pane_inner
        local pane_h = state.pane_h
        if not state.root then
          return panes.box("BUILDER", pad_to(panes.wrong_folder_content(state.cwd), pane_h), state.full_inner)
        end
        if state.help then
          return panes.box("HELP · cheatsheet", pad_to(panes.cheatsheet(), pane_h), state.full_inner)
        end
        -- vertical (narrow screen): one pane, full width; Ctrl-t still cycles
        if state.winlayout == "vertical" then
          return render_view(left_view(), state.full_inner, pane_h)
        end
        local left = render_view(left_view(), pane_inner, pane_h)
        local right = render_view(right_view(), pane_inner, pane_h)
        return ui.grid_col({
          { lines = left, w = pane_inner + 4, pad = 1 },
          { lines = divider(#left), w = 1, pad = 1 },
          { lines = right, w = pane_inner + 4 },
        })
      end,
    },
    {
      name = "indicator",
      lines = function()
        if not state.root or state.help then
          return { {} }
        end
        local dots = { {} }
        local row = { { "  " } }
        for i, v in ipairs(RING) do
          local on = (i == state.pane_i) or (i == (state.pane_i % #RING) + 1)
          row[#row + 1] = { (on and "●" or "○") .. " ", on and "LedgerStateRunning" or "LedgerBuilderDim" }
          row[#row + 1] = { TITLES[v]:lower() .. "  ", on and "LedgerBuilderTitle" or "LedgerBuilderDim" }
        end
        dots[#dots + 1] = row
        return dots
      end,
    },
  }
end

local function redraw(which)
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    require("volt").redraw(state.buf, which or "all")
  end
end

-- TyprStats-style sizing: single-pane ~80 wide, horizontal ~160; height a
-- modest content height (not full-screen). Responsive: vertical single-pane
-- when the screen is too narrow for two panes.
local function compute_dims()
  local horizontal = vim.o.columns > 170
  state.winlayout = horizontal and "horizontal" or "vertical"
  local W = horizontal and math.min(vim.o.columns - 6, 160) or math.min(vim.o.columns - 6, 84)
  state.W = math.max(W, 76)
  state.full_inner = state.W - 4
  if horizontal then
    state.pane_inner = math.floor((state.W - 4) / 2) - 3
  else
    state.pane_inner = state.full_inner
  end
  state.pane_h = math.max(10, math.min(18, vim.o.lines - 11))
end

-- Rebuild layout + buffer when section line counts change (tabs/subtab/pane/
-- help/platform). volt locks heights at gen_data time.
local function rebuild()
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local volt = require("volt")
  sync_focus()
  vim.bo[state.buf].modifiable = true
  volt.gen_data({ { buf = state.buf, layout = sections(), xpad = 2, ns = state.vns } })
  local h = require("volt.state")[state.buf].h
  volt.set_empty_lines(state.buf, h, state.W)
  vim.bo[state.buf].modifiable = false
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_set_height, state.win, h)
    pcall(vim.api.nvim_win_set_width, state.win, state.W + 4)
  end
  volt.redraw(state.buf, "all")
end

-- ── actions ──────────────────────────────────────────────────────────────────

function M.run_template(template)
  if not state.root then
    return
  end
  local tasks = require("ledger.tasks")
  local opts = { root = state.root }
  if state.platform == "mobile" then
    opts.config = state.config
    opts.platform_flag = state.platform_flag
  end
  tasks.run(template, opts)
  vim.defer_fn(function()
    refresh_runtime()
    redraw("body")
  end, 250)
end

function M.run_step_by_id(id)
  for _, step in ipairs(state.steps or {}) do
    if step.id == id and step.template then
      M.run_template(step.template)
      return
    end
  end
  vim.notify("Builder: no '" .. id .. "' step for this platform", vim.log.levels.WARN)
end

local function activate()
  if not state.root then
    return
  end
  local v = focused_view()
  if v == "pipeline" then
    local step = (state.steps or {})[state.focus_idx]
    if step and step.kind == "test" then
      M.run_test()
    elseif step and step.template then
      M.run_template(step.template)
    end
  elseif v == "processes" then
    local p = (state.procs or {})[state.focus_idx]
    if p then
      M.proc_popup(p)
    end
  end
end

local function proc_action(kind)
  if not state.root or focused_view() ~= "processes" then
    return
  end
  local p = (state.procs or {})[state.focus_idx]
  if not p then
    return
  end
  local proc = require("ledger.builder.proc")
  if kind == "kill" then
    proc.stop(p.name)
  elseif kind == "start" then
    local ok, err = proc.start(p.name)
    if not ok then
      vim.notify("Builder: " .. tostring(err), vim.log.levels.WARN)
    end
  end
  vim.defer_fn(function()
    refresh_runtime()
    redraw("body")
  end, 350)
end

-- Per-process popup: full info (command, port, uptime), log tail, and actions
-- (s start / x kill / R restart / q close). Navigable with j/k.
function M.proc_popup(p)
  local proc = require("ledger.builder.proc")
  local templates = require("ledger.tasks.templates")
  local tasks = require("ledger.tasks")
  local panes = require("ledger.builder.ui.panes")

  local e = proc.by_name[p.name]
  local command, log, uptime = nil, {}, nil
  if e and e.start then
    local spec = templates.resolve(e.start, { config = state.config, platform_flag = state.platform_flag }, state.root)
    command = spec and spec.cmd
    log = tasks.log_tail(e.start, 12)
    local rec = tasks.tasks and tasks.tasks[e.start]
    if rec and rec.started then
      uptime = os.difftime(os.time(), rec.started) .. "s"
    end
  else
    command = proc.detect_cmd(p.name) or "(started/detected externally)"
  end

  local content = panes.process_popup_content({
    label = p.label,
    command = command,
    alive = p.alive,
    port = p.port,
    count = p.count,
    uptime = uptime,
    log = log,
  })
  local text = {}
  for _, line in ipairs(content) do
    local s = ""
    for _, seg in ipairs(line) do
      s = s .. (seg[1] or "")
    end
    text[#text + 1] = s
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.min(64, vim.o.columns - 4)
  local height = math.min(#text, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. p.label .. " ",
    title_pos = "center",
    zindex = 260,
  })
  vim.wo[win].winhighlight = "Normal:LedgerBuilderNormal,FloatBorder:LedgerBuilderTitle"
  vim.wo[win].cursorline = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  local function act(fn)
    fn()
    close()
    vim.defer_fn(function()
      refresh_runtime()
      redraw("body")
    end, 350)
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
  vim.keymap.set("n", "s", function()
    act(function()
      proc.start(p.name, { root = state.root })
    end)
  end, opts)
  vim.keymap.set("n", "x", function()
    act(function()
      proc.stop(p.name)
    end)
  end, opts)
  vim.keymap.set("n", "R", function()
    act(function()
      proc.restart(p.name, { root = state.root })
    end)
  end, opts)
end

local function cycle_pane(delta)
  state.pane_i = ((state.pane_i - 1 + delta) % #RING) + 1
  state.side = "left"
  rebuild()
end

local function set_platform(p)
  state.platform = p
  if p == "mobile" then
    state.config = default_config(state.platform_flag)
  end
  refresh_statuses()
  rebuild()
end

local function set_subplatform(flag)
  state.platform_flag = flag
  state.platform = "mobile"
  state.config = default_config(flag)
  refresh_statuses()
  rebuild()
end

-- A tiny cursor-based dropdown float (no search bar): j/k/arrows move the
-- cursor, <CR> picks the highlighted line, q/<Esc> closes. Focus returns to the
-- builder on close. Chosen over vim.ui.select (snacks) which adds an unwanted
-- search prompt, and over nvzone/menu's keyboard mode (needs per-item keybinds).
local function open_menu(title, choices, current, on_pick)
  if not choices or #choices == 0 then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local width = vim.fn.strdisplaywidth(title) + 2
  local cur_line = 1
  local lines = {}
  for i, c in ipairs(choices) do
    local marked = (c == current)
    lines[i] = (marked and " ● " or "   ") .. c
    if marked then
      cur_line = i
    end
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]) + 2)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local height = math.min(#choices, math.max(1, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.min(width, vim.o.columns - 4),
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    zindex = 250,
  })
  vim.wo[win].cursorline = true
  pcall(vim.api.nvim_win_set_cursor, win, { cur_line, 0 })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  local function pick()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    close()
    local choice = choices[row]
    if choice then
      on_pick(choice)
    end
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", pick, opts)
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
end

local function pick_device()
  open_menu("Speculos device", DEVICES, state.device, function(d)
    state.device = d
    vim.env.SPECULOS_DEVICE = d
    refresh_meta()
    redraw("all")
  end)
end

-- Env dropdown is platform-specific: desktop toggles PWDEBUG; mobile picks the
-- detox configuration (iOS vs Android lists).
local function pick_env()
  if state.platform == "desktop" then
    open_menu("PWDEBUG", { "PWDEBUG=0", "PWDEBUG=1" }, "PWDEBUG=" .. (state.pwdebug or "0"), function(c)
      state.pwdebug = c:match("=(%d)")
      redraw("all")
    end)
  else
    local choices = state.platform_flag == "android" and ANDROID_CONFIGS or IOS_CONFIGS
    open_menu("Detox configuration", choices, state.config, function(c)
      state.config = c
      refresh_statuses()
      rebuild()
    end)
  end
end

-- ── run-a-test flow (All / Pick file / By name|ticket, with discovery) ───────

local function specs_root()
  if state.platform == "desktop" then
    return state.root .. "/e2e/desktop/tests/specs", state.root .. "/e2e/desktop"
  end
  return state.root .. "/e2e/mobile/specs", state.root .. "/e2e/mobile"
end

local function do_run_test(scope_opts)
  if not state.root then
    return
  end
  local tasks = require("ledger.tasks")
  local id = state.platform == "desktop" and "desktop.pw.run" or "mobile.detox.test"
  local opts = vim.tbl_extend("force", { root = state.root }, scope_opts or {})
  if state.platform == "desktop" then
    opts.pwdebug = state.pwdebug == "1"
  else
    opts.config = state.config
    opts.platform_flag = state.platform_flag
  end
  tasks.run(id, opts)
  vim.defer_fn(function()
    refresh_runtime()
    redraw("body")
  end, 250)
end

local function pick_spec_file()
  local dir, base = specs_root()
  local files = vim.fs.find(function(name)
    return name:match("%.spec%.ts$") ~= nil
  end, { path = dir, type = "file", limit = 1000 })
  if #files == 0 then
    vim.notify("Builder: no spec files under " .. dir, vim.log.levels.WARN)
    return
  end
  local rels = {}
  for _, f in ipairs(files) do
    rels[#rels + 1] = f:gsub("^" .. vim.pesc(base .. "/"), "")
  end
  table.sort(rels)
  vim.ui.select(rels, { prompt = "Spec file" }, function(sel)
    if not sel then
      return
    end
    -- Playwright matches a basename substring; Detox uses --testPathPattern path
    local spec = state.platform == "desktop" and vim.fn.fnamemodify(sel, ":t") or sel
    do_run_test({ scope = "file", spec = spec })
  end)
end

-- Run rg with the given args, calling on_line for each output line.
local function rg_lines(args, on_line)
  local ok, res = pcall(function()
    return vim.system(args, { text = true }):wait()
  end)
  if ok and res and res.code == 0 and res.stdout then
    for line in res.stdout:gmatch("[^\r\n]+") do
      on_line(line)
    end
  end
end

local function target_label()
  return state.platform == "desktop" and "desktop" or state.platform_flag
end

-- Pick by test NAME: it()/test() titles in the target's specs. Multiline -U so
-- desktop Playwright (title on the line after `test(`) is captured too.
local function pick_test_name()
  local dir = specs_root()
  local names, seen = {}, {}
  rg_lines({ "rg", "-U", "--no-filename", "-o", "-r", "$1", [[(?:it|test)\(\s*['"`]([^'"`]+)]], dir }, function(line)
    local t = line:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" and t:match("%a") and not seen[t] then
      seen[t] = true
      names[#names + 1] = t
    end
  end)
  table.sort(names)
  names[#names + 1] = "✎ type a name / grep…"
  vim.ui.select(names, { prompt = "Test name (" .. target_label() .. ")" }, function(sel)
    if not sel then
      return
    end
    if sel:match("^✎") then
      vim.ui.input({ prompt = "Name / grep: " }, function(input)
        if input and input ~= "" then
          do_run_test({ scope = "name", name = input })
        end
      end)
    else
      do_run_test({ scope = "name", name = sel })
    end
  end)
end

-- Pick by TICKET: B2CQA-#### referenced in the target's specs.
local function pick_ticket()
  local dir = specs_root()
  local tickets, seen = {}, {}
  rg_lines({ "rg", "--no-filename", "-o", "B2CQA-\\d+", dir }, function(line)
    for tok in line:gmatch("B2CQA%-%d+") do
      if not seen[tok] then
        seen[tok] = true
        tickets[#tickets + 1] = tok
      end
    end
  end)
  table.sort(tickets)
  if #tickets == 0 then
    vim.notify("Builder: no B2CQA tickets found in " .. target_label() .. " specs", vim.log.levels.WARN)
    return
  end
  vim.ui.select(tickets, { prompt = "Ticket (" .. target_label() .. ")" }, function(sel)
    if sel then
      do_run_test({ scope = "name", name = sel })
    end
  end)
end

function M.run_test()
  if not state.root then
    return
  end
  open_menu("Run tests", { "All tests", "Pick spec file…", "By test name…", "By ticket…" }, nil, function(choice)
    if choice == "All tests" then
      do_run_test({ scope = "all" })
    elseif choice == "Pick spec file…" then
      pick_spec_file()
    elseif choice == "By test name…" then
      pick_test_name()
    else
      pick_ticket()
    end
  end)
end

-- ── fix / maintenance menu ────────────────────────────────────────────────────

local function fix_menu()
  local items = { { label = "Global fix (reinstall node_modules + store)", id = "fix.global" } }
  if state.platform == "mobile" and state.platform_flag == "ios" then
    items[#items + 1] = { label = "iOS pod fix (reset Pods)", id = "fix.ios_pod" }
  end
  items[#items + 1] = { label = "Clean (git clean -fdX)", id = "shared.clean" }
  local labels = {}
  local by_label = {}
  for _, it in ipairs(items) do
    labels[#labels + 1] = it.label
    by_label[it.label] = it.id
  end
  open_menu("Fix / maintenance", labels, nil, function(choice)
    local id = by_label[choice]
    if id then
      require("ledger.tasks").run(id)
    end
  end)
end

local function toggle_help()
  state.help = not state.help
  rebuild()
end

-- ── timers / animation ───────────────────────────────────────────────────────

local function start_timer()
  state.timer = uv.new_timer()
  state.timer:start(
    SPIN_MS,
    SPIN_MS,
    vim.schedule_wrap(function()
      if not (state and state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
        return
      end
      state.tick = (state.tick or 0) + 1
      if state.tick % PROC_REFRESH_EVERY == 0 then
        refresh_runtime()
      end
      redraw("body")
    end)
  )
end

local function stop_timer()
  if state and state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then
      state.timer:close()
    end
    state.timer = nil
  end
end

-- ── mouse / focus callbacks injected into panes ──────────────────────────────

local function install_callbacks()
  state.on_platform = set_platform
  state.on_subplatform = set_subplatform
  state.on_device = pick_device
  state.on_env = pick_env
  state.on_step = function(i)
    -- focus the pipeline pane wherever it currently is, then run
    if left_view() == "pipeline" then
      state.side = "left"
    elseif right_view() == "pipeline" then
      state.side = "right"
    end
    state.focus_idx = i
    sync_focus()
    activate()
  end
  state.on_proc = function(i)
    if left_view() == "processes" then
      state.side = "left"
    elseif right_view() == "processes" then
      state.side = "right"
    end
    state.focus_idx = i
    sync_focus()
    activate()
  end
end

-- ── keymaps ───────────────────────────────────────────────────────────────────

local function set_keymaps()
  local buf = state.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  local function move(delta)
    state.focus_idx = (state.focus_idx or 1) + delta
    sync_focus()
    redraw("body")
  end
  local function side(s)
    state.side = s
    sync_focus()
    redraw("body")
  end

  -- within-column nav (Tab is now the platform switch, see below)
  for _, k in ipairs({ "j", "<Down>" }) do
    map(k, function()
      move(1)
    end)
  end
  for _, k in ipairs({ "k", "<Up>" }) do
    map(k, function()
      move(-1)
    end)
  end
  for _, k in ipairs({ "l", "<Right>" }) do
    map(k, function()
      side("right")
    end)
  end
  for _, k in ipairs({ "h", "<Left>" }) do
    map(k, function()
      side("left")
    end)
  end
  -- Tab / Shift-Tab toggle Desktop ↔ Mobile
  local function toggle_platform()
    set_platform(state.platform == "desktop" and "mobile" or "desktop")
  end
  map("<Tab>", toggle_platform)
  map("<S-Tab>", toggle_platform)
  map("<C-t>", function()
    cycle_pane(1)
  end)
  map("<CR>", activate)
  map("x", function()
    proc_action("kill")
  end)
  map("s", function()
    proc_action("start")
  end)
  map("B", function()
    M.run_step_by_id("build")
  end)
  map("r", M.run_test)
  map("F", fix_menu)
  map("R", function()
    refresh_statuses()
    redraw("all")
  end)
  map("D", function()
    set_platform("desktop")
  end)
  map("M", function()
    set_platform("mobile")
  end)
  map("i", function()
    if state.platform == "mobile" then
      set_subplatform("ios")
    end
  end)
  map("a", function()
    if state.platform == "mobile" then
      set_subplatform("android")
    end
  end)
  map("e", pick_env)
  map("d", pick_device)
  map("?", toggle_help)
  map("q", M.close)
  map("<Esc>", M.close)
end

-- ── open / close ──────────────────────────────────────────────────────────────

function M.open()
  if state and state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  local volt = require("volt")
  local builder_cfg = cfg()
  require("ledger.builder.ui.hl").setup({ transparent = builder_cfg.transparent })

  -- Detect from the CURRENT working dir only (no monorepo_root fallback): if
  -- you're not inside a ledger-live checkout, the Builder must say so.
  local detox = require("ledger.detox")
  local cwd = (vim.uv or vim.loop).cwd()
  local detected = detox.get_repo_root()
  local root = detox.is_ledger_root(detected) and detected or nil

  state = {
    platform = "desktop",
    platform_flag = "ios",
    config = default_config("ios"),
    pwdebug = "0",
    tick = 0,
    root = root,
    cwd = cwd,
    help = false,
    pane_i = 1,
    side = "left",
    focus_idx = 1,
    buf = vim.api.nvim_create_buf(false, true),
    vns = vim.api.nvim_create_namespace("ledger_builder"),
    steps = {},
    statuses = {},
    procs = {},
  }

  install_callbacks()
  compute_dims()
  refresh_meta()
  refresh_statuses()

  volt.gen_data({ { buf = state.buf, layout = sections(), xpad = 2, ns = state.vns } })
  local h = require("volt.state")[state.buf].h
  local width = state.W + 4
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Ledger Builder ",
    title_pos = "center",
  })

  -- opaque, theme-tracking panel via a window-local highlight namespace
  local hl = require("ledger.builder.ui.hl")
  if hl.ns then
    vim.api.nvim_win_set_hl_ns(state.win, hl.ns)
  end
  vim.wo[state.win].winhighlight =
    "Normal:LedgerBuilderNormal,NormalFloat:LedgerBuilderNormal,FloatBorder:LedgerBuilderTitle"
  if builder_cfg.transparent then
    vim.wo[state.win].winblend = 0
  end

  volt.run(state.buf, { h = h, w = state.W })

  -- MOUSE: register the buffer with volt's event system (this is what makes
  -- the {text, hl, fn} segments clickable).
  local volt_events = require("volt.events")
  volt_events.add(state.buf)
  volt_events.enable()

  set_keymaps() -- after add() so our nav keys win over volt's defaults

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = state.buf,
    once = true,
    callback = function()
      vim.schedule(M.close)
    end,
  })

  start_timer()
end

function M.close()
  stop_timer()
  if state then
    local win, buf = state.win, state.buf
    state = nil
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function M.toggle()
  if state and state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

function M.register_commands()
  vim.api.nvim_create_user_command("LedgerBuilder", function()
    M.toggle()
  end, { desc = "Toggle the Ledger Builder dashboard" })
end

return M
