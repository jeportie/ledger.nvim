local commands = require("ledger.builder.commands")

describe("ledger.builder.commands.parse_scripts", function()
  local root
  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  it("returns {} when package.json is missing or root is nil", function()
    assert.same({}, commands.parse_scripts(root))
    assert.same({}, commands.parse_scripts(nil))
  end)

  it("groups scripts by the prefix before the first colon, sorted", function()
    local pkg = {
      name = "ledger-live",
      scripts = {
        ["build:cli"] = "turbo run build:cli",
        ["build:lld:deps"] = "turbo run build",
        ["e2e:desktop"] = "playwright",
        ["e2e:mobile"] = "detox",
        ["test"] = "jest",
      },
    }
    vim.fn.writefile({ vim.json.encode(pkg) }, root .. "/package.json")

    local by = {}
    for _, g in ipairs(commands.parse_scripts(root)) do
      by[g.section] = g
    end

    assert.is_truthy(by.build)
    assert.equals(2, #by.build.items)
    assert.equals("build:cli", by.build.items[1].name) -- items sorted
    assert.equals("turbo run build:cli", by.build.items[1].cmd)
    assert.is_truthy(by.e2e)
    assert.equals(2, #by.e2e.items)
    assert.is_truthy(by.misc) -- "test" has no colon → misc
  end)

  it("returns {} on malformed JSON", function()
    vim.fn.writefile({ "{ not json" }, root .. "/package.json")
    assert.same({}, commands.parse_scripts(root))
  end)
end)

describe("ledger.builder.commands.builder_docs", function()
  it("returns titled sections for each platform", function()
    local cases = { { "desktop" }, { "mobile", "ios" }, { "mobile", "android" } }
    for _, c in ipairs(cases) do
      local docs = commands.builder_docs(c[1], c[2])
      assert.is_true(#docs >= 1)
      assert.is_truthy(docs[1].title)
      assert.is_table(docs[1].items)
      assert.is_truthy(docs[1].items[1][1]) -- a command string
    end
  end)
end)
