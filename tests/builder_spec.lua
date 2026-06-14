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
