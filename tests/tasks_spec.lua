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
    for _, id in ipairs(templates.ids()) do
      assert.equals(ROOT, templates.resolve(id, {}, ROOT).cwd, id .. " should run from repo root")
    end
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
    it("detox build no longer prefixes pod (mobile.pod is its own step)", function()
      local ios = templates.resolve("mobile.detox.build", { config = "ios.sim.debug" }, ROOT).cmd
      assert.equals("pnpm mobile e2e:build -c ios.sim.debug", ios)
      assert.is_nil(ios:find("pnpm mobile pod", 1, true))
      assert.equals(
        "pnpm mobile e2e:build -c android.emu.release",
        templates.resolve("mobile.detox.build", { config = "android.emu.release" }, ROOT).cmd
      )
    end)

    it("run-app templates launch the native app without tests", function()
      assert.equals("pnpm mobile ios", templates.resolve("mobile.run.ios", {}, ROOT).cmd)
      assert.equals("pnpm mobile android", templates.resolve("mobile.run.android", {}, ROOT).cmd)
      assert.equals("pnpm mobile ios:staging", templates.resolve("mobile.run.ios.staging", {}, ROOT).cmd)
      assert.equals("pnpm mobile staging-android", templates.resolve("mobile.run.android.staging", {}, ROOT).cmd)
      -- desktop production always rebuilds the prod bundle (build:js), then runs it
      assert.equals(
        "pnpm desktop build:js && pnpm desktop start:prod",
        templates.resolve("desktop.run.prod", {}, ROOT).cmd
      )
      -- iOS simulator log stream is a daemon scoped to the app process
      local simlogs = templates.resolve("mobile.sim.logs", {}, ROOT)
      assert.is_true(simlogs.daemon)
      assert.is_truthy(simlogs.cmd:find("simctl", 1, true))
      assert.is_truthy(simlogs.cmd:find("log stream", 1, true))
      assert.is_truthy(simlogs.cmd:find("ledgerlivemobile", 1, true))
      -- speculos container logs (daemon)
      local spec = templates.resolve("speculos.logs", {}, ROOT)
      assert.is_true(spec.daemon)
      assert.is_truthy(spec.cmd:find("docker logs", 1, true))
      assert.is_truthy(spec.cmd:find("name=speculos", 1, true))
    end)

    it("detox test maps configs to scripts and applies scope", function()
      assert.equals(
        "pnpm e2e:mobile test:ios:debug",
        templates.resolve("mobile.detox.test", { config = "ios.sim.debug", scope = "all" }, ROOT).cmd
      )
      assert.equals(
        "pnpm e2e:mobile test:android",
        templates.resolve("mobile.detox.test", { config = "android.emu.release", scope = "all" }, ROOT).cmd
      )
      assert.equals(
        "pnpm e2e:mobile test:ios:debug -- --testPathPattern specs/swap/x.spec.ts",
        templates.resolve(
          "mobile.detox.test",
          { config = "ios.sim.debug", scope = "file", spec = "specs/swap/x.spec.ts" },
          ROOT
        ).cmd
      )
      assert.equals(
        'pnpm e2e:mobile test:android -- -t "B2CQA-604"',
        templates.resolve(
          "mobile.detox.test",
          { config = "android.emu.release", scope = "name", name = "B2CQA-604" },
          ROOT
        ).cmd
      )
    end)

    it("detox test falls back to generic detox for unknown configs", function()
      assert.equals(
        "pnpm e2e:mobile test:detox -- -c ios.sim.prerelease",
        templates.resolve("mobile.detox.test", { config = "ios.sim.prerelease" }, ROOT).cmd
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
      local sim = templates.resolve("fix.ios_sim", {}, ROOT).cmd
      assert.is_truthy(sim:find("simctl", 1, true)) -- creates/boots via simctl
      assert.is_truthy(sim:find('"iOS Simulator"', 1, true)) -- detox's device name
      assert.is_truthy(sim:find("xcodebuild -downloadPlatform iOS", 1, true)) -- install hint
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
