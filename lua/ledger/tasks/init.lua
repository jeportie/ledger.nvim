-- ledger.tasks
--
-- Runs the templates from ledger.tasks.templates as BACKGROUND jobs (no
-- terminal window steals focus). Output is captured into a per-task ring so
-- the Builder dashboard can tail it. Liveness + last-result are queryable.

local templates = require("ledger.tasks.templates")

local M = {}

-- id -> { job, lines = {ring}, running, started, code, duration }
M.tasks = {}

local RING_MAX = 1000

-- Resolve the monorepo root: configured `monorepo_root` wins, else detect from
-- cwd. Returns nil if neither points at a ledger-live checkout.
function M.resolve_root()
  local detox = require("ledger.detox")
  local cfg = require("ledger.config").get()
  local configured = cfg.monorepo_root
  if configured and configured ~= "" then
    local root = vim.fn.expand(configured)
    if detox.is_ledger_root(root) then
      return root
    end
  end
  local detected = detox.get_repo_root()
  if detox.is_ledger_root(detected) then
    return detected
  end
  return nil
end

local function fmt_label(spec)
  return spec.label or spec.id
end

-- Run a template by id with opts, in the background. Returns true on launch.
function M.run(id, opts)
  local root = M.resolve_root()
  if not root then
    vim.notify(
      "ledger.tasks: not inside a ledger-live repo.\n"
        .. "cd into the monorepo, or set `monorepo_root` in require('ledger').setup{}.",
      vim.log.levels.WARN
    )
    return false, "not a ledger-live repo"
  end
  local spec, err = templates.resolve(id, opts, root)
  if not spec then
    vim.notify("ledger.tasks: " .. tostring(err), vim.log.levels.ERROR)
    return false, err
  end

  local rec = { lines = {}, running = true, started = os.time() }
  local function append(data)
    for _, line in ipairs(data) do
      if line ~= "" then
        rec.lines[#rec.lines + 1] = line
        if #rec.lines > RING_MAX then
          table.remove(rec.lines, 1)
        end
      end
    end
  end

  rec.job = vim.fn.jobstart({ "sh", "-c", spec.cmd }, {
    cwd = spec.cwd,
    env = spec.env,
    on_stdout = function(_, data)
      append(data)
    end,
    on_stderr = function(_, data)
      append(data)
    end,
    on_exit = function(_, code)
      rec.running = false
      rec.code = code
      rec.duration = os.time() - rec.started
      vim.schedule(function()
        local lvl = code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
        vim.notify(
          (code == 0 and "✓ " or "✗ ") .. fmt_label(spec) .. (code == 0 and "" or (" (exit " .. code .. ")")),
          lvl
        )
      end)
    end,
  })

  if not rec.job or rec.job <= 0 then
    vim.notify("ledger.tasks: failed to start " .. fmt_label(spec), vim.log.levels.ERROR)
    return false
  end

  M.tasks[id] = rec
  M.last_started = id
  vim.notify("▶ " .. fmt_label(spec), vim.log.levels.INFO)
  return true
end

function M.is_running(id)
  local r = M.tasks[id]
  return r ~= nil and r.running == true
end

function M.stop(id)
  local r = M.tasks[id]
  if r and r.job then
    vim.fn.jobstop(r.job)
    r.running = false
    return true
  end
  return false
end

-- Last `n` captured lines for a task id (running or finished).
function M.log_tail(id, n)
  local r = M.tasks[id]
  if not r then
    return {}
  end
  n = n or 8
  local out = {}
  local start = math.max(1, #r.lines - n + 1)
  for i = start, #r.lines do
    out[#out + 1] = r.lines[i]
  end
  return out
end

-- { code, duration } for a finished task, or nil.
function M.last_result(id)
  local r = M.tasks[id]
  if r and not r.running and r.code ~= nil then
    return { code = r.code, duration = r.duration }
  end
  return nil
end

function M.running()
  return M.tasks
end

-- :LedgerTask <id> [k=v ...]
local function parse_opts(fargs)
  local opts = {}
  for i = 2, #fargs do
    local k, v = fargs[i]:match("^([%w_]+)=(.+)$")
    if k then
      opts[k] = v
    end
  end
  return opts
end

function M.register_commands()
  vim.api.nvim_create_user_command("LedgerTask", function(a)
    local id = a.fargs[1]
    if not id or not templates.by_id[id] then
      vim.notify("Unknown task: " .. tostring(id), vim.log.levels.ERROR)
      return
    end
    M.run(id, parse_opts(a.fargs))
  end, {
    nargs = "+",
    desc = "Run a ledger build/test task (background)",
    complete = function(arglead)
      local out = {}
      for _, id in ipairs(templates.ids()) do
        if id:find(arglead, 1, true) then
          out[#out + 1] = id
        end
      end
      return out
    end,
  })

  vim.api.nvim_create_user_command("LedgerTasks", function()
    local ids = templates.ids()
    local items = {}
    for _, id in ipairs(ids) do
      items[#items + 1] = { id = id, label = templates.by_id[id].label }
    end
    vim.ui.select(items, {
      prompt = "Ledger task:",
      format_item = function(it)
        return it.label .. "  (" .. it.id .. ")"
      end,
    }, function(choice)
      if choice then
        M.run(choice.id)
      end
    end)
  end, { desc = "Pick and run a ledger build/test task (background)" })
end

return M
