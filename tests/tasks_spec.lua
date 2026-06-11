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

    it("detox test maps known configs to wrappers and appends spec", function()
      assert.equals(
        "pnpm e2e:mobile test:ios:debug",
        templates.resolve("mobile.detox.test", { config = "ios.sim.debug" }, ROOT).cmd
      )
      assert.equals(
        "pnpm e2e:mobile test:android",
        templates.resolve("mobile.detox.test", { config = "android.emu.release" }, ROOT).cmd
      )
      assert.equals(
        "pnpm e2e:mobile test:ios:debug send.spec.ts",
        templates.resolve("mobile.detox.test", { config = "ios.sim.debug", spec = "send.spec.ts" }, ROOT).cmd
      )
    end)

    it("detox test falls back to generic detox for unknown configs", function()
      assert.equals(
        "pnpm e2e:mobile test:detox -- -c ios.sim.prerelease",
        templates.resolve("mobile.detox.test", { config = "ios.sim.prerelease" }, ROOT).cmd
      )
    end)

    it("playwright run supports spec / grep / shard", function()
      assert.equals("pnpm e2e:desktop test:playwright", templates.resolve("desktop.pw.run", {}, ROOT).cmd)
      assert.equals(
        "pnpm e2e:desktop test:playwright settings.spec.ts",
        templates.resolve("desktop.pw.run", { spec = "settings.spec.ts" }, ROOT).cmd
      )
      assert.equals(
        'pnpm e2e:desktop test:playwright --grep "@NanoSP"',
        templates.resolve("desktop.pw.run", { grep = "@NanoSP" }, ROOT).cmd
      )
      assert.equals(
        "pnpm e2e:desktop test:playwright --shard=1/4",
        templates.resolve("desktop.pw.run", { shard = "1/4" }, ROOT).cmd
      )
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
