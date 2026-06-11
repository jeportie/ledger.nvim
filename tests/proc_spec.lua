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
end)
