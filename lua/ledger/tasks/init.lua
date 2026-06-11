-- ledger.tasks
--
-- Runs the templates from ledger.tasks.templates. Prefers stevearc/overseer.nvim
-- when present (uniform start/restart/kill/log); otherwise falls back to a
-- terminal split so the backend is usable without overseer installed.

local templates = require("ledger.tasks.templates")

local M = {}

-- id -> { backend, spec, started, task? (overseer), job?, buf? }
M._running = {}

-- Build the `cd <cwd> && export <env> && <cmd>` shell string for the fallback.
function M._shell_string(spec)
  local parts = { "cd " .. vim.fn.shellescape(spec.cwd) }
  if spec.env and next(spec.env) then
    local ex = {}
    for k, v in pairs(spec.env) do
      ex[#ex + 1] = k .. "=" .. vim.fn.shellescape(tostring(v))
    end
    table.sort(ex)
    parts[#parts + 1] = "export " .. table.concat(ex, " ")
  end
  parts[#parts + 1] = spec.cmd
  return table.concat(parts, " && ")
end

local function run_overseer(overseer, spec)
  local task = overseer.new_task({
    name = spec.label,
    cmd = { "sh", "-c", spec.cmd },
    cwd = spec.cwd,
    env = spec.env,
    components = { "default" },
  })
  task:start()
  return task
end

local function run_terminal(spec)
  local shell = M._shell_string(spec)
  -- Daemons get a persistent split; one-shots a transient one.
  vim.cmd("botright " .. (spec.daemon and "10" or "15") .. "split")
  local buf = vim.api.nvim_get_current_buf()
  local job = vim.fn.termopen(shell, {
    on_exit = function(_, code)
      vim.schedule(function()
        local lvl = code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
        vim.notify(spec.label .. (code == 0 and " completed" or (" failed (exit " .. code .. ")")), lvl)
      end)
    end,
  })
  vim.cmd("wincmd p")
  return job, buf
end

-- Run a template by id with opts. Returns true on launch.
function M.run(id, opts)
  local spec, err = templates.resolve(id, opts)
  if not spec then
    vim.notify("ledger.tasks: " .. tostring(err), vim.log.levels.ERROR)
    return false, err
  end
  local has_overseer, overseer = pcall(require, "overseer")
  if has_overseer then
    local task = run_overseer(overseer, spec)
    M._running[id] = { backend = "overseer", task = task, spec = spec, started = os.time() }
  else
    local job, buf = run_terminal(spec)
    M._running[id] = { backend = "term", job = job, buf = buf, spec = spec, started = os.time() }
  end
  vim.notify("▶ " .. spec.label, vim.log.levels.INFO)
  return true
end

-- Is a launched task still running?
function M.is_running(id)
  local r = M._running[id]
  if not r then
    return false
  end
  if r.backend == "overseer" then
    return r.task and not r.task:is_complete()
  end
  return r.job ~= nil and vim.fn.jobwait({ r.job }, 0)[1] == -1
end

-- Stop a launched task.
function M.stop(id)
  local r = M._running[id]
  if not r then
    return false
  end
  if r.backend == "overseer" then
    if r.task then
      r.task:stop()
    end
  elseif r.job then
    vim.fn.jobstop(r.job)
  end
  M._running[id] = nil
  return true
end

-- The currently-tracked tasks (for the dashboard).
function M.running()
  return M._running
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
    desc = "Run a ledger build/test task",
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
  end, { desc = "Pick and run a ledger build/test task" })
end

return M
