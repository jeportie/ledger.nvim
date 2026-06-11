-- ledger.builder
--
-- The Builder dashboard (LN-006). A volt float that renders the desktop/mobile
-- E2E pipeline (with mtime staleness), live process cards, and runs tasks via
-- ledger.tasks. Increment 1: header + pipeline + processes, platform toggle,
-- refresh, spinner animation, per-step run. (log tail / history / stats /
-- neotest handoff are increment 2.)

local uv = vim.uv or vim.loop

local M = {}

local W = 92
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

-- Recompute pipeline step statuses + process liveness into state.
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

  -- process liveness (shell) once, into a map
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
    -- a running task for this step's template overrides the static status
    if step.template and tasks.is_running and tasks.is_running(step.template) then
      state.statuses[step.id] = "running"
    else
      state.statuses[step.id] = pipeline.status(step, ctx)
    end
  end
end

-- Light refresh: process liveness + running-task overlay only (no find/staleness).
local function refresh_runtime()
  if not state then
    return
  end
  local proc = require("ledger.builder.proc")
  local tasks = require("ledger.tasks")
  state.procs = proc.status_all()
  for _, step in ipairs(state.steps or {}) do
    if step.template and tasks.is_running and tasks.is_running(step.template) then
      state.statuses[step.id] = "running"
    elseif state.statuses[step.id] == "running" then
      -- task finished; fall back to a full recompute for this step lazily
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
        return ui.grid_col({
          { lines = panes.pipeline(state), w = 46, pad = 2 },
          { lines = panes.processes(state), w = 42 },
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

local function set_keymaps()
  local buf = state.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
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
  map("R", function()
    refresh_statuses()
    redraw("all")
    vim.notify("Builder: refreshed", vim.log.levels.INFO)
  end)
  map("B", function()
    M.run_step_by_id("build")
  end)
  -- run step N
  for i = 1, 9 do
    map(tostring(i), function()
      local step = (state.steps or {})[i]
      if step and step.template then
        M.run_template(step.template)
      end
    end)
  end
end

function M.run_template(template)
  local tasks = require("ledger.tasks")
  local opts = {}
  if state.platform == "mobile" then
    opts.config = state.config
    opts.platform_flag = state.platform_flag
  end
  tasks.run(template, opts)
  -- reflect "running" immediately
  vim.defer_fn(function()
    refresh_runtime()
    redraw("body")
  end, 200)
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
  local height = math.max(8, math.min(h, math.floor(vim.o.lines * 0.85)))
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
  volt.mappings({
    bufs = { state.buf },
    after_close = function()
      stop_timer()
      state = nil
    end,
  })
  set_keymaps()
  start_timer()
end

function M.close()
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    require("volt").close(state.buf)
  end
  stop_timer()
  state = nil
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
