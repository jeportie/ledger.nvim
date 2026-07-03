local running = require("ledger.builder.running")
local pipeline = require("ledger.builder.pipeline")

describe("ledger.builder.running.running_steps", function()
  local desktop = pipeline.steps("desktop", { desktop_build = "testing" })
  local ios = pipeline.steps("mobile", { platform_flag = "ios" })
  -- Unscoped matching (root=nil): the legacy whole-listing behaviour.
  local function scan(steps, listing)
    return running.running_steps(steps, nil, function()
      return listing
    end)
  end

  it("flags a step whose command pattern appears in the process listing", function()
    local r = scan(desktop, "/bin/zsh\nnode pnpm.cjs build:lld:deps\nnvim\n")
    assert.is_true(r.libs)
    assert.is_nil(r.cli)
    assert.is_nil(r.install)
    assert.is_nil(r.build)
    assert.is_nil(r.clean)
  end)

  it("matches install across pnpm spellings (the cross-terminal bug)", function()
    -- `pnpm i` runs as the proto shim → `node …/pnpm.cjs i`; the old plain
    -- substring "pnpm i" missed those. The "pnpm%S* i" pattern catches them all.
    assert.is_true(scan(desktop, "pnpm i --filter=ledger-live-desktop").install)
    assert.is_true(scan(desktop, "node /repo/node_modules/.bin/pnpm.cjs i").install)
    assert.is_true(scan(desktop, "/Users/x/.proto/shims/pnpm i").install)
    assert.is_true(scan(desktop, "pnpm install").install)
  end)

  it("matches cli / desktop build signatures", function()
    assert.is_true(scan(desktop, "pnpm build:cli").cli)
    assert.is_true(scan(desktop, "pnpm desktop build:testing").build)
  end)

  it("matches clean as `pnpm clean` OR the underlying `git clean`", function()
    assert.is_true(scan(desktop, "pnpm clean").clean)
    assert.is_true(scan(desktop, "node pnpm.cjs clean").clean)
    assert.is_true(scan(desktop, "git clean -fdX").clean)
  end)

  it("install pattern doesn't cross-match build commands", function()
    local r = scan(desktop, "pnpm build:lld:deps")
    assert.is_nil(r.install)
    assert.is_true(r.libs)
  end)

  it("matches the iOS detox build (e2e:build) and pod step", function()
    assert.is_true(scan(ios, "pnpm mobile e2e:build -c ios.sim.debug").build)
    assert.is_true(scan(ios, "pnpm mobile pod && pnpm mobile e2e:build -c ios.sim.debug").pod)
  end)

  it("returns an empty set when nothing matches", function()
    assert.same({}, scan(desktop, "/bin/zsh\nnvim\n/usr/bin/ssh-agent\n"))
    assert.same({}, scan(desktop, ""))
  end)
end)

-- #61: with two ledger-live checkouts open, a build in repo A must not show as
-- in-progress in repo B. When a `root` is given, a matched process only counts
-- if its cwd is under that root.
describe("ledger.builder.running root-scoping", function()
  local desktop = pipeline.steps("desktop", { desktop_build = "testing" })
  local ios = pipeline.steps("mobile", { platform_flag = "ios" })
  -- listing is "<pid> <command>" lines; cwds maps pid → the process's cwd.
  local function scan_root(steps, root, listing, cwds)
    return running.running_steps(steps, root, function()
      return listing
    end, function(pid)
      return cwds[pid]
    end)
  end

  it("flags a matched command only when its process cwd is under root", function()
    local listing = "111 pnpm desktop build:testing\n222 nvim\n"
    -- same command, two repos: flagged under repoA, NOT under repoB (the bug)
    assert.is_true(scan_root(desktop, "/src/repoA", listing, { ["111"] = "/src/repoA/apps/ledger-live-desktop" }).build)
    assert.is_nil(scan_root(desktop, "/src/repoA", listing, { ["111"] = "/src/repoB/apps/ledger-live-desktop" }).build)
  end)

  it("scopes the generic install pattern per repo", function()
    local listing = "500 pnpm i --filter=ledger-live-desktop\n"
    assert.is_true(scan_root(desktop, "/src/repoA", listing, { ["500"] = "/src/repoA" }).install)
    assert.is_nil(scan_root(desktop, "/src/repoA", listing, { ["500"] = "/src/repoB" }).install)
  end)

  it("scopes the mobile detox build per repo", function()
    local listing = "77 pnpm mobile e2e:build -c ios.sim.debug\n"
    assert.is_true(scan_root(ios, "/src/repoA", listing, { ["77"] = "/src/repoA/apps/ledger-live-mobile" }).build)
    assert.is_nil(scan_root(ios, "/src/repoA", listing, { ["77"] = "/src/repoB" }).build)
  end)

  it("treats the root itself as under-root (exact match)", function()
    assert.is_true(scan_root(desktop, "/src/repoA", "9 pnpm clean\n", { ["9"] = "/src/repoA" }).clean)
  end)

  it("does not flag a match whose cwd can't be resolved (fails safe)", function()
    assert.is_nil(scan_root(desktop, "/src/repoA", "111 pnpm build:cli\n", {}).cli)
  end)

  it("a sibling path sharing a prefix is not treated as under root", function()
    -- /src/repoA-2 must not count as under /src/repoA
    assert.is_nil(scan_root(desktop, "/src/repoA", "111 pnpm build:cli\n", { ["111"] = "/src/repoA-2" }).cli)
  end)
end)

describe("ledger.builder.running TTL memo", function()
  local ios = pipeline.steps("mobile", { platform_flag = "ios" })

  after_each(function()
    running._set_default_runner(nil) -- restore the real `ps` scan + clear memo
  end)

  it("reuses the listing within the window (one ps scan for two calls)", function()
    local calls = 0
    running._set_default_runner(function()
      calls = calls + 1
      return "pnpm mobile e2e:build -c ios.sim.debug\n"
    end)
    -- both calls take the memoised default path (no runner arg)
    local r1 = running.running_steps(ios)
    local r2 = running.running_steps(ios)
    assert.equals(1, calls) -- second call served from the memo
    assert.is_true(r1.build)
    assert.is_true(r2.build) -- same listing → same result
  end)

  it("re-scans after the memo is invalidated", function()
    local calls = 0
    running._set_default_runner(function()
      calls = calls + 1
      return ""
    end)
    running.running_steps(ios)
    running.invalidate()
    running.running_steps(ios)
    assert.equals(2, calls) -- invalidation forces a fresh scan
  end)

  it("an explicitly-injected runner always bypasses the memo", function()
    local calls = 0
    -- prime the memo via the default path
    running._set_default_runner(function()
      return ""
    end)
    running.running_steps(ios)
    -- an injected runner must still run (existing unit tests depend on this)
    running.running_steps(ios, nil, function()
      calls = calls + 1
      return "pnpm mobile e2e:build -c ios.sim.debug\n"
    end)
    assert.equals(1, calls)
  end)
end)
