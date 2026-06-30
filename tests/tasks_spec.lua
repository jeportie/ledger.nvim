local templates = require("ledger.tasks.templates")

local ROOT = "/repo"

describe("ledger.tasks.templates", function()
  it("resolves a simple desktop build with env and artifact", function()
    local spec = templates.resolve("desktop.build.testing", {}, ROOT)
    assert.equals("desktop.build.testing", spec.id)
    assert.equals("pnpm desktop build:testing", spec.cmd)
    assert.equals("/repo", spec.cwd)
    assert.equals("1", spec.env.TESTING)
    assert.equals("/repo/apps/ledger-live-desktop/.webpack/main.bundle.js", spec.artifact)
    assert.is_false(spec.daemon)
  end)

  it("runs every template from the repo root (root-alias convention)", function()
    -- mobile.detox.test runs the leaf `detox test` from e2e/mobile (one shell
    -- parse keeps the -t "name" quoting intact) — the lone non-root template.
    for _, id in ipairs(templates.ids()) do
      if id ~= "mobile.detox.test" then
        assert.equals(ROOT, templates.resolve(id, {}, ROOT).cwd, id .. " should run from repo root")
      end
    end
    assert.equals(ROOT .. "/e2e/mobile", templates.resolve("mobile.detox.test", {}, ROOT).cwd)
  end)

  it("resolve_cwd still maps the workspace symbols (for future use)", function()
    assert.equals("/repo", templates.resolve_cwd("repo", ROOT))
    assert.equals("/repo/e2e/desktop", templates.resolve_cwd("e2e_desktop", ROOT))
    assert.equals("/repo/e2e/mobile", templates.resolve_cwd("e2e_mobile", ROOT))
    assert.equals("/repo/apps/ledger-live-mobile", templates.resolve_cwd("mobile_app", ROOT))
    assert.equals("/repo", templates.resolve_cwd(nil, ROOT))
  end)

  it("marks daemons", function()
    assert.is_true(templates.resolve("mobile.metro", {}, ROOT).daemon)
    assert.is_true(templates.resolve("desktop.dev", {}, ROOT).daemon)
    assert.is_false(templates.resolve("mobile.pod", {}, ROOT).daemon)
  end)

  it("installs run non-interactively (no TTY → confirm-modules-purge=false)", function()
    for _, id in ipairs({ "desktop.install", "mobile.install" }) do
      local cmd = templates.resolve(id, {}, ROOT).cmd
      assert.is_truthy(cmd:find("^pnpm i"), id .. " should still start with `pnpm i`")
      assert.is_truthy(
        cmd:find("--config.confirm-modules-purge=false", 1, true),
        id .. " should pass --config.confirm-modules-purge=false"
      )
    end
  end)

  it("targeted build template builds only the named projects (excludes deps)", function()
    assert.equals(
      "pnpm nx run-many -t build -p @ledgerhq/live-common @ledgerhq/coin-evm --excludeTaskDependencies",
      templates.resolve("shared.nx.build", { projects = { "@ledgerhq/live-common", "@ledgerhq/coin-evm" } }, ROOT).cmd
    )
    assert.equals(
      "pnpm nx run-many -t build -p @ledgerhq/coin-* --excludeTaskDependencies",
      templates.resolve("shared.nx.build", { filter = "@ledgerhq/coin-*" }, ROOT).cmd
    )
    -- install-targeting was dropped (pnpm installs are workspace-wide)
    assert.is_nil(templates.by_id["shared.install.scoped"])
  end)

  describe("parametric commands", function()
    it("detox build prefixes pod for iOS only", function()
      assert.equals(
        "pnpm mobile pod && pnpm mobile e2e:build -c ios.sim.debug",
        templates.resolve("mobile.detox.build", { config = "ios.sim.debug" }, ROOT).cmd
      )
      assert.equals(
        "pnpm mobile e2e:build -c android.emu.release",
        templates.resolve("mobile.detox.build", { config = "android.emu.release" }, ROOT).cmd
      )
    end)

    it("detox test runs the leaf `detox test` with --configuration and applies scope", function()
      -- all: just the configuration, no jest filter
      assert.equals(
        "pnpm detox test --configuration ios.sim.debug",
        templates.resolve("mobile.detox.test", { config = "ios.sim.debug", scope = "all" }, ROOT).cmd
      )
      -- file: --testPathPattern
      assert.equals(
        "pnpm detox test --configuration ios.sim.debug --testPathPattern specs/swap/x.spec.ts",
        templates.resolve(
          "mobile.detox.test",
          { config = "ios.sim.debug", scope = "file", spec = "specs/swap/x.spec.ts" },
          ROOT
        ).cmd
      )
      -- name with spaces stays ONE quoted -t token (the bug we fixed)
      assert.equals(
        'pnpm detox test --configuration ios.sim.debug -t "Checks if the amount is hidden in the asset drawer"',
        templates.resolve("mobile.detox.test", {
          config = "ios.sim.debug",
          scope = "name",
          name = "Checks if the amount is hidden in the asset drawer",
        }, ROOT).cmd
      )
    end)

    it("detox test passes any configuration straight through (no script map)", function()
      assert.equals(
        "pnpm detox test --configuration ios.sim.prerelease",
        templates.resolve("mobile.detox.test", { config = "ios.sim.prerelease" }, ROOT).cmd
      )
      assert.equals(
        "pnpm detox test --configuration android.emu.release",
        templates.resolve("mobile.detox.test", { config = "android.emu.release", scope = "all" }, ROOT).cmd
      )
    end)

    it("playwright run supports scope + PWDEBUG", function()
      assert.equals("pnpm e2e:desktop test:playwright", templates.resolve("desktop.pw.run", {}, ROOT).cmd)
      assert.equals(
        "pnpm e2e:desktop test:playwright settings.spec.ts",
        templates.resolve("desktop.pw.run", { scope = "file", spec = "settings.spec.ts" }, ROOT).cmd
      )
      assert.equals(
        'pnpm e2e:desktop test:playwright --grep "@NanoSP"',
        templates.resolve("desktop.pw.run", { scope = "name", name = "@NanoSP" }, ROOT).cmd
      )
      assert.equals(
        "PWDEBUG=1 pnpm e2e:desktop test:playwright",
        templates.resolve("desktop.pw.run", { pwdebug = true }, ROOT).cmd
      )
      assert.equals(
        "MOCK=1 pnpm e2e:desktop test:playwright",
        templates.resolve("desktop.pw.run", { mock = true }, ROOT).cmd
      )
      assert.equals(
        "MOCK=1 PWDEBUG=1 pnpm e2e:desktop test:playwright",
        templates.resolve("desktop.pw.run", { mock = true, pwdebug = true }, ROOT).cmd
      )
    end)

    it("clean / fix templates", function()
      assert.equals("pnpm clean", templates.resolve("shared.clean", {}, ROOT).cmd)
      assert.equals("rm -rf node_modules && pnpm store prune && pnpm i", templates.resolve("fix.global", {}, ROOT).cmd)
      assert.is_truthy(templates.resolve("fix.ios_pod", {}, ROOT).cmd:find("pnpm mobile pod", 1, true))
    end)

    it("lib watch defaults and overrides the package", function()
      assert.equals(
        "pnpm --filter @ledgerhq/live-common run watch",
        templates.resolve("shared.lib.watch", {}, ROOT).cmd
      )
      assert.equals(
        "pnpm --filter @ledgerhq/coin-evm run watch",
        templates.resolve("shared.lib.watch", { lib = "@ledgerhq/coin-evm" }, ROOT).cmd
      )
    end)
  end)

  it("errors on unknown id", function()
    local spec, err = templates.resolve("nope.nope", {}, ROOT)
    assert.is_nil(spec)
    assert.is_truthy(err:find("unknown template"))
  end)

  it("filters ids by platform (shared always included)", function()
    local desktop = templates.ids("desktop")
    local function has(list, id)
      for _, v in ipairs(list) do
        if v == id then
          return true
        end
      end
      return false
    end
    assert.is_true(has(desktop, "desktop.build.testing"))
    assert.is_true(has(desktop, "shared.lib.watch"))
    assert.is_false(has(desktop, "mobile.metro"))
  end)
end)

describe("ledger.tasks runtime", function()
  local tasks = require("ledger.tasks")

  it("strip_ansi removes colour + cursor CSI and carriage returns", function()
    assert.equals("File (cjs)  Size", tasks.strip_ansi("\27[34mFile (cjs)\27[39m  Size\r"))
    assert.equals("plain", tasks.strip_ansi("plain"))
    assert.equals("", tasks.strip_ansi("\27[2K"))
  end)

  it("log_window slices a window ending `offset` lines from the newest", function()
    tasks.tasks["spec.win"] = { lines = {} }
    for i = 1, 20 do
      tasks.tasks["spec.win"].lines[i] = "L" .. i
    end
    assert.same({ "L18", "L19", "L20" }, tasks.log_window("spec.win", 0, 3))
    assert.same({ "L8", "L9", "L10" }, tasks.log_window("spec.win", 10, 3))
    assert.equals(20, tasks.log_len("spec.win"))
    assert.same({}, tasks.log_window("nope", 0, 3))
    tasks.tasks["spec.win"] = nil
  end)
end)
