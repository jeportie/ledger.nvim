local running = require("ledger.builder.running")
local pipeline = require("ledger.builder.pipeline")

describe("ledger.builder.running.running_steps", function()
  local desktop = pipeline.steps("desktop", { desktop_build = "testing" })
  local ios = pipeline.steps("mobile", { platform_flag = "ios" })
  local function scan(steps, listing)
    return running.running_steps(steps, function()
      return listing
    end)
  end

  it("flags a step whose command substring appears in the process listing", function()
    local r = scan(desktop, "/bin/zsh\nnode pnpm.cjs build:lld:deps\nnvim\n")
    assert.is_true(r.libs)
    assert.is_nil(r.cli)
    assert.is_nil(r.install)
    assert.is_nil(r.build)
  end)

  it("matches install / cli / desktop build signatures", function()
    assert.is_true(scan(desktop, "pnpm i --filter=ledger-live-desktop").install)
    assert.is_true(scan(desktop, "pnpm build:cli").cli)
    assert.is_true(scan(desktop, "pnpm desktop build:testing").build)
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
