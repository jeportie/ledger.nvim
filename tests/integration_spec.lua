-- LOCAL integration tests — skipped unless LEDGER_LIVE_ROOT points at a real
-- ledger-live checkout. Run with:  LEDGER_LIVE_ROOT=~/src/…-ledger-live make test-integration
-- These verify (a) the Builder builds the SAME commands you'd run manually, (b)
-- against a pre-built checkout the Builder's pipeline states are correct, and
-- (c) external builds (run in another terminal) are read back from the Nx cache.

local templates = require("ledger.tasks.templates")
local pipeline = require("ledger.builder.pipeline")
local running = require("ledger.builder.running")
local nx = require("ledger.builder.nx")

local ROOT = os.getenv("LEDGER_LIVE_ROOT")

describe("ledger.builder integration", function()
  if not ROOT or ROOT == "" then
    it("is skipped without LEDGER_LIVE_ROOT", function()
      -- set LEDGER_LIVE_ROOT=… and run `make test-integration` for the real checks
      assert.is_true(true)
    end)
    return
  end
  ROOT = vim.fn.expand(ROOT)

  local function find(steps, id)
    for _, s in ipairs(steps) do
      if s.id == id then
        return s
      end
    end
  end

  -- the ordered shell commands the Builder's run-all would execute for a target
  -- (clean is now the first pipeline step, so just resolve every step in order)
  local function builder_cmds(platform, opts)
    local steps = pipeline.steps(platform, opts or {})
    local cmds = {}
    for _, s in ipairs(steps) do
      cmds[#cmds + 1] = templates.resolve(s.template, opts or {}, ROOT).cmd
    end
    return cmds
  end

  it("desktop run-all matches the manual build sequence", function()
    local cmds = builder_cmds("desktop", { desktop_build = "testing" })
    print("\n[builder] desktop run-all:\n  " .. table.concat(cmds, "\n  "))
    assert.equals("pnpm clean", cmds[1]) -- clean leads the pipeline
    assert.is_truthy(cmds[2]:find("^pnpm i")) -- install (scoped --filter superset of `pnpm i`)
    assert.equals("pnpm build:lld:deps", cmds[3])
    assert.equals("pnpm build:cli", cmds[4])
    assert.equals("pnpm desktop build:testing", cmds[5])
  end)

  it("ios/android run-all build commands match manual", function()
    local ios = builder_cmds("mobile", { platform_flag = "ios", config = "ios.sim.debug" })
    assert.equals("pnpm build:llm:deps", ios[3])
    assert.equals("pnpm build:cli", ios[4])
    assert.equals("pnpm mobile pod && pnpm mobile e2e:build -c ios.sim.debug", ios[#ios])
    local android = builder_cmds("mobile", { platform_flag = "android", config = "android.emu.release" })
    assert.equals("pnpm mobile e2e:build -c android.emu.release", android[#android])
  end)

  it("pipeline statuses reflect the real checkout (build it first)", function()
    local detox = require("ledger.detox")
    local staleness = require("ledger.builder.staleness")
    local uv = vim.uv or vim.loop
    local ctx = {
      root = ROOT,
      config = "ios.sim.debug",
      detox_binary = function(c)
        return detox.binary_paths[c]
      end,
      artifact_exists = function(p)
        return uv.fs_stat(p) ~= nil
      end,
      is_stale = function(p, s)
        return staleness.is_stale(p, s)
      end,
      proc_alive = function()
        return false
      end,
      last_result = function(step)
        -- libs/cli read their real done/failed from the Nx cache
        if step.nx_project then
          return nx.build_result(ROOT, step.nx_project)
        end
        return nil
      end,
    }
    for _, step in ipairs(pipeline.steps("desktop", { desktop_build = "testing" })) do
      local st = pipeline.status(step, ctx)
      print(string.format("  %-14s → %s", step.id, st))
      assert.is_truthy(st == "missing" or st == "needs_update" or st == "done" or st == "failed")
    end
    -- after a `pnpm i`, the install artifact step should not be "missing"
    if uv.fs_stat(ROOT .. "/node_modules/.modules.yaml") then
      assert.is_not.equal("missing", pipeline.status(find(pipeline.steps("desktop"), "install"), ctx))
    end
  end)

  it("reads libs/cli build status + log straight from the Nx cache", function()
    local db = nx.db_path(ROOT)
    if not db then
      print("  (no .nx workspace db — build the repo first; skipping)")
      return
    end
    for _, proj in ipairs({ "ledger-live-desktop", "@ledgerhq/live-cli" }) do
      local r = nx.build_result(ROOT, proj)
      if r then
        print(string.format("  %-22s → code=%d hash=%s", proj, r.code, r.hash))
        assert.is_number(r.code)
        assert.is_string(r.hash)
        assert.is_table(nx.log_lines(ROOT, r.hash, 50)) -- the captured terminal log
      else
        print("  " .. proj .. " → no build recorded yet (or no sqlite3)")
      end
    end
  end)

  -- `sleep 4; : # <marker>` — the trailing `; :` stops macOS `/bin/sh -c` from
  -- exec-optimizing into a bare `sleep` (which would drop the marker from `ps`).
  it("detects a build command running in another process (cross-session)", function()
    local steps = pipeline.steps("desktop")
    local job = vim.fn.jobstart({ "sh", "-c", "sleep 4; : # pnpm build:cli marker" })
    vim.wait(600)
    assert.is_true(running.running_steps(steps).cli == true) -- real `ps` scan
    pcall(vim.fn.jobstop, job)
  end)

  it("detects a live `pnpm i` as the install step (the cross-terminal fix)", function()
    local steps = pipeline.steps("desktop")
    -- pnpm runs as the proto shim → node …/pnpm.cjs i; the pattern must catch it
    local job = vim.fn.jobstart({ "sh", "-c", "sleep 4; : # node /r/pnpm.cjs i --filter=x" })
    vim.wait(600)
    assert.is_true(running.running_steps(steps).install == true)
    pcall(vim.fn.jobstop, job)
  end)
end)
