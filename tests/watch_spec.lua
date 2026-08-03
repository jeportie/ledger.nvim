local watch = require("ledger.builder.watch")
local tasks = require("ledger.tasks")

describe("ledger.builder.watch", function()
  local state, calls, orig
  before_each(function()
    state = { root = "/repo", show_substeps = true, substeps = {} }
    calls = { run = {}, stop = {}, rebuilt = false, refreshed = 0 }
    watch.setup({
      get_state = function()
        return state
      end,
      refresh = function()
        calls.refreshed = calls.refreshed + 1
      end,
      redraw = function() end,
      rebuild = function()
        calls.rebuilt = true
      end,
      open_menu = function() end,
      pick_project = function() end,
    })
    -- stub the tasks API the watch module calls (save originals)
    orig = { run = tasks.run, stop = tasks.stop, is_running = tasks.is_running, last_result = tasks.last_result }
    tasks.run = function(id, opts)
      calls.run[#calls.run + 1] = { id = id, task_id = opts and opts.task_id, projects = opts and opts.projects }
      return true
    end
    tasks.stop = function(id)
      calls.stop[#calls.stop + 1] = id
      return true
    end
    tasks.is_running = function()
      return false
    end
    tasks.last_result = function()
      return nil
    end
  end)
  after_each(function()
    tasks.run, tasks.stop, tasks.is_running, tasks.last_result = orig.run, orig.stop, orig.is_running, orig.last_result
  end)

  it("add_substep records a row + launches it under a distinct task id, pins log", function()
    watch.add_substep(
      "libs",
      { template = "shared.nx.build", label = "@ledgerhq/live-common", projects = { "@ledgerhq/live-common" } }
    )
    local list = state.substeps.libs
    assert.equals(1, #list)
    assert.equals("@ledgerhq/live-common", list[1].project)
    assert.equals("ss:libs:@ledgerhq/live-common", list[1].task_id)
    assert.equals("in_progress", list[1].status)
    assert.equals("ss:libs:@ledgerhq/live-common", state.log_id) -- log pinned to the sub-step
    assert.equals("ss:libs:@ledgerhq/live-common", calls.run[1].task_id) -- launched with the task id
    assert.is_true(calls.rebuilt) -- a new visible row → re-layout
  end)

  it("add_substep dedups by project (re-run updates the same row)", function()
    watch.add_substep("libs", { template = "shared.nx.build", label = "X", projects = { "X" } })
    watch.add_substep("libs", { template = "shared.nx.build", label = "X", projects = { "X" } })
    assert.equals(1, #state.substeps.libs) -- one row
    assert.equals(2, #calls.run) -- but launched twice
  end)

  it("refresh_substeps maps task results to status + duration", function()
    state.substeps = { libs = { { project = "X", task_id = "ss:libs:X" } } }
    tasks.last_result = function()
      return { code = 0, duration = 12 }
    end
    watch.refresh_substeps(state)
    assert.equals("done", state.substeps.libs[1].status)
    assert.equals(12, state.substeps.libs[1].dur)
    tasks.last_result = function()
      return { code = 1, duration = 3 }
    end
    watch.refresh_substeps(state)
    assert.equals("failed", state.substeps.libs[1].status)
  end)

  it("set_mode toggles watch state + the nx daemon", function()
    local running = false
    tasks.is_running = function()
      return running
    end
    tasks.run = function()
      running = true
      return true
    end
    tasks.stop = function()
      running = false
      return true
    end
    watch.set_mode("nx")
    assert.equals("nx", state.watch_mode)
    assert.is_true(state.watching)
    assert.is_true(running) -- daemon started
    watch.set_mode("off")
    assert.equals("off", state.watch_mode)
    assert.is_false(state.watching)
    assert.is_false(running) -- daemon stopped
  end)

  it("modified_buildable maps git-changed files to their buildable nx projects", function()
    local git_lines = function()
      return {
        " M libs/live-e2e-shared/src/speculos.ts",
        "?? apps/ledger-live-desktop/src/new.tsx",
        " D libs/live-e2e-shared/src/gone.ts", -- deletion → not a rebuild target
        "M  package.json", -- not inside any nx project
        " M libs/live-e2e-shared/src/enum/Account.ts", -- same project as speculos
      }
    end
    local project_of = function(_, abspath)
      if abspath:find("live-e2e-shared", 1, true) then
        return "@ledgerhq/live-e2e-shared"
      elseif abspath:find("ledger-live-desktop", 1, true) then
        return "ledger-live-desktop"
      end
      return nil -- package.json → no project
    end
    local mods = watch.modified_buildable("/repo", git_lines, project_of)
    local by_file = {}
    for _, m in ipairs(mods) do
      by_file[m.file] = m.project
    end
    assert.equals("@ledgerhq/live-e2e-shared", by_file["libs/live-e2e-shared/src/speculos.ts"])
    assert.equals("@ledgerhq/live-e2e-shared", by_file["libs/live-e2e-shared/src/enum/Account.ts"])
    assert.equals("ledger-live-desktop", by_file["apps/ledger-live-desktop/src/new.tsx"])
    assert.is_nil(by_file["package.json"]) -- no project → excluded
    assert.is_nil(by_file["libs/live-e2e-shared/src/gone.ts"]) -- deletion → excluded
    assert.equals(3, #mods)
  end)
end)
