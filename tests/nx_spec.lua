local nx = require("ledger.builder.nx")

describe("ledger.builder.nx", function()
  local root
  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/.nx/workspace-data", "p")
    vim.fn.mkdir(root .. "/.nx/cache/terminalOutputs", "p")
    -- a dummy DB file so db_path() finds a target to query (content unused — the
    -- runner is injected, so no real sqlite3 is needed in CI)
    vim.fn.writefile({ "" }, root .. "/.nx/workspace-data/ABC.db")
  end)

  it("db_path globs the workspace-data UUID db", function()
    assert.is_truthy(nx.db_path(root):find("/.nx/workspace-data/ABC.db", 1, true))
    assert.is_nil(nx.db_path(vim.fn.tempname())) -- no .nx → nil
  end)

  it("build_result parses sqlite3's code|hash row (success)", function()
    local r = nx.build_result(root, "@ledgerhq/live-cli", function(_, sql)
      assert.is_truthy(sql:find("@ledgerhq/live-cli", 1, true))
      assert.is_truthy(sql:find("target = 'build'", 1, true))
      return "0|4548396293383635183\n"
    end)
    assert.same({ code = 0, hash = "4548396293383635183" }, r)
  end)

  it("build_result reports a non-zero exit code (failure)", function()
    local r = nx.build_result(root, "ledger-live-desktop", function()
      return "1|deadbeef"
    end)
    assert.equals(1, r.code)
    assert.equals("deadbeef", r.hash)
  end)

  it("build_result is nil with no row / no project / no db", function()
    assert.is_nil(nx.build_result(root, "x", function()
      return ""
    end))
    assert.is_nil(nx.build_result(root, nil, function()
      return "0|abc"
    end))
    -- a root without a .nx db never even calls the runner
    assert.is_nil(nx.build_result(vim.fn.tempname(), "x", function()
      error("runner should not run without a db")
    end))
  end)

  it("log_lines reads terminalOutputs/<hash> and strips ANSI", function()
    local hash = "777"
    vim.fn.writefile({
      "> nx run @ledgerhq/live-cli:build",
      "\27[32mBuilding bundled javascript\27[39m",
      "",
      "done",
    }, root .. "/.nx/cache/terminalOutputs/" .. hash)
    assert.same({
      "> nx run @ledgerhq/live-cli:build",
      "Building bundled javascript",
      "done",
    }, nx.log_lines(root, hash)) -- blank line dropped, SGR codes stripped
  end)

  it("log_lines is empty for a missing hash and caps to max", function()
    assert.same({}, nx.log_lines(root, "nope"))
    local many = {}
    for i = 1, 50 do
      many[i] = "line " .. i
    end
    vim.fn.writefile(many, root .. "/.nx/cache/terminalOutputs/big")
    assert.equals(10, #nx.log_lines(root, "big", 10))
  end)
end)
