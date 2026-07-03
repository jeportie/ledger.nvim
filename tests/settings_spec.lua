local settings = require("ledger.builder.settings")

describe("ledger.builder.settings", function()
  before_each(function()
    settings._reset()
  end)

  it("returns nil for an unset key", function()
    assert.is_nil(settings.get("border"))
  end)

  it("set persists a value and get reads it back", function()
    settings.set("border", true)
    assert.is_true(settings.get("border"))
    settings.set("animation", "minimal")
    assert.equals("minimal", settings.get("animation"))
  end)

  it("set(nil) clears an override so the config default takes over", function()
    settings.set("border", true)
    settings.set("border", nil)
    assert.is_nil(settings.get("border"))
  end)

  it("persists across a cache reload", function()
    settings.set("transparent", true)
    settings._overrides = nil -- force reload from disk
    assert.is_true(settings.get("transparent"))
  end)

  it("stores only overridden keys (minimal file)", function()
    settings.set("loader", false)
    local o = settings.load()
    assert.same({ loader = false }, o)
  end)
end)

describe("ledger.builder settings overlay", function()
  local builder = require("ledger.builder")

  before_each(function()
    settings._reset()
    require("ledger.config").setup({}) -- restore defaults under the overlay
  end)

  it("cfg() reflects a persisted override over the config default", function()
    -- border defaults to false in config; the overlay flips it on.
    assert.is_false(builder._cfg().border)
    settings.set("border", true)
    assert.is_true(builder._cfg().border)
  end)

  it("cfg() keeps config defaults for keys the overlay doesn't set", function()
    settings.set("border", true)
    -- loader (config default true) is untouched by the overlay.
    assert.is_true(builder._cfg().loader)
    assert.equals("max", builder._cfg().animation)
  end)
end)

describe("ledger.builder Allure paths", function()
  local builder = require("ledger.builder")

  it("desktop results/report live side-by-side under e2e/desktop", function()
    local p = builder.allure_paths("desktop", nil, "/repo")
    assert.equals("/repo/e2e/desktop/allure-results", p.results)
    assert.equals("/repo/e2e/desktop/allure-report", p.report)
  end)

  it("mobile results/report nest under e2e/mobile/artifacts (flag-agnostic)", function()
    local ios = builder.allure_paths("mobile", "ios", "/repo")
    assert.equals("/repo/e2e/mobile/artifacts", ios.results)
    assert.equals("/repo/e2e/mobile/artifacts/allure-report", ios.report)
    -- android resolves to the same layout as ios (flag doesn't change dirs).
    local android = builder.allure_paths("mobile", "android", "/repo")
    assert.same(ios, android)
  end)
end)
