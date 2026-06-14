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

  it("desktop pipeline is build-focused and ends in test", function()
    local steps = pipeline.steps("desktop")
    assert.equals("clean", steps[1].id)
    assert.equals("test", steps[#steps].id)
    assert.is_truthy(find(steps, "cli"))
    assert.is_truthy(find(steps, "build"))
    assert.is_nil(find(steps, "pod")) -- desktop has no pods
  end)

  it("iOS has pod install; Android does not (and neither carries Metro as a step)", function()
    local ios = pipeline.steps("mobile", { platform_flag = "ios" })
    local android = pipeline.steps("mobile", { platform_flag = "android" })
    assert.is_truthy(find(ios, "pod"))
    assert.is_nil(find(android, "pod"))
    assert.is_nil(find(ios, "metro")) -- Metro is a process, not a pipeline step
    assert.is_nil(find(android, "metro"))
    assert.equals("test", ios[#ios].id)
    assert.equals("test", android[#android].id)
  end)

  it("clean and install are optional steps", function()
    local steps = pipeline.steps("desktop")
    assert.is_true(find(steps, "clean").optional)
    assert.is_true(find(steps, "install").optional)
    assert.is_nil(find(steps, "build").optional)
  end)

  it("artifact step: pending / stale / done", function()
    local build = find(pipeline.steps("mobile", { platform_flag = "ios" }), "build")
    assert.equals(
      "pending",
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
      "stale",
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

  it("step with no artifact is ready", function()
    local libs = find(pipeline.steps("desktop"), "libs")
    assert.equals("ready", pipeline.status(libs, ctx()))
  end)

  it("resolves the detox-binary sentinel via ctx", function()
    local build = find(pipeline.steps("mobile", { platform_flag = "ios" }), "build")
    local path = pipeline.resolve_artifact(build, ctx())
    assert.equals("/repo/apps/ledger-live-mobile/ios/build/x.app", path)
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

  it("renders all pane content without error", function()
    is_lines(panes.header(fake))
    is_lines(panes.pipeline_content(fake, 44, 14))
    is_lines(panes.processes_content(fake, 44, 12))
    is_lines(panes.logs_content(fake, 10))
    is_lines(panes.stats_content(fake, 40))
    is_lines(panes.stats_history(fake, 24))
    is_lines(panes.stats_buildtime(fake, 24))
    is_lines(panes.stats_passrate(fake, 24))
    is_lines(panes.bottom_indicator(fake))
    is_lines(panes.wrong_folder_content("/home/u"))
    is_lines(panes.cheatsheet())
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

  it("header shows a centered title when borderless", function()
    -- config default border = false → the header carries the title itself
    assert.is_truthy(flat(panes.header(fake)):find("Ledger Builder", 1, true))
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

  it("pipeline fills the pane height and uses the ✶ step bullet", function()
    local lines = panes.pipeline_content(fake, 44, 16)
    -- progress bar + blank + steps distributed to fill → exactly height lines
    assert.equals(16, #lines)
    -- the focused step (idx 2) leads with ▶; the others with ✶
    local s = flat(lines)
    assert.is_truthy(s:find("✶", 1, true))
    assert.is_truthy(s:find("▶", 1, true))
  end)

  it("pipeline fills the same height regardless of step count", function()
    local few = vim.tbl_extend("force", {}, fake, {
      steps = { { id = "a", label = "one" }, { id = "b", label = "two" } },
      statuses = { a = "done", b = "pending" },
    })
    assert.equals(16, #panes.pipeline_content(few, 44, 16))
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
