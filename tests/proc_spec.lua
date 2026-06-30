local proc = require("ledger.builder.proc")

-- Build a fake runner from a table of { [substring] = { code=, stdout= } }.
-- The first key found as a substring of the command wins.
local function fake_runner(rules)
  return function(cmd)
    for needle, result in pairs(rules) do
      if cmd:find(needle, 1, true) then
        return result
      end
    end
    return { code = 1, stdout = "" }
  end
end

-- Async equivalent: same rule table, but invokes `cb` (synchronously, so tests
-- stay deterministic — no event-loop pumping). Mirrors `default_async_runner`'s
-- (cmd, cb) shape.
local function fake_async_runner(rules)
  local sync = fake_runner(rules)
  return function(cmd, cb)
    cb(sync(cmd))
  end
end

describe("ledger.builder.proc", function()
  it("lists processes in registry order", function()
    local list = proc.list()
    assert.equals("metro", list[1])
    assert.is_truthy(vim.tbl_contains(list, "speculos"))
  end)

  describe("detect_cmd (pure)", function()
    it("builds a port probe", function()
      assert.equals("lsof -ti:8081 -sTCP:LISTEN", proc.detect_cmd("metro"))
      assert.equals("lsof -ti:8099 -sTCP:LISTEN", proc.detect_cmd("bridge"))
    end)

    it("builds a docker probe", function()
      assert.equals("docker ps --filter name=speculos --format '{{.ID}}'", proc.detect_cmd("speculos"))
    end)

    it("returns the raw probe for command-based entries", function()
      assert.equals("xcrun simctl list devices booted | grep -qi iphone", proc.detect_cmd("ios_sim"))
    end)

    it("returns nil for managed-only entries", function()
      assert.is_nil(proc.detect_cmd("dev_lld"))
    end)
  end)

  describe("stop_cmd (pure)", function()
    it("kills the port listener", function()
      assert.equals("lsof -ti:8081 | xargs kill -9", proc.stop_cmd("metro"))
    end)
    it("removes docker containers", function()
      assert.equals("docker rm -f $(docker ps -aq --filter name=speculos)", proc.stop_cmd("speculos"))
    end)
  end)

  describe("is_alive", function()
    it("port: alive when lsof returns a pid", function()
      assert.is_true(proc.is_alive("metro", fake_runner({ ["lsof -ti:8081"] = { code = 0, stdout = "54321\n" } })))
      assert.is_false(proc.is_alive("metro", fake_runner({ ["lsof -ti:8081"] = { code = 1, stdout = "" } })))
    end)

    it("docker: alive when a container id is returned", function()
      assert.is_true(proc.is_alive("speculos", fake_runner({ ["docker ps"] = { code = 0, stdout = "abc123\n" } })))
      assert.is_false(proc.is_alive("speculos", fake_runner({ ["docker ps"] = { code = 0, stdout = "" } })))
    end)

    it("probe: alive when the command exits 0", function()
      assert.is_true(proc.is_alive("ios_sim", fake_runner({ ["xcrun"] = { code = 0, stdout = "" } })))
      assert.is_false(proc.is_alive("ios_sim", fake_runner({ ["xcrun"] = { code = 1, stdout = "" } })))
    end)
  end)

  it("container_count counts docker lines", function()
    local r = fake_runner({ ["docker ps"] = { code = 0, stdout = "a\nb\nc\n" } })
    assert.equals(3, proc.container_count("speculos", r))
    assert.equals(0, proc.container_count("metro", r))
  end)

  it("status reports alive + port + count", function()
    local r = fake_runner({
      ["lsof -ti:8081"] = { code = 0, stdout = "111\n" },
      ["docker ps"] = { code = 0, stdout = "x\ny\n" },
    })
    local metro = proc.status("metro", r)
    assert.is_true(metro.alive)
    assert.equals(8081, metro.port)

    local spec = proc.status("speculos", r)
    assert.is_true(spec.alive)
    assert.equals(2, spec.count)
  end)

  it("status_all returns one entry per registered process", function()
    local r = fake_runner({})
    local all = proc.status_all(r)
    assert.equals(#proc.list(), #all)
  end)

  -- The synchronous injectable path is the unit-test contract; assert it still
  -- behaves exactly as before alongside the new async fan-out.
  it("the synchronous for_platform path is unchanged", function()
    local r = fake_runner({
      ["lsof -ti:8081"] = { code = 0, stdout = "111\n" }, -- metro alive
      ["lsof -ti:8099"] = { code = 1, stdout = "" }, -- bridge down
      ["docker ps"] = { code = 0, stdout = "abc\n" }, -- speculos alive (1 ctr)
      ["xcrun"] = { code = 1, stdout = "" }, -- ios_sim down
    })
    local list = proc.for_platform("mobile", "ios", r)
    assert.equals(4, #list)
    assert.equals("metro", list[1].name)
    assert.is_true(list[1].alive)
    assert.is_false(list[2].alive) -- bridge
    assert.is_true(list[3].alive) -- speculos
    assert.equals(1, list[3].count)
    assert.is_false(list[4].alive) -- ios_sim
  end)

  describe("for_platform_async", function()
    it("calls back with the platform's statuses, in order", function()
      local got
      proc.for_platform_async(
        "mobile",
        "ios",
        function(list)
          got = list
        end,
        fake_async_runner({
          ["lsof -ti:8081"] = { code = 0, stdout = "111\n" }, -- metro alive
          ["lsof -ti:8099"] = { code = 1, stdout = "" }, -- bridge down
          ["docker ps"] = { code = 0, stdout = "a\nb\n" }, -- speculos: 2 ctr
          ["xcrun"] = { code = 0, stdout = "" }, -- ios_sim alive (probe exit 0)
        })
      )
      assert.is_table(got)
      assert.equals(4, #got)
      assert.same({ "metro", "bridge", "speculos", "ios_sim" }, {
        got[1].name,
        got[2].name,
        got[3].name,
        got[4].name,
      })
      assert.is_true(got[1].alive) -- metro
      assert.is_false(got[2].alive) -- bridge
      assert.is_true(got[3].alive) -- speculos
      assert.equals(2, got[3].count)
      assert.is_true(got[4].alive) -- ios_sim
    end)

    it("matches the synchronous statuses for the same inputs", function()
      local rules = {
        ["docker ps"] = { code = 0, stdout = "x\n" }, -- speculos alive
      }
      local sync = proc.for_platform("desktop", nil, fake_runner(rules))
      local async
      proc.for_platform_async("desktop", nil, function(list)
        async = list
      end, fake_async_runner(rules))
      assert.equals(#sync, #async)
      for i = 1, #sync do
        assert.equals(sync[i].name, async[i].name)
        assert.equals(sync[i].alive, async[i].alive)
        assert.equals(sync[i].count, async[i].count)
      end
    end)

    it("resolves managed-only entries (dev_lld) to down without a probe", function()
      local probed = false
      proc.for_platform_async("desktop", nil, function(list)
        -- desktop = { speculos, dev_lld }; dev_lld has no detect_cmd
        local dev = list[2]
        assert.equals("dev_lld", dev.name)
        assert.is_false(dev.alive)
      end, function(cmd, cb)
        probed = cmd:find("docker", 1, true) ~= nil -- only speculos should probe
        cb({ code = 1, stdout = "" })
      end)
      assert.is_true(probed) -- speculos was probed; dev_lld was not
    end)
  end)
end)
