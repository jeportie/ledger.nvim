local history = require("ledger.builder.history")
local tasks = require("ledger.tasks")

-- Run-log persistence: history.write_log / log_lines round-trip, prune deletes
-- evicted sidecars, and the injected log is readable back through tasks.
describe("ledger.builder.history run logs", function()
  before_each(function()
    history._reset() -- clears entries JSON + wipes the log dir
  end)

  it("write_log persists a file that log_lines reads back", function()
    local lines = { "line one", "line two", "✓ done" }
    local p = history.write_log(1000, "desktop.build", lines)
    assert.is_string(p)
    assert.equals(1, vim.fn.filereadable(p))

    local e = history.record({ label = "build", kind = "build", code = 0, duration = 3, log = p })
    assert.same(lines, history.log_lines(e))
  end)

  it("survives across sessions: log_lines reads the sidecar from disk", function()
    -- A run's log lives in a file (not memory), so a NEW nvim session — whose
    -- recent() yields plain entry tables carrying the `log` path — reads it back
    -- via log_lines. We model that entry directly (no dependence on the shared
    -- global history file, which parallel specs race on).
    local p = history.write_log(1001, "mobile.detox.test", { "session A output", "✓ passed" })
    assert.is_string(p)
    local entry = { time = 1001, label = "e2e", kind = "test", code = 0, log = p }
    assert.same({ "session A output", "✓ passed" }, history.log_lines(entry))
  end)

  it("sanitizes the id into the sidecar filename", function()
    local p = history.write_log(1002, "shared.nx.build:some/proj@x", { "x" })
    assert.is_string(p)
    -- non-alphanumerics collapse to _, so the basename stays filesystem-safe
    local base = vim.fn.fnamemodify(p, ":t")
    assert.equals("1002-shared_nx_build_some_proj_x.log", base)
  end)

  it("write_log returns nil for empty output", function()
    assert.is_nil(history.write_log(1003, "noop", {}))
    assert.is_nil(history.write_log(1003, "noop", nil))
  end)

  it("log_lines returns {} for an entry without a log or a missing file", function()
    assert.same({}, history.log_lines({ label = "no-log" }))
    assert.same({}, history.log_lines({ label = "gone", log = history._log_dir() .. "/does-not-exist.log" }))
  end)

  it("pruning beyond MAX deletes the evicted run's sidecar", function()
    -- MAX is 100. Seed a full in-memory list of 100 entries (the first carries a
    -- real sidecar), then record ONE more so entry #1 is evicted. Seeding the
    -- cache directly keeps this to a single disk write (parallel specs share the
    -- global history file) while still exercising the eviction path in record().
    local first_path = history.write_log(2000, "build0", { "oldest run" })
    assert.equals(1, vim.fn.filereadable(first_path))

    local seeded = { { time = 2000, label = "build0", kind = "build", code = 0, log = first_path } }
    for i = 1, 99 do
      seeded[#seeded + 1] = { time = 2000 + i, label = "b" .. i, kind = "build", code = 0 }
    end
    history._entries = seeded
    assert.equals(100, #history._entries)

    history.record({ time = 3000, label = "newest", kind = "build", code = 0 })

    local all = history.recent(1000)
    assert.equals(100, #all) -- still capped at MAX
    assert.equals("b1", all[1].label) -- entry #1 (build0) evicted; b1 is now oldest
    assert.equals("newest", all[#all].label)
    assert.equals(0, vim.fn.filereadable(first_path)) -- evicted sidecar removed
  end)

  it("the loaded log is readable back through tasks (reopen UX path)", function()
    -- Mirrors what the controller does on pick: read the saved log, inject it
    -- under a synthetic id, then the Logs pane reads it via tasks.log_window.
    local saved = { "old build step 1", "old build step 2", "✗ failed (exit 1)" }
    local p = history.write_log(3000, "desktop.build", saved)
    local e = history.record({ time = 3000, label = "build", kind = "build", code = 1, duration = 4, log = p })

    local lines = history.log_lines(e)
    tasks.inject("history:3000:build", lines, e.code)
    assert.same(saved, tasks.log_window("history:3000:build", 0, 100))
    assert.same({ code = 1, duration = 0 }, tasks.last_result("history:3000:build"))
  end)
end)
