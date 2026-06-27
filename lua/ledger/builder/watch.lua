-- ledger.builder.watch
--
-- The watch (on-save / nx daemon) + per-project sub-step machinery, extracted
-- from the Builder controller. Wired via `M.setup(ctx)` so it never references
-- the controller module back (no circular require). `ctx` provides:
--   get_state()                         -> the live builder state table
--   refresh()                           -> recompute statuses
--   redraw(which)                       -> redraw the dashboard
--   rebuild()                           -> re-layout (resize the window)
--   open_menu(title, choices, cur, cb)  -> floating picker (menus.open_menu)
--   pick_project(root, prompt, cb)      -> nx project picker (menus.pick_project)

local M = {}

local ctx

function M.setup(c)
  ctx = c
end

-- Per-sub-step status + duration, from their in-memory tasks. Called from the
-- controller's refresh cycle.
function M.refresh_substeps(state)
  local tasks = require("ledger.tasks")
  for _, list in pairs(state.substeps or {}) do
    for _, sub in ipairs(list) do
      if tasks.is_running(sub.task_id) then
        sub.status = "in_progress"
      else
        local r = tasks.last_result(sub.task_id)
        if r then
          sub.status = (r.code == 0) and "done" or "failed"
          sub.dur = r.duration
        end -- else keep the launch-set status until a result lands
      end
    end
  end
end

-- Record + launch a per-project sub-step under `parent` ("libs" for builds).
-- `spec` = { template, label, projects?, filter? }. Shows as a navigable row
-- under its parent (state + duration); its log is pinned so it's visible.
function M.add_substep(parent, spec)
  local state = ctx.get_state()
  if not state.root or not spec.label or spec.label == "" then
    return
  end
  state.substeps = state.substeps or {}
  local list = state.substeps[parent] or {}
  state.substeps[parent] = list
  local rec, is_new
  for _, s in ipairs(list) do
    if s.project == spec.label then
      rec = s
      break
    end
  end
  if not rec then
    rec = { project = spec.label, task_id = "ss:" .. parent .. ":" .. spec.label, template = spec.template }
    list[#list + 1] = rec
    is_new = true
  end
  rec.run = { projects = spec.projects, filter = spec.filter }
  rec.status = "in_progress"
  state.log_id = rec.task_id -- pin the log so the rebuild's output is visible
  state.bottom = "logs"
  state.log_offset = 0
  require("ledger.tasks").run(spec.template, {
    root = state.root,
    task_id = rec.task_id,
    label = spec.label,
    projects = spec.projects,
    filter = spec.filter,
    on_done = function()
      if ctx.get_state() then
        ctx.refresh()
        ctx.redraw("all")
      end
    end,
  })
  ctx.refresh()
  if is_new and state.show_substeps then
    ctx.rebuild() -- a new visible row → re-layout to fit it
  else
    ctx.redraw("all")
  end
end

-- Switch the watch mode: "on-save" (Neovim rebuilds the saved file's nx project
-- via the BufWritePost autocmd — daemon-free), "nx" (the nx watch daemon, which
-- needs NX_DAEMON=true here), or "off".
function M.set_mode(mode)
  local state = ctx.get_state()
  if not state.root then
    return
  end
  local tasks = require("ledger.tasks")
  if mode == "nx" then
    if not tasks.is_running("shared.nx.watch") then
      tasks.run("shared.nx.watch", { root = state.root })
    end
  elseif tasks.is_running("shared.nx.watch") then
    tasks.stop("shared.nx.watch") -- leaving nx mode → stop the daemon
  end
  state.watch_mode = mode
  state.watching = mode ~= "off"
  ctx.redraw("all")
end

function M.menu()
  local state = ctx.get_state()
  if not state.root then
    return
  end
  local cur = state.watch_mode == "nx" and "nx watch (daemon)" or state.watch_mode
  ctx.open_menu("Watch", { "on-save", "nx watch (daemon)", "off" }, cur, function(c)
    M.set_mode(c:find("^nx") and "nx" or (c == "off" and "off" or "on-save"))
  end)
end

-- On-save incremental rebuild: rebuild just the nx project owning the saved
-- file. Debounced per project (reuses the prefetch.lua tick pattern).
local _watch_ticks = {}
function M.on_save(abspath)
  local state = ctx.get_state()
  if not (state and state.root and state.watch_mode == "on-save") then
    return
  end
  local proj = require("ledger.builder.nx").buildable_project_for_file(state.root, abspath)
  if not proj then
    return
  end
  _watch_ticks[proj] = (_watch_ticks[proj] or 0) + 1
  local tick = _watch_ticks[proj]
  vim.defer_fn(function()
    local s = ctx.get_state()
    if _watch_ticks[proj] ~= tick or not (s and s.root and s.watch_mode == "on-save") then
      return
    end
    M.add_substep("libs", { template = "shared.nx.build", label = proj, projects = { proj } })
  end, 400)
end

-- Build a specific nx project (current file's / picked / by filter). Runs through
-- the Builder as a sub-step under `libs`, so status + logs update like any step.
function M.target_menu()
  local state = ctx.get_state()
  if not state.root then
    return
  end
  ctx.open_menu(
    "Build a project",
    {
      "Build current file's project",
      "Build project…",
      "Build by filter…",
    },
    nil,
    function(c)
      if c == "Build current file's project" then
        local f = vim.fn.expand("#:p") -- the file edited before the Builder took focus
        local proj = f ~= "" and require("ledger.builder.nx").project_for_file(state.root, f) or nil
        if not proj then
          vim.notify("Builder: the previous buffer isn't inside an nx project", vim.log.levels.WARN)
          return
        end
        M.add_substep("libs", { template = "shared.nx.build", label = proj, projects = { proj } })
      elseif c == "Build project…" then
        ctx.pick_project(state.root, "Build nx project:", function(p)
          M.add_substep("libs", { template = "shared.nx.build", label = p, projects = { p } })
        end)
      elseif c == "Build by filter…" then
        vim.ui.input({ prompt = "Build -p filter: " }, function(f)
          if f and f ~= "" then
            M.add_substep("libs", { template = "shared.nx.build", label = f, filter = f })
          end
        end)
      end
    end
  )
end

return M
