-- ledger.builder
--
-- The Builder dashboard (LN-006). A volt float that renders the desktop/mobile
-- E2E pipeline (with mtime staleness), live process cards, and a log tail; runs
-- tasks in the background via ledger.tasks. 2D focus navigation (h/l columns,
-- j/k/arrows/Tab within, Enter to activate). (history / stats graphs / neotest
-- handoff are a later increment.)

local uv = vim.uv or vim.loop

local M = {}

local W = 96
local SPIN_MS = 120
local PROC_REFRESH_EVERY = 16 -- ticks (~2s) between process liveness polls

local state = nil

local function default_config()
  local ok, detox = pcall(require, "ledger.detox")
  if ok and detox.get_detox_config then
    return detox.get_detox_config()
  end
  return "ios.sim.debug"
end

local function focus_len(col)
  if not state then
    return 0
  end
  if col == "processes" then
    return #(state.procs or {})
  end
  return #(state.steps or {})
end

local function clamp_focus()
  local len = focus_len(state.focus.col)
  if len == 0 then
    state.focus.idx = 1
    return
  end
  if state.focus.idx < 1 then
    state.focus.idx = 1
  elseif state.focus.idx > len then
    state.focus.idx = len
  end
end

-- Full recompute: pipeline statuses + process liveness (shell).
local function refresh_statuses()
  if not state then
    return
  end
  local pipeline = require("ledger.builder.pipeline")
  local staleness = require("ledger.builder.staleness")
  local proc = require("ledger.builder.proc")
  local tasks = require("ledger.tasks")
  local detox = require("ledger.detox")

  state.steps = pipeline.steps(state.platform, { platform_flag = state.platform_flag })
  state.procs = proc.status_all()
  local alive = {}
  for _, p in ipairs(state.procs) do
    alive[p.name] = p.alive
  end

  local ctx = {
    root = state.root,
    config = state.config,
    detox_binary = function(cfg)
      return detox.binary_paths[cfg]
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
  clamp_focus()
end

-- Light recompute: process liveness + running overlay (no find/staleness).
local function refresh_runtime()
  if not state then
    return
  end
  local proc = require("ledger.builder.proc")
  local tasks = require("ledger.tasks")
  state.procs = proc.status_all()
  for _, step in ipairs(state.steps or {}) do
    if step.template and tasks.is_running(step.template) then
      state.statuses[step.id] = "running"
    elseif state.statuses[step.id] == "running" then
      state.statuses[step.id] = "ready"
    end
  end
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
        local left = panes.box("PIPELINE", panes.pipeline_content(state), 44)
        local right = panes.box("PROCESSES", panes.processes_content(state), 42)
        right[#right + 1] = {}
        local logs = panes.box("LOGS", panes.logs_content(state), 42)
        for _, l in ipairs(logs) do
          right[#right + 1] = l
        end
        return ui.grid_col({
          { lines = left, w = 48, pad = 2 },
          { lines = right, w = 46 },
        })
      end,
    },
    {
      name = "footer",
      lines = function()
        return panes.footer(state)
      end,
    },
  }
end

local function redraw(which)
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    require("volt").redraw(state.buf, which or "all")
  end
end

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

-- Run the ledger.tasks template for a pipeline step / template id (background).
function M.run_template(template)
  local tasks = require("ledger.tasks")
  local opts = {}
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

-- Activate the focused item: run a step, or toggle a process.
local function activate()
  if state.focus.col == "pipeline" then
    local step = (state.steps or {})[state.focus.idx]
    if step and step.template then
      M.run_template(step.template)
    else
      vim.notify("Builder: '" .. (step and step.label or "?") .. "' has no run action", vim.log.levels.WARN)
    end
  else
    local p = (state.procs or {})[state.focus.idx]
    if not p then
      return
    end
    local proc = require("ledger.builder.proc")
    if p.alive then
      proc.stop(p.name)
    else
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
end

local function proc_action(kind)
  if state.focus.col ~= "processes" then
    vim.notify("Builder: " .. kind .. " acts on a process — switch with l/→", vim.log.levels.INFO)
    return
  end
  local p = (state.procs or {})[state.focus.idx]
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

local function set_keymaps()
  local buf = state.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  local function move(delta)
    state.focus.idx = state.focus.idx + delta
    clamp_focus()
    redraw("body")
  end
  local function switch(col)
    state.focus.col = col
    clamp_focus()
    redraw("body")
  end

  for _, k in ipairs({ "j", "<Down>", "<Tab>" }) do
    map(k, function()
      move(1)
    end)
  end
  for _, k in ipairs({ "k", "<Up>", "<S-Tab>" }) do
    map(k, function()
      move(-1)
    end)
  end
  for _, k in ipairs({ "l", "<Right>" }) do
    map(k, function()
      switch("processes")
    end)
  end
  for _, k in ipairs({ "h", "<Left>" }) do
    map(k, function()
      switch("pipeline")
    end)
  end
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
  map("R", function()
    refresh_statuses()
    redraw("all")
    vim.notify("Builder: refreshed", vim.log.levels.INFO)
  end)
  map("D", function()
    state.platform = "desktop"
    refresh_statuses()
    redraw("all")
  end)
  map("M", function()
    state.platform = "mobile"
    refresh_statuses()
    redraw("all")
  end)
  map("q", M.close)
  map("<Esc>", M.close)
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

function M.open()
  if state and state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  local volt = require("volt")
  require("ledger.builder.ui.hl").setup()

  local root = nil
  local ok_tasks, tasks = pcall(require, "ledger.tasks")
  if ok_tasks and tasks.resolve_root then
    root = tasks.resolve_root()
  end

  state = {
    platform = "desktop",
    platform_flag = "ios",
    config = default_config(),
    tick = 0,
    root = root,
    focus = { col = "pipeline", idx = 1 },
    buf = vim.api.nvim_create_buf(false, true),
    ns = vim.api.nvim_create_namespace("ledger_builder"),
    steps = {},
    statuses = {},
    procs = {},
  }

  refresh_statuses()

  local layout = sections()
  volt.gen_data({ { buf = state.buf, layout = layout, xpad = 2, ns = state.ns } })

  local h = require("volt.state")[state.buf].h
  local height = math.max(8, math.min(h, math.floor(vim.o.lines * 0.9)))
  local width = W + 4
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Ledger Builder ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("winhighlight", "Normal:Normal,FloatBorder:LedgerBuilderTitle", { win = state.win })

  volt.run(state.buf, { h = h, w = W })
  set_keymaps()

  -- Clean up if the window is closed by any means.
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
