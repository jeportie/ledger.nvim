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

  it("run_meta filters by project and orders task hashes by startTime", function()
    local run = {
      run = { command = "nx run-many -t build -p @ledgerhq/live-cli", endTime = "2026-06-26T07:37:09Z" },
      tasks = {
        { hash = "b", startTime = "2026-06-26T07:37:02Z" },
        { hash = "a", startTime = "2026-06-26T07:37:01Z" },
        { hash = "c", startTime = "2026-06-26T07:37:03Z" },
      },
    }
    vim.fn.writefile({ vim.json.encode(run) }, root .. "/.nx/cache/run.json")
    local meta = nx.run_meta(root, "@ledgerhq/live-cli")
    assert.same({ "a", "b", "c" }, meta.hashes) -- ordered by startTime
    assert.equals("2026-06-26T07:37:09Z", meta.id)
    -- the latest run was a different project → nil (caller falls back to leaf)
    assert.is_nil(nx.run_meta(root, "ledger-live-desktop"))
  end)

  it("run_meta is nil when there's no run.json", function()
    assert.is_nil(nx.run_meta(vim.fn.tempname(), "x"))
  end)

  it("concat_logs joins multiple task logs (ANSI-stripped) and caps to max", function()
    vim.fn.writefile({ "> nx run a:build", "\27[32mok A\27[39m" }, root .. "/.nx/cache/terminalOutputs/a")
    vim.fn.writefile({ "> nx run b:build", "ok B" }, root .. "/.nx/cache/terminalOutputs/b")
    assert.same({ "> nx run a:build", "ok A", "> nx run b:build", "ok B" }, nx.concat_logs(root, { "a", "b" }))
    assert.equals(2, #nx.concat_logs(root, { "a", "b" }, 2)) -- cap keeps the tail across files
    assert.same({}, nx.concat_logs(root, {}))
  end)

  it("projects parses project-graph.json (name → root, longest root first)", function()
    local graph = {
      nodes = {
        ["@ledgerhq/live-common"] = { data = { root = "libs/ledger-live-common" } },
        ["ledger-live-desktop"] = { data = { root = "apps/ledger-live-desktop" } },
        ["@ledgerhq/types-live"] = { data = { root = "libs/ledgerjs/packages/types-live" } },
      },
    }
    vim.fn.writefile({ vim.json.encode(graph) }, root .. "/.nx/workspace-data/project-graph.json")
    local list = nx.projects(root)
    assert.equals(3, #list)
    assert.equals("libs/ledgerjs/packages/types-live", list[1].root) -- longest first
    assert.same({}, nx.projects(vim.fn.tempname())) -- no graph → empty
  end)

  it("project_for_file maps a path to its owning project (longest prefix)", function()
    local graph = {
      nodes = {
        ["@ledgerhq/live-common"] = { data = { root = "libs/ledger-live-common" } },
        ["root-proj"] = { data = { root = "." } },
      },
    }
    vim.fn.writefile({ vim.json.encode(graph) }, root .. "/.nx/workspace-data/project-graph.json")
    assert.equals(
      "@ledgerhq/live-common",
      nx.project_for_file(root, root .. "/libs/ledger-live-common/src/e2e/swap.ts")
    )
    assert.is_nil(nx.project_for_file(root, root .. "/README.md")) -- root-"." doesn't claim it
    assert.is_nil(nx.project_for_file(root, "/elsewhere/foo.ts")) -- outside the repo
  end)

  it("buildable_project_for_file gates on a build target", function()
    local graph = {
      nodes = {
        ["@ledgerhq/live-common"] = { data = { root = "libs/ledger-live-common", targets = { build = {} } } },
        ["e2e-tests"] = { data = { root = "tests/e2e", targets = { lint = {} } } }, -- no build
      },
    }
    vim.fn.writefile({ vim.json.encode(graph) }, root .. "/.nx/workspace-data/project-graph.json")
    assert.equals(
      "@ledgerhq/live-common",
      nx.buildable_project_for_file(root, root .. "/libs/ledger-live-common/src/x.ts")
    )
    -- a non-buildable project's file → nil (no junk sub-step on save)
    assert.is_nil(nx.buildable_project_for_file(root, root .. "/tests/e2e/foo.ts"))
    -- project_for_file still returns it regardless of targets
    assert.equals("e2e-tests", nx.project_for_file(root, root .. "/tests/e2e/foo.ts"))
  end)
end)
