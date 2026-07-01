local staleness = require("ledger.builder.staleness")
local pipeline = require("ledger.builder.pipeline")

describe("ledger.builder.staleness", function()
  local artifact, srcdir
  before_each(function()
    artifact = vim.fn.tempname()
    vim.fn.writefile({ "built" }, artifact)
    srcdir = vim.fn.tempname()
    vim.fn.mkdir(srcdir, "p")
  end)

  it("missing artifact is stale (no runner call)", function()
    assert.is_true(staleness.is_stale("/no/such/artifact", { srcdir }, function()
      error("runner should not be called when artifact is missing")
    end))
  end)

  it("not stale when find returns nothing", function()
    assert.is_false(staleness.is_stale(artifact, { srcdir }, function()
      return ""
    end))
  end)

  it("stale when find reports a newer file", function()
    assert.is_true(staleness.is_stale(artifact, { srcdir }, function()
      return srcdir .. "/newer.ts\n"
    end))
  end)

  it("skips source dirs that don't exist", function()
    assert.is_false(staleness.is_stale(artifact, { "/nope/missing" }, function()
      error("runner should not be called for a non-existent source dir")
    end))
  end)

  it("freshness labels", function()
    assert.is_nil(staleness.freshness(nil, {}))
    assert.equals("missing", staleness.freshness("/no/such", { srcdir }))
    assert.equals(
      "fresh",
      staleness.freshness(artifact, { srcdir }, function()
        return ""
      end)
    )
  end)
end)

describe("ledger.builder.pipeline", function()
  local function ctx(over)
    return vim.tbl_extend("force", {
      root = "/repo",
      config = "ios.sim.debug",
      detox_binary = function(c)
        return ({ ["ios.sim.debug"] = "apps/ledger-live-mobile/ios/build/x.app" })[c]
      end,
      artifact_exists = function()
        return true
      end,
      is_stale = function()
        return false
      end,
      proc_alive = function()
        return false
      end,
    }, over or {})
  end

  local function find(steps, id)
    for _, s in ipairs(steps) do
      if s.id == id then
        return s
      end
    end
  end

  it("desktop pipeline is clean→install→deps→cli→build, no test/pw rows", function()
    local steps = pipeline.steps("desktop")
    assert.equals("clean", steps[1].id) -- clean leads the pipeline
    assert.equals("build", steps[#steps].id) -- ends at the build, not a test
    assert.is_nil(find(steps, "test"))
    assert.is_nil(find(steps, "pw_setup"))
    assert.is_truthy(find(steps, "clean"))
    -- clean → install → libs → cli order
    local order = {}
    for i, s in ipairs(steps) do
      order[s.id] = i
    end
    assert.is_true(order.clean < order.install)
    assert.is_true(order.install < order.libs)
    assert.is_true(order.libs < order.cli)
  end)

  it("iOS has pod install; Android does not; both end at the build (no test step)", function()
    local ios = pipeline.steps("mobile", { platform_flag = "ios" })
    local android = pipeline.steps("mobile", { platform_flag = "android" })
    assert.is_truthy(find(ios, "pod"))
    assert.is_nil(find(android, "pod"))
    assert.is_nil(find(ios, "test"))
    assert.is_nil(find(android, "test"))
    assert.equals("build", ios[#ios].id)
    assert.equals("build", android[#android].id)
  end)

  it("install is diff-driven (.modules.yaml vs the lockfile); only clean is optional", function()
    local steps = pipeline.steps("desktop")
    local install = find(steps, "install")
    assert.equals("node_modules/.modules.yaml", install.artifact)
    assert.same({ "pnpm-lock.yaml" }, install.sources)
    assert.is_nil(install.optional)
    for _, s in ipairs(steps) do
      if s.id == "clean" then
        assert.is_true(s.optional) -- clean is the only optional (non-gating) step
      else
        assert.is_nil(s.optional)
      end
    end
  end)

  it("artifact step: missing / needs_update / done", function()
    local build = find(pipeline.steps("mobile", { platform_flag = "ios" }), "build")
    assert.equals(
      "missing",
      pipeline.status(
        build,
        ctx({
          artifact_exists = function()
            return false
          end,
        })
      )
    )
    assert.equals(
      "needs_update",
      pipeline.status(
        build,
        ctx({
          is_stale = function()
            return true
          end,
        })
      )
    )
    assert.equals("done", pipeline.status(build, ctx()))
  end)

  it("no-artifact step uses last_result: done on success, failed on error, else missing", function()
    local libs = find(pipeline.steps("desktop"), "libs")
    assert.equals("missing", pipeline.status(libs, ctx())) -- no result → never run
    assert.equals(
      "failed",
      pipeline.status(
        libs,
        ctx({
          last_result = function()
            return { code = 1 }
          end,
        })
      )
    )
    assert.equals(
      "done",
      pipeline.status(
        libs,
        ctx({
          last_result = function()
            return { code = 0 }
          end,
        })
      )
    )
  end)

  it("a failed last_result trumps a present artifact", function()
    local build = find(pipeline.steps("mobile", { platform_flag = "ios" }), "build")
    -- artifact_exists=true (ctx default), but the last run errored → failed
    assert.equals(
      "failed",
      pipeline.status(
        build,
        ctx({
          last_result = function()
            return { code = 2 }
          end,
        })
      )
    )
  end)

  it("libs/cli carry their nx_project so done/failed can be read from Nx", function()
    assert.equals("ledger-live-desktop", find(pipeline.steps("desktop"), "libs").nx_project)
    assert.equals("@ledgerhq/live-cli", find(pipeline.steps("desktop"), "cli").nx_project)
    assert.equals("live-mobile", find(pipeline.steps("mobile", { platform_flag = "ios" }), "libs").nx_project)
  end)

  it("clean is first, optional, runs shared.clean, matches pnpm/git clean", function()
    local clean = find(pipeline.steps("desktop"), "clean")
    assert.equals("shared.clean", clean.template)
    assert.is_true(clean.optional)
    assert.equals("table", type(clean.match)) -- a list of patterns
  end)

  it("target_state: not_ready / in_progress / ready over the step set", function()
    local steps = pipeline.steps("desktop")
    local function all(s)
      local m = {}
      for _, step in ipairs(steps) do
        m[step.id] = s
      end
      return m
    end
    -- ready when every required step is done
    assert.equals("ready", pipeline.target_state(steps, all("done")))
    local missing = all("done")
    missing.install = "missing"
    assert.equals("not_ready", pipeline.target_state(steps, missing))
    assert.equals("not_ready", pipeline.target_state(steps, all("missing")))
    local running = all("done")
    running.build = "in_progress"
    assert.equals("in_progress", pipeline.target_state(steps, running))
    -- clean is optional → its state never gates "ready"
    local clean_idle = all("done")
    clean_idle.clean = "idle"
    assert.equals("ready", pipeline.target_state(steps, clean_idle))
  end)

  it("resolves the detox-binary sentinel via ctx", function()
    local build = find(pipeline.steps("mobile", { platform_flag = "ios" }), "build")
    local path = pipeline.resolve_artifact(build, ctx())
    assert.equals("/repo/apps/ledger-live-mobile/ios/build/x.app", path)
  end)

  it("mobile build label reflects the chosen detox config", function()
    local ios = pipeline.steps("mobile", { platform_flag = "ios", config = "ios.sim.release" })
    assert.equals("e2e:build ios.sim.release", find(ios, "build").label)
    local android = pipeline.steps("mobile", { platform_flag = "android", config = "android.emu.prerelease" })
    assert.equals("e2e:build android.emu.prerelease", find(android, "build").label)
  end)

  it("desktop build step follows the chosen build profile", function()
    local testing = find(pipeline.steps("desktop", { desktop_build = "testing" }), "build")
    assert.equals("build:testing", testing.label)
    assert.equals("desktop.build.testing", testing.template)
    local staging = find(pipeline.steps("desktop", { desktop_build = "staging" }), "build")
    assert.equals("build:staging", staging.label)
    assert.equals("desktop.build.staging", staging.template)
  end)
end)

describe("ledger.builder.proc.for_platform", function()
  local proc = require("ledger.builder.proc")
  local function names(list)
    local out = {}
    for _, n in ipairs(list) do
      out[#out + 1] = n
    end
    return out
  end
  it("desktop = speculos + dev:lld (no metro)", function()
    assert.same({ "speculos", "dev_lld" }, names(proc.names_for("desktop")))
  end)
  it("iOS includes metro", function()
    assert.is_true(vim.tbl_contains(proc.names_for("mobile", "ios"), "metro"))
    assert.is_true(vim.tbl_contains(proc.names_for("mobile", "ios"), "ios_sim"))
  end)
  it("Android excludes metro, includes emulator", function()
    assert.is_false(vim.tbl_contains(proc.names_for("mobile", "android"), "metro"))
    assert.is_true(vim.tbl_contains(proc.names_for("mobile", "android"), "android_emu"))
  end)
end)

describe("ledger.builder.ui.panes", function()
  local panes = require("ledger.builder.ui.panes")

  local fake = {
    platform = "mobile",
    platform_flag = "ios",
    config = "ios.sim.debug",
    device = "nanoSP",
    root = "/repo/LedgerHQ-ledger-live",
    tick = 3,
    bottom = "logs",
    focus = { col = "pipeline", idx = 2 },
    steps = {
      { id = "deps", label = "deps installed", template = "mobile.install" },
      { id = "build", label = "native app built", template = "mobile.detox.build" },
      { id = "metro", label = "metro", template = "mobile.metro", proc = "metro" },
    },
    statuses = { deps = "done", build = "stale", metro = "running" },
    procs = {
      { name = "metro", label = "Metro", alive = true, port = 8081 },
      { name = "speculos", label = "Speculos", alive = true, count = 2 },
      { name = "bridge", label = "Detox bridge", alive = false, port = 8099 },
    },
  }

  local function is_lines(v)
    assert.is_table(v)
    for _, line in ipairs(v) do
      assert.is_table(line) -- each line is a list of segments (or {})
    end
  end

  -- flatten all segment text in a list of volt lines into one string
  local function flat(lines)
    local s = ""
    for _, line in ipairs(lines) do
      for _, seg in ipairs(line) do
        s = s .. (seg[1] or "")
      end
    end
    return s
  end

  -- The Run-tests row's position is layout-defined (clean now renders last), so
  -- resolve it from pipeline_items rather than assuming a fixed offset.
  local function runtests_idx(st)
    for i, it in ipairs(panes.pipeline_items(st)) do
      if it.kind == "runtests" then
        return i
      end
    end
  end

  it("renders all pane content without error", function()
    is_lines(panes.header(fake))
    is_lines(panes.pipeline_content(fake, 44))
    is_lines(panes.processes_content(fake, 44, 12))
    is_lines(panes.logs_content(fake, 10))
    is_lines(panes.stats_content(fake, 40))
    is_lines(panes.stats_history(fake, 24))
    is_lines(panes.stats_buildtime(fake, 24))
    is_lines(panes.stats_passrate(fake, 24))
    is_lines(panes.wrong_folder_content("/home/u"))
    is_lines(panes.help_tabs(fake))
    is_lines(panes.help_shortcuts())
    is_lines(panes.help_commands(fake, 80))
  end)

  it("pipeline renders failed / recommended / idle words", function()
    local st = vim.tbl_extend("force", {}, fake, {
      platform = "desktop",
      steps = {
        { id = "clean", label = "clean", template = "shared.clean" },
        { id = "install", label = "install deps", template = "desktop.install" },
        { id = "libs", label = "build:lld:deps", template = "desktop.build.deps" },
      },
      statuses = { clean = "recommended", install = "idle", libs = "failed" },
      focus = { col = "pipeline", idx = 1 },
    })
    local s = flat(panes.pipeline_content(st, 60))
    assert.is_truthy(s:find("failed", 1, true))
    assert.is_truthy(s:find("recommended", 1, true))
    assert.is_truthy(s:find("—", 1, true)) -- idle renders as an em dash
  end)

  it("wrong-folder banner shows the cwd path", function()
    local lines = panes.wrong_folder_content("/Users/x/projects")
    local joined = ""
    for _, line in ipairs(lines) do
      for _, seg in ipairs(line) do
        joined = joined .. (seg[1] or "")
      end
    end
    assert.is_truthy(joined:find("/Users/x/projects", 1, true))
    assert.is_truthy(joined:find("not inside", 1, true))
  end)

  it("header is the same height on desktop and mobile; subtabs only on mobile", function()
    local mobile = panes.header(fake)
    local desktop = panes.header(vim.tbl_extend("force", {}, fake, { platform = "desktop" }))
    -- a blank line replaces the subtab row on desktop → identical height
    assert.equals(#mobile, #desktop)
    assert.is_truthy(flat(mobile):find("iOS", 1, true))
    assert.is_truthy(flat(mobile):find("Android", 1, true))
    assert.is_nil(flat(desktop):find("Android", 1, true))
  end)

  it("shows a filled title bar only when borderless", function()
    local function has_title_bar(lines)
      for _, line in ipairs(lines) do
        for _, seg in ipairs(line) do
          if seg[2] == "LedgerTitleBar" and (seg[1] or ""):find("Ledger Builder", 1, true) then
            return true
          end
        end
      end
      return false
    end
    -- borderless (the default) → the header carries the title as a LedgerTitleBar
    require("ledger.config").setup({ builder = { border = false } })
    assert.is_true(has_title_bar(panes.header(fake)))
    -- with a border → no in-content title (the border carries it)
    require("ledger.config").setup({ builder = { border = true } })
    assert.is_false(has_title_bar(panes.header(fake)))
    require("ledger.config").setup({ builder = { border = false } }) -- restore the default
  end)

  it("uses the per-tab active highlight groups", function()
    local function active_hl(lines, label)
      for _, line in ipairs(lines) do
        for _, seg in ipairs(line) do
          if seg[1] and seg[1]:find(label, 1, true) then
            return seg[2]
          end
        end
      end
    end
    assert.equals(
      "LedgerTabDesktop",
      active_hl(panes.header(vim.tbl_extend("force", {}, fake, { platform = "desktop" })), "Desktop")
    )
    assert.equals("LedgerTabIos", active_hl(panes.header(fake), "iOS"))
  end)

  it("pipeline renders the table (Step/State/Dur + rule) with the ✶ bullet + Run-tests row", function()
    local lines = panes.pipeline_content(fake, 60)
    local s = flat(lines)
    -- header + a horizontal rule under it
    assert.is_truthy(s:find("Step", 1, true))
    assert.is_truthy(s:find("State", 1, true))
    assert.is_truthy(s:find("─", 1, true)) -- header rule
    -- the focused step (idx 2) leads with ▶; non-focused with ✶
    assert.is_truthy(s:find("✶", 1, true))
    assert.is_truthy(s:find("▶", 1, true))
    -- the Run-tests row is the last pipeline row (test devicon + "Run tests")
    assert.is_truthy(s:find("Run tests", 1, true))
    assert.is_truthy(s:find("󰂓", 1, true)) -- the test icon (default test_icon, nf-md-flask)
  end)

  it("progress bar counts only required steps; clean shows the broom + steps renumber", function()
    local pl = require("ledger.builder.pipeline")
    local steps = pl.steps("desktop") -- clean, install, libs, cli, build
    local statuses = {}
    for _, st in ipairs(steps) do
      statuses[st.id] = "done"
    end
    local s = flat(
      panes.pipeline_content(
        vim.tbl_extend("force", {}, fake, { platform = "desktop", steps = steps, statuses = statuses }),
        70
      )
    )
    assert.is_truthy(s:find("4/4", 1, true)) -- 4 required steps; clean excluded (not 5/5)
    assert.is_truthy(s:find("󰃢 clean", 1, true)) -- clean leads with the broom, not a number
    assert.is_truthy(s:find("1 install deps", 1, true)) -- real steps renumber from 1
    assert.is_truthy(s:find("2 build:lld:deps", 1, true))
  end)

  it("a blank line separates the build steps from the Run-tests row", function()
    local pl = require("ledger.builder.pipeline")
    local lines = panes.pipeline_content(
      vim.tbl_extend("force", {}, fake, { platform = "desktop", steps = pl.steps("desktop"), statuses = {} }),
      70
    )
    local rt
    for i, l in ipairs(lines) do
      if flat({ l }):find("Run tests", 1, true) then
        rt = i
      end
    end
    assert.is_truthy(rt)
    assert.same({}, lines[rt - 1]) -- the row immediately above Run-tests is blank
  end)

  it("pipeline_items interleaves sub-steps and ends with run-tests", function()
    local st = vim.tbl_extend("force", {}, fake, {
      steps = {
        { id = "libs", label = "build:lld:deps", template = "desktop.build.deps" },
        { id = "build", label = "build:testing", template = "desktop.build.testing" },
      },
      show_substeps = true,
      substeps = { libs = { { project = "@ledgerhq/live-common", task_id = "ss:libs:c", status = "in_progress" } } },
    })
    local items = panes.pipeline_items(st)
    assert.equals("step", items[1].kind)
    assert.equals("substep", items[2].kind)
    assert.equals("@ledgerhq/live-common", items[2].sub.project)
    assert.equals("step", items[3].kind)
    assert.equals("runtests", items[4].kind)
    -- folded away when show_substeps is false
    st.show_substeps = false
    assert.equals(3, #panes.pipeline_items(st)) -- libs, build, runtests
  end)

  it("pipeline_items renders clean LAST, after the Run-tests row (optional)", function()
    local st = vim.tbl_extend("force", {}, fake, {
      steps = {
        { id = "clean", label = "clean", template = "shared.clean", optional = true },
        { id = "install", label = "install deps", template = "desktop.install" },
        { id = "build", label = "build:testing", template = "desktop.build.testing" },
      },
      show_substeps = false,
    })
    local items = panes.pipeline_items(st)
    assert.equals("install", items[1].step.id) -- real steps first, clean is NOT inline
    assert.equals("build", items[2].step.id)
    assert.equals("runtests", items[3].kind)
    assert.equals("clean", items[4].step.id) -- clean last, after Run-tests
  end)

  it("the focused pipeline step is blue (LedgerTitle), matching a focused process card", function()
    local pl = require("ledger.builder.pipeline")
    local st = vim.tbl_extend("force", {}, fake, {
      platform = "desktop",
      steps = pl.steps("desktop"),
      show_substeps = false,
      focus = { col = "pipeline", idx = 1 }, -- first pipeline item (a real build step)
    })
    local found = false
    for _, l in ipairs(panes.pipeline_content(st, 70)) do
      if l[1] and l[1][1] and l[1][1]:find("▶", 1, true) then
        assert.equals("LedgerTitle", l[1][2]) -- bullet blue+bold
        assert.equals("LedgerTitle", l[2][2]) -- label blue+bold
        found = true
      end
    end
    assert.is_true(found) -- the focused row rendered a ▶
  end)

  it("renders a sub-step row indented with state + duration", function()
    local st = vim.tbl_extend("force", {}, fake, {
      steps = { { id = "libs", label = "build:lld:deps", template = "desktop.build.deps" } },
      statuses = { libs = "done" },
      show_substeps = true,
      substeps = { libs = { { project = "@ledgerhq/live-common", task_id = "x", status = "done", dur = 12 } } },
      focus = { col = "pipeline", idx = 1 },
    })
    local s = flat(panes.pipeline_content(st, 70))
    assert.is_truthy(s:find("└ @ledgerhq/live-common", 1, true))
    assert.is_truthy(s:find("12s", 1, true))
  end)

  it("logs_content prefers a pinned st.log_id (ad-hoc/watch log)", function()
    require("ledger.tasks").inject("ss:libs:probe", { "sub-step log line" }, 0)
    local st = vim.tbl_extend("force", {}, fake, { log_id = "ss:libs:probe", bottom = "logs" })
    local s = flat(panes.logs_content(st, 10, 60))
    assert.is_truthy(s:find("sub-step log line", 1, true))
  end)

  -- a focused process shows ITS OWN task log, never another task's
  it("current_log_id maps a focused process to its own start template", function()
    require("ledger.tasks").last_started = "mobile.detox.test" -- a different task ran last
    local st = vim.tbl_extend("force", {}, fake, {
      procs = { { name = "metro", label = "Metro", alive = true, port = 8081 } },
      focus = { col = "processes", idx = 1 },
    })
    assert.equals("mobile.metro", panes.current_log_id(st)) -- metro's log, not last_started
  end)

  -- a focused process with no start template (no own log) shows nothing
  it("current_log_id returns nil for a focused logless process (no bleed)", function()
    require("ledger.tasks").last_started = "mobile.detox.test"
    local st = vim.tbl_extend("force", {}, fake, {
      procs = { { name = "android_emu", label = "Android emulator", alive = true } },
      focus = { col = "processes", idx = 1 },
    })
    assert.is_nil(panes.current_log_id(st)) -- android_emu has no start template
  end)

  -- a task-tracked card (the detox bridge) shows the log of the task it lives in
  it("current_log_id maps a focused task-based process to its task log", function()
    local proc = require("ledger.builder.proc")
    proc.by_name._test_bridge = { name = "_test_bridge", task = "mobile.detox.test" }
    local st = vim.tbl_extend("force", {}, fake, {
      procs = { { name = "_test_bridge", alive = true } },
      focus = { col = "processes", idx = 1 },
    })
    local id = panes.current_log_id(st)
    proc.by_name._test_bridge = nil -- cleanup the injected registry entry
    assert.equals("mobile.detox.test", id)
  end)

  -- the Run-tests row shows the TEST task's log, not last_started (which could be
  -- Metro or a build that ran afterwards)
  it("current_log_id maps the Run-tests row to the test task, not last_started", function()
    require("ledger.tasks").last_started = "mobile.metro" -- metro ran last, but isn't the test
    local function runtests_log(platform, flag)
      local steps = require("ledger.builder.pipeline").steps(platform, { platform_flag = flag })
      local st = vim.tbl_extend("force", {}, fake, {
        platform = platform,
        platform_flag = flag,
        steps = steps,
        show_substeps = false,
      })
      st.focus = { col = "pipeline", idx = runtests_idx(st) } -- the Run-tests row
      return panes.current_log_id(st)
    end
    assert.equals("mobile.detox.test", runtests_log("mobile", "ios"))
    assert.equals("desktop.pw.run", runtests_log("desktop"))
  end)

  -- focused_task_id backs both the Logs panel and the stop (x) action
  it("focused_task_id resolves the focused pipeline item (nil off-pipeline)", function()
    local steps = require("ledger.builder.pipeline").steps("mobile", { platform_flag = "ios" })
    local base = { platform = "mobile", platform_flag = "ios", steps = steps, show_substeps = false }
    local function focus(idx)
      return vim.tbl_extend("force", {}, fake, base, { focus = { col = "pipeline", idx = idx } })
    end
    -- item 1 is the first build step SHOWN (clean renders last, so it is not clean)
    local items = panes.pipeline_items(focus(1))
    assert.equals(items[1].step.template, panes.focused_task_id(focus(1)))
    assert.equals("mobile.detox.test", panes.focused_task_id(focus(runtests_idx(focus(1))))) -- Run-tests row
    local proc = vim.tbl_extend(
      "force",
      {},
      fake,
      { procs = { { name = "metro" } }, focus = { col = "processes", idx = 1 } }
    )
    assert.is_nil(panes.focused_task_id(proc)) -- a focused process is not a pipeline task
  end)

  it("Logs panel shows the running test's log when the Run-tests row is focused", function()
    local tasks = require("ledger.tasks")
    tasks.inject("desktop.pw.run", { "Running 3 tests", "✓ all passed" }, 0)
    tasks.last_started = "desktop.pw.run"
    local steps = require("ledger.builder.pipeline").steps("desktop")
    local st = vim.tbl_extend("force", {}, fake, {
      platform = "desktop",
      steps = steps,
      show_substeps = false,
      bottom = "logs",
    })
    st.focus = { col = "pipeline", idx = runtests_idx(st) }
    local s = flat(panes.logs_content(st, 10, 60))
    assert.is_truthy(s:find("Running 3 tests", 1, true)) -- the test log shows
    assert.is_nil(s:find("no output yet", 1, true)) -- not the empty placeholder
  end)

  it("pipeline cells are left-aligned with uniform widths across targets", function()
    local ui = require("volt.ui")
    local function rowwidths(p, f)
      local st = vim.tbl_extend("force", {}, fake, { platform = p, platform_flag = f })
      st.steps = require("ledger.builder.pipeline").steps(p, { platform_flag = f })
      st.statuses = {}
      local out = {}
      for _, l in ipairs(panes.pipeline_content(st, 70)) do
        out[#out + 1] = ui.line_w(l)
      end
      return out
    end
    -- the table body rows are all the same width regardless of target
    local d = rowwidths("desktop")
    local maxw = 0
    for _, w in ipairs(d) do
      maxw = math.max(maxw, w)
    end
    local i = rowwidths("mobile", "ios")
    local maxi = 0
    for _, w in ipairs(i) do
      maxi = math.max(maxi, w)
    end
    assert.equals(maxw, maxi) -- identical table shape across targets
  end)

  it("the navigable Run-tests row reflects readiness + focuses at row #steps+1", function()
    local pl = require("ledger.builder.pipeline")
    local steps = pl.steps("mobile", { platform_flag = "ios" })
    local function content(statuses, focus_idx)
      local st = vim.tbl_extend("force", {}, fake, {
        platform = "mobile",
        platform_flag = "ios",
        steps = steps,
        statuses = statuses,
        focus = { col = "pipeline", idx = focus_idx },
      })
      return flat(panes.pipeline_content(st, 70))
    end
    -- all build steps done (mobile → no pw gate) → Run-tests row reads "ready"
    local done = {}
    for _, s in ipairs(steps) do
      done[s.id] = "done"
    end
    assert.is_truthy(content(done, #steps + 1):find("ready", 1, true))
    -- not built → "locked"
    assert.is_truthy(content({}, 1):find("locked", 1, true))
  end)

  it("proc_tile splits N processes into rows of ≤2 (lone last when odd)", function()
    assert.same({ 2 }, panes.proc_tile(2))
    assert.same({ 2, 1 }, panes.proc_tile(3))
    assert.same({ 2, 2 }, panes.proc_tile(4))
    assert.same({ 2, 2, 1 }, panes.proc_tile(5))
  end)

  it("pw_installed is true when a candidate browsers dir is non-empty", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/chromium-1140", "p")
    require("ledger.config").setup({ builder = { pw_browsers_path = dir } })
    assert.is_true(panes.pw_installed())
    require("ledger.config").setup({ builder = {} }) -- restore
  end)

  it("header title bg covers only the title text, not the whole line", function()
    local seg
    for _, line in ipairs(panes.header(fake)) do
      for _, s in ipairs(line) do
        if s[2] == "LedgerTitleBar" then
          seg = s[1]
        end
      end
    end
    assert.equals(" Ledger Builder ", seg) -- a small plaque, not a full-width bar
  end)

  it("pipeline Dur reads per-template durations from state (off the redraw path)", function()
    -- refresh_statuses snapshots store durations into state.durations; the pane
    -- reads from there (no disk store.get on every render).
    local st = vim.tbl_extend("force", {}, fake, {
      durations = { [fake.steps[1].template] = { code = 0, duration = 123 } }, -- fmt_dur(123) = 2m03
    })
    assert.is_truthy(flat(panes.pipeline_content(st, 80)):find("2m03", 1, true))
    -- with no snapshot the column degrades to "-" rather than reading disk
    local bare = vim.tbl_extend("force", {}, fake, { durations = nil })
    local s = flat(panes.pipeline_content(bare, 80))
    assert.is_truthy(s:find("-", 1, true))
  end)

  it("the running step's bullet animates with the tick", function()
    -- a running step that is NOT focused → its bullet uses the (animated) spinner,
    -- so the rendered row changes between ticks (pattern-agnostic: the test rtp
    -- has no spinner.nvim, so this falls back to the builtin animated frames).
    local f = vim.tbl_extend("force", {}, fake, {
      steps = { { id = "r", label = "building" }, { id = "p", label = "pending" } },
      statuses = { r = "in_progress", p = "missing" },
      focus = { col = "pipeline", idx = 2 }, -- focus the pending step, not the running one
    })
    local t0 = flat(panes.pipeline_content(vim.tbl_extend("force", {}, f, { tick = 0 }), 60))
    local t1 = flat(panes.pipeline_content(vim.tbl_extend("force", {}, f, { tick = 1 }), 60))
    assert.are_not.equals(t0, t1)
  end)

  it("pipeline shows the target-state line and the 4 state words", function()
    local f = vim.tbl_extend("force", {}, fake, {
      platform = "desktop",
      steps = {
        { id = "a", label = "x" },
        { id = "b", label = "y" },
        { id = "c", label = "z" },
        { id = "d", label = "w" },
      },
      statuses = { a = "done", b = "in_progress", c = "needs_update", d = "missing" },
    })
    local s = flat(panes.pipeline_content(f, 60))
    assert.is_truthy(s:find("desktop ·", 1, true)) -- global target-state line
    assert.is_truthy(s:find("done", 1, true))
    assert.is_truthy(s:find("in progress", 1, true))
    assert.is_truthy(s:find("needs update", 1, true))
    assert.is_truthy(s:find("missing", 1, true))
  end)

  it("logs truncate to the box width (not 50) and honor the scroll offset", function()
    local tasks = require("ledger.tasks")
    tasks.tasks["spec.logtest"] = { lines = {}, running = false }
    for i = 1, 30 do
      tasks.tasks["spec.logtest"].lines[i] = "line" .. i .. " " .. string.rep("z", 100)
    end
    local f = vim.tbl_extend("force", {}, fake, {
      steps = { { id = "x", label = "x", template = "spec.logtest" } },
      focus = { col = "pipeline", idx = 1 },
      log_offset = 0,
    })
    local ui = require("volt.ui")
    for _, l in ipairs(panes.logs_content(f, 6, 40)) do
      assert.is_true(ui.line_w(l) <= 40) -- fits the passed width, not a hardcoded 50
    end
    assert.is_truthy(flat(panes.logs_content(f, 6, 120)):find("line30", 1, true)) -- tail
    f.log_offset = 20
    assert.is_truthy(flat(panes.logs_content(f, 6, 120)):find("line10", 1, true)) -- scrolled up
    tasks.tasks["spec.logtest"] = nil
  end)

  it("stats panes start with a blank line and the chart fills the card", function()
    local history = require("ledger.builder.history")
    history._entries = {} -- seed in-memory only (no disk write → no cross-spec coupling)
    -- first line is a blank breathing-room row even with no data
    assert.same({}, panes.stats_history(fake, 30)[1])
    assert.same({}, panes.stats_buildtime(fake, 30)[1])
    assert.same({}, panes.stats_passrate(fake, 30)[1])
    -- seed build history for the target so the chart renders, then verify it
    -- fills the card (a wider card → wider bars)
    local target = fake.platform == "desktop" and "desktop" or fake.platform_flag
    local entries = {}
    for i = 1, 6 do
      entries[i] = { time = i, label = "b" .. i, kind = "build", code = 0, duration = 30 + i, platform = target }
    end
    history._entries = entries
    local ui = require("volt.ui")
    local function maxw(lines)
      local m = 0
      for _, l in ipairs(lines) do
        m = math.max(m, ui.line_w(l))
      end
      return m
    end
    assert.is_true(maxw(panes.stats_buildtime(fake, 60)) > maxw(panes.stats_buildtime(fake, 24)))
    history._entries = {} -- leave the in-memory cache clean
  end)

  it("processes tile to fill the pane (2/3/4 → grid that fills height)", function()
    local function procs(n)
      local p = {}
      for i = 1, n do
        p[i] = { name = "p" .. i, label = "Proc" .. i, alive = i % 2 == 0, count = 1 }
      end
      return vim.tbl_extend("force", {}, fake, { procs = p, focus = { col = "processes", idx = 1 } })
    end
    -- each count fills exactly the requested height
    assert.equals(12, #panes.processes_content(procs(2), 60, 12))
    assert.equals(12, #panes.processes_content(procs(3), 60, 12))
    assert.equals(12, #panes.processes_content(procs(4), 60, 12))
    -- all process labels are rendered
    local s = flat(panes.processes_content(procs(4), 60, 12))
    for i = 1, 4 do
      assert.is_truthy(s:find("Proc" .. i, 1, true))
    end
    -- the activity row is the (longer) progress bar, not a short spinner
    assert.is_truthy(s:find("▰", 1, true) or s:find("▱", 1, true))
  end)

  it("help has two tabs and the cheatsheet lists package.json scripts", function()
    -- tab bar shows both tabs (help_tabs returns a single line → wrap for flat)
    local tabs = flat({ panes.help_tabs(fake) })
    assert.is_truthy(tabs:find("Shortcuts", 1, true))
    assert.is_truthy(tabs:find("Cheatsheet", 1, true))
    -- shortcuts tab dropped D/M and gained p
    local sc = flat(panes.help_shortcuts())
    assert.is_nil(sc:find("desktop / mobile platform", 1, true))
    assert.is_truthy(sc:find("PWDEBUG", 1, true))
    -- the run-all shortcut names what it does (runs the outdated steps)
    assert.is_truthy(sc:find("outdated", 1, true))
    -- commands tab includes curated builder docs (per active platform)
    assert.is_truthy(flat(panes.help_commands(fake, 100)):find("Pipeline", 1, true))
  end)

  it("stats show empty-state messages when history is empty", function()
    require("ledger.builder.history")._entries = {} -- in-memory only
    assert.is_truthy(flat(panes.stats_history(fake, 30)):find("no runs yet", 1, true))
    assert.is_truthy(flat(panes.stats_buildtime(fake, 30)):find("no builds yet", 1, true))
    assert.is_truthy(flat(panes.stats_passrate(fake, 30)):find("no test runs yet", 1, true))
  end)

  it("process popup content has command, log + action footer", function()
    local lines = panes.process_popup_content({
      label = "Metro",
      command = "pnpm dev:llm",
      alive = true,
      port = 8081,
      uptime = "42s",
      log = { "bundle 1823 modules", "error: boom" },
    })
    local joined = ""
    for _, line in ipairs(lines) do
      for _, seg in ipairs(line) do
        joined = joined .. (seg[1] or "")
      end
    end
    assert.is_truthy(joined:find("pnpm dev:llm", 1, true))
    assert.is_truthy(joined:find(":8081", 1, true))
    assert.is_truthy(joined:find("bundle 1823", 1, true))
    assert.is_truthy(joined:find("restart", 1, true))
  end)

  it("box wraps content with a titled border of stable width", function()
    local boxed = panes.box("PIPELINE", panes.pipeline_content(fake), 44)
    local ui = require("volt.ui")
    -- first line is the titled top border; all lines share one width
    local w0 = ui.line_w(boxed[1])
    for _, line in ipairs(boxed) do
      assert.equals(w0, ui.line_w(line))
    end
    assert.is_true(#boxed >= #panes.pipeline_content(fake) + 2) -- + top + bottom
  end)

  it("loads the controller and hl without error", function()
    assert.has_no.errors(function()
      require("ledger.builder")
      require("ledger.builder.ui.hl")
    end)
  end)
end)

describe("ledger.builder.ui.hl + loader", function()
  it("apply_float defines accent + Normal groups in the ns", function()
    local hl = require("ledger.builder.ui.hl")
    local ns = vim.api.nvim_create_namespace("ledger_test_hl")
    assert.has_no.errors(function()
      hl.apply_float(ns)
    end)
    assert.is_table(vim.api.nvim_get_hl(ns, { name = "LedgerGreen0" }))
    assert.is_table(vim.api.nvim_get_hl(ns, { name = "Normal" }))
  end)

  it("pulse cycles through the level groups", function()
    local hl = require("ledger.builder.ui.hl")
    assert.equals("LedgerPulse0", hl.pulse(0))
    assert.is_truthy(hl.pulse(4):match("^LedgerPulse%d$"))
  end)

  it("loader module loads", function()
    assert.has_no.errors(function()
      require("ledger.builder.ui.loader")
    end)
  end)
end)

describe("ledger.builder run-app dispatch", function()
  local builder = require("ledger.builder")
  it("offers Dev/Production (desktop) and Dev/Staging (mobile) run entries", function()
    local function ids(platform, flag)
      local out = {}
      for _, e in ipairs(builder.run_app_entries(platform, flag)) do
        out[#out + 1] = e.id
      end
      return out
    end
    assert.same({ "desktop.dev", "desktop.run.prod" }, ids("desktop"))
    assert.same({ "mobile.run.ios", "mobile.run.ios.staging" }, ids("mobile", "ios"))
    assert.same({ "mobile.run.android", "mobile.run.android.staging" }, ids("mobile", "android"))
  end)
end)

describe("ledger.builder open-report dispatch", function()
  local builder = require("ledger.builder")
  it("maps a platform to its single Allure report template", function()
    assert.equals("desktop.allure", builder.report_template_for("desktop"))
    assert.equals("mobile.allure", builder.report_template_for("mobile"))
  end)
end)

describe("ledger.builder._enclosing_export", function()
  local builder = require("ledger.builder")
  -- mirrors the real swap.other.ts layout: a parameterized title inside an exported
  -- function that a .spec.ts imports + calls.
  local lines = {
    "export function runSwapWithoutAccountTest() {", -- 1
    "  it('swap without account', () => {});", -- 2
    "}", -- 3
    "export function runSwapDiscreetModeTest(", -- 4
    "  account,", -- 5
    ") {", -- 6
    "  it('Checks if the amount is hidden in the asset drawer', () => {});", -- 7
    "}", -- 8
  }
  it("returns the nearest export at/above a line", function()
    assert.equals("runSwapDiscreetModeTest", builder._enclosing_export(lines, 7))
    assert.equals("runSwapWithoutAccountTest", builder._enclosing_export(lines, 2))
    assert.equals("runSwapDiscreetModeTest", builder._enclosing_export(lines, 4)) -- on the export line
  end)
  it("handles export const / async function, nil when none", function()
    assert.equals("foo", builder._enclosing_export({ "export const foo = () => {", "it('x')" }, 2))
    assert.equals("bar", builder._enclosing_export({ "export async function bar() {", "it('y')" }, 2))
    assert.is_nil(builder._enclosing_export({ "const localOnly = 1", "it('z')" }, 2))
  end)
end)
