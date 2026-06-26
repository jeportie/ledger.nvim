local store = require("ledger.builder.store")

describe("ledger.builder.store", function()
  before_each(function()
    store._reset()
  end)

  it("round-trips a result per repo + template", function()
    store.record("/repo/a", "desktop.build.cli", 0, 42)
    local r = store.get("/repo/a")["desktop.build.cli"]
    assert.equals(0, r.code)
    assert.equals(42, r.duration)
    assert.is_number(r.time)
  end)

  it("isolates repos and returns {} for unknown / nil", function()
    store.record("/repo/a", "x", 0, 1)
    assert.same({}, store.get("/repo/b"))
    assert.same({}, store.get(nil))
  end)

  it("re-reads the file each get (sees a concurrent external write)", function()
    store.record("/repo/a", "x", 0, 1)
    -- simulate another vim/terminal session writing directly to the file
    local p = store._path()
    local data = vim.json.decode(table.concat(vim.fn.readfile(p), "\n"))
    data["/repo/a"]["y"] = { code = 1, duration = 9, time = os.time() }
    vim.fn.writefile({ vim.json.encode(data) }, p)
    -- a fresh get reflects it (no stale in-memory cache, unlike history.lua)
    assert.equals(9, store.get("/repo/a")["y"].duration)
  end)
end)
