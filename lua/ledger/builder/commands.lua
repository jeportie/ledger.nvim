-- ledger.builder.commands
--
-- Backs the Builder's `?` help "Cheatsheet" tab:
--   * builder_docs(platform, flag) — curated docs for the Builder's own flows.
--   * parse_scripts(root)          — the repo's package.json `scripts`, grouped
--                                     by the `prefix:` before the first colon.

local uv = vim.uv or vim.loop
local M = {}

-- Read <root>/package.json and group its scripts by section. Returns a sorted
-- list of { section, items = { { name, cmd }, ... } }; {} when missing/invalid.
function M.parse_scripts(root)
  if not root or root == "" then
    return {}
  end
  local path = root .. "/package.json"
  if not uv.fs_stat(path) then
    return {}
  end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if not ok or type(decoded) ~= "table" or type(decoded.scripts) ~= "table" then
    return {}
  end

  local groups = {}
  for name, cmd in pairs(decoded.scripts) do
    local section = name:match("^([^:]+):") or "misc"
    groups[section] = groups[section] or {}
    table.insert(groups[section], { name = name, cmd = tostring(cmd) })
  end

  local sections = {}
  for section, items in pairs(groups) do
    table.sort(items, function(a, b)
      return a.name < b.name
    end)
    sections[#sections + 1] = { section = section, items = items }
  end
  table.sort(sections, function(a, b)
    return a.section < b.section
  end)
  return sections
end

-- Curated, per-platform docs for the Builder's own flows. Returns a list of
-- { title, items = { { cmd, desc }, ... } }.
function M.builder_docs(platform, flag)
  local mobile = platform == "mobile"
  local android = mobile and flag == "android"

  local pipeline
  if not mobile then
    pipeline = {
      { "pnpm build:cli", "shared CLI used by the desktop test harness" },
      { "pnpm build:lld:deps", "build ledger-live-desktop workspace deps" },
      { "pnpm desktop build:testing", "build the app (TESTING=1) for Playwright" },
      { "pnpm desktop build:staging", "build the app (STAGING=1)" },
      { "pnpm e2e:desktop test:playwright:setup", "install the Playwright browser" },
    }
  elseif android then
    pipeline = {
      { "pnpm build:cli", "shared CLI" },
      { "pnpm build:llm:deps", "build ledger-live-mobile workspace deps" },
      { "pnpm mobile e2e:build -c android.emu.release", "build the Detox release APK (no Metro)" },
    }
  else
    pipeline = {
      { "pnpm build:cli", "shared CLI" },
      { "pnpm build:llm:deps", "build ledger-live-mobile workspace deps" },
      { "pnpm mobile pod", "install iOS CocoaPods" },
      { "pnpm mobile e2e:build -c ios.sim.debug", "build the Detox debug app (needs Metro)" },
    }
  end

  local run
  if not mobile then
    run = {
      { "pnpm e2e:desktop test:playwright", "run all desktop specs" },
      { 'pnpm e2e:desktop test:playwright --grep "<t>"', "run specs matching a title/ticket" },
      { "PWDEBUG=1 …", "open the Playwright inspector (p key)" },
      { "MOCK=1 …", "run against a mocked device (e env)" },
    }
  elseif android then
    run = {
      { "pnpm e2e:mobile test:android", "run all Android specs (release)" },
      { "… -- --testPathPattern <f>", "run one spec file" },
      { '… -- -t "<title>"', "run specs matching a title/ticket" },
    }
  else
    run = {
      { "pnpm e2e:mobile test:ios:debug", "run all iOS specs (debug; needs Metro)" },
      { "… -- --testPathPattern <f>", "run one spec file" },
      { '… -- -t "<title>"', "run specs matching a title/ticket" },
    }
  end

  local procs
  if not mobile then
    procs = {
      { "speculos", "device emulator (Docker)" },
      { "pnpm dev:lld", "ledger-live-desktop dev server" },
    }
  elseif android then
    procs = {
      { "detox bridge", "Detox JSON-RPC bridge (:8099)" },
      { "speculos", "device emulator (Docker)" },
      { "android emulator", "AVD" },
    }
  else
    procs = {
      { "pnpm dev:llm (Metro)", "React Native bundler (:8081)" },
      { "detox bridge", "Detox JSON-RPC bridge (:8099)" },
      { "speculos", "device emulator (Docker)" },
      { "iOS simulator", "simctl" },
    }
  end

  local fix = {
    { "pnpm clean", "clean workspace build artifacts" },
    { "rm -rf node_modules && pnpm store prune && pnpm i", "full reinstall" },
  }
  if mobile and not android then
    fix[#fix + 1] = { "rm -rf ios/Pods Podfile.lock && pnpm mobile pod", "reset iOS pods" }
  end

  return {
    { title = "Pipeline (B builds, ⏎ runs the focused step)", items = pipeline },
    { title = "Run tests (r)", items = run },
    { title = "Processes (x kill · s start · ⏎ popup)", items = procs },
    { title = "Fix / maintenance (F)", items = fix },
  }
end

return M
