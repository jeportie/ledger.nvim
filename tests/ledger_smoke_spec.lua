describe("ledger.nvim smoke", function()
  it("loads the top-level module", function()
    local ok, ledger = pcall(require, "ledger")
    assert.is_true(ok, "failed to require('ledger'): " .. tostring(ledger))
    assert.is_table(ledger)
  end)

  it("exposes setup()", function()
    local ledger = require("ledger")
    assert.is_function(ledger.setup)
  end)

  it("loads sub-modules without error", function()
    local mods = {
      "ledger.config",
      "ledger.jira.api",
      "ledger.jira.agile",
      "ledger.jira.config",
      "ledger.jira.util",
      "ledger.jira.icons",
      "ledger.jira.adf",
      "ledger.jira.board",
      "ledger.xray",
      "ledger.detox",
      "ledger.neotest",
    }
    for _, mod in ipairs(mods) do
      local ok, err = pcall(require, mod)
      assert.is_true(ok, ("failed to require(%q): %s"):format(mod, tostring(err)))
    end
  end)
end)