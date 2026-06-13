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

  it("desktop and mobile have ordered steps", function()
    assert.is_true(#pipeline.steps("desktop") >= 5)
    assert.equals("deps", pipeline.steps("desktop")[1].id)
    assert.equals("report", pipeline.steps("mobile")[#pipeline.steps("mobile")].id)
  end)

  it("android swaps the device step proc", function()
    local function device(steps)
      for _, s in ipairs(steps) do
        if s.id == "device" then
          return s
        end
      end
    end
    assert.equals("ios_sim", device(pipeline.steps("mobile", { platform_flag = "ios" })).proc)
    assert.equals("android_emu", device(pipeline.steps("mobile", { platform_flag = "android" })).proc)
  end)

  it("daemon step status follows proc liveness", function()
    local metro = pipeline.steps("mobile")[5]
    assert.equals("metro", metro.id)
    assert.equals(
      "pending",
      pipeline.status(
        metro,
        ctx({
          proc_alive = function()
            return false
          end,
        })
      )
    )
    assert.equals(
      "done",
      pipeline.status(
        metro,
        ctx({
          proc_alive = function()
            return true
          end,
        })
      )
    )
  end)

  it("artifact step: pending / stale / done", function()
    local build
    for _, s in ipairs(pipeline.steps("mobile")) do
      if s.id == "build" then
        build = s
      end
    end
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

  it("step with no artifact/proc is ready", function()
    local libs = pipeline.steps("desktop")[2]
    assert.equals("libs", libs.id)
    assert.equals("ready", pipeline.status(libs, ctx()))
  end)

  it("resolves the detox-binary sentinel via ctx", function()
    local build
    for _, s in ipairs(pipeline.steps("mobile")) do
      if s.id == "build" then
        build = s
      end
    end
    local path = pipeline.resolve_artifact(build, ctx())
    assert.equals("/repo/apps/ledger-live-mobile/ios/build/x.app", path)
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

  it("renders all pane content without error", function()
    is_lines(panes.header(fake))
    is_lines(panes.pipeline_content(fake))
    is_lines(panes.processes_content(fake))
    is_lines(panes.logs_content(fake, 10))
    is_lines(panes.stats_content(fake, 40))
    is_lines(panes.wrong_folder_content())
    is_lines(panes.cheatsheet())
  end)

  it("header shows iOS/Android subtabs only on mobile", function()
    local mobile = panes.header(fake)
    -- mobile header has tabs line + subtab line + meta + blank (>=4)
    assert.is_true(#mobile >= 4)
    local desktop = panes.header(vim.tbl_extend("force", {}, fake, { platform = "desktop" }))
    assert.is_true(#desktop >= 3)
  end)

  it("pipeline shows one row per step", function()
    local lines = panes.pipeline_content(fake)
    assert.equals(#fake.steps, #lines)
  end)

  it("processes shows one row per process", function()
    local lines = panes.processes_content(fake)
    assert.equals(#fake.procs, #lines)
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
