-- ledger.tasks.templates
--
-- Declarative command matrix for the ledger-live monorepo. Each template is
-- data: an id, label, platform, kind, the literal command (string or a
-- function of opts), the symbolic cwd, optional env, optional build artifact
-- (for staleness checks), and whether it is a long-running daemon.
--
-- `resolve(id, opts, root)` turns a template into a concrete runnable spec
-- { id, label, platform, kind, cmd, cwd, env, daemon, artifact }. It is pure
-- when `root` is supplied, which is what the specs exercise.

local M = {}

-- Symbolic cwd -> absolute, given the repo root.
function M.resolve_cwd(sym, root)
  local map = {
    repo = root,
    e2e_desktop = root .. "/e2e/desktop",
    e2e_mobile = root .. "/e2e/mobile",
    mobile_app = root .. "/apps/ledger-live-mobile",
    desktop_app = root .. "/apps/ledger-live-desktop",
  }
  return map[sym or "repo"] or root
end

-- Build command for a detox configuration. iOS configs need pods first.
local function detox_build_cmd(opts)
  local cfg = opts.config or "ios.sim.debug"
  local prefix = cfg:match("^ios") and "pnpm mobile pod && " or ""
  return prefix .. "pnpm mobile e2e:build -c " .. cfg
end

-- Map a detox configuration to its e2e:mobile script (iOS debug needs Metro;
-- iOS/Android release embed the bundle; Android debug is broken locally).
local DETOX_SCRIPT = {
  ["ios.sim.debug"] = "test:ios:debug",
  ["ios.sim.release"] = "test:ios",
  ["android.emu.release"] = "test:android",
}

-- Detox test command. `opts.config` picks the script; `opts.scope` ("all" |
-- "file" | "name") + `opts.spec` / `opts.name` build the Jest filter.
local function detox_test_cmd(opts)
  local cfg = opts.config or "ios.sim.debug"
  local script = DETOX_SCRIPT[cfg]
  local base = script and ("pnpm e2e:mobile " .. script) or ("pnpm e2e:mobile test:detox -- -c " .. cfg)
  local scope = opts.scope or "all"
  if script then
    if scope == "file" and opts.spec and opts.spec ~= "" then
      base = base .. " -- --testPathPattern " .. opts.spec
    elseif scope == "name" and opts.name and opts.name ~= "" then
      base = base .. ' -- -t "' .. opts.name .. '"'
    end
  end
  return base
end

-- Playwright test command. `opts.scope` ("all" | "file" | "name") + `opts.spec`
-- / `opts.name`; `opts.pwdebug` prefixes `PWDEBUG=1` to open the Inspector.
local function pw_run_cmd(opts)
  local base = "pnpm e2e:desktop test:playwright"
  local scope = opts.scope or "all"
  if scope == "file" and opts.spec and opts.spec ~= "" then
    base = base .. " " .. opts.spec
  elseif scope == "name" and opts.name and opts.name ~= "" then
    base = base .. ' --grep "' .. opts.name .. '"'
  end
  if opts.pwdebug then
    base = "PWDEBUG=1 " .. base
  end
  return base
end

-- The matrix. Order is roughly pipeline order per platform.
M.templates = {
  -- ── desktop ──────────────────────────────────────────────────────────────
  {
    id = "desktop.install",
    label = "Desktop · install deps",
    platform = "desktop",
    kind = "install",
    cwd = "repo",
    cmd = 'pnpm i --filter="ledger-live-desktop..." --filter="live-cli..." '
      .. '--filter="ledger-live" --filter="@ledgerhq/dummy-*-app..." '
      .. '--filter="ledger-live-desktop-e2e-tests" --unsafe-perm',
  },
  {
    id = "desktop.build.deps",
    label = "Desktop · build libs (deps)",
    platform = "desktop",
    kind = "build",
    cwd = "repo",
    cmd = "pnpm build:lld:deps",
  },
  {
    id = "desktop.build.cli",
    label = "Desktop · build CLI",
    platform = "desktop",
    kind = "build",
    cwd = "repo",
    cmd = "pnpm build:cli",
  },
  {
    id = "desktop.build.testing",
    label = "Desktop · build:testing (Playwright)",
    platform = "desktop",
    kind = "build",
    cwd = "repo",
    cmd = "pnpm desktop build:testing",
    env = { TESTING = "1" },
    artifact = "apps/ledger-live-desktop/.webpack/main.bundle.js",
  },
  {
    id = "desktop.build.staging",
    label = "Desktop · build:staging",
    platform = "desktop",
    kind = "build",
    cwd = "repo",
    cmd = "pnpm desktop build:staging",
    env = { STAGING = "1" },
    artifact = "apps/ledger-live-desktop/.webpack/main.bundle.js",
  },
  {
    id = "desktop.dev",
    label = "Desktop · dev server (dev:lld)",
    platform = "desktop",
    kind = "daemon",
    cwd = "repo",
    cmd = "pnpm dev:lld",
    daemon = true,
  },
  {
    id = "desktop.pw.setup",
    label = "Desktop · install Playwright browser",
    platform = "desktop",
    kind = "install",
    cwd = "repo",
    cmd = "pnpm e2e:desktop test:playwright:setup",
  },
  {
    id = "desktop.pw.run",
    label = "Desktop · Playwright run",
    platform = "desktop",
    kind = "test",
    cwd = "repo",
    cmd = pw_run_cmd,
  },
  {
    id = "desktop.pw.smoke",
    label = "Desktop · Playwright @smoke",
    platform = "desktop",
    kind = "test",
    cwd = "repo",
    cmd = 'pnpm e2e:desktop test:playwright --grep "@smoke"',
  },
  {
    id = "desktop.allure",
    label = "Desktop · Allure report",
    platform = "desktop",
    kind = "report",
    cwd = "repo",
    cmd = "pnpm e2e:desktop allure",
    daemon = true,
  },

  -- ── mobile ───────────────────────────────────────────────────────────────
  {
    id = "mobile.install",
    label = "Mobile · install deps",
    platform = "mobile",
    kind = "install",
    cwd = "repo",
    cmd = 'pnpm i --filter="live-mobile..." --filter="ledger-live" '
      .. '--filter="live-cli..." --filter="ledger-live-mobile-e2e-tests"',
  },
  {
    id = "mobile.build.deps",
    label = "Mobile · build libs (deps)",
    platform = "mobile",
    kind = "build",
    cwd = "repo",
    cmd = "pnpm build:llm:deps",
  },
  {
    id = "mobile.build.cli",
    label = "Mobile · build CLI",
    platform = "mobile",
    kind = "build",
    cwd = "repo",
    cmd = "pnpm build:cli",
  },
  {
    id = "mobile.pod",
    label = "Mobile · pod install (iOS)",
    platform = "mobile",
    kind = "build",
    cwd = "repo",
    cmd = "pnpm mobile pod",
    artifact = "apps/ledger-live-mobile/ios/Podfile.lock",
  },
  {
    id = "mobile.metro",
    label = "Mobile · Metro bundler",
    platform = "mobile",
    kind = "daemon",
    cwd = "repo",
    cmd = "pnpm dev:llm",
    daemon = true,
  },
  {
    id = "mobile.detox.build",
    label = "Mobile · Detox build",
    platform = "mobile",
    kind = "build",
    cwd = "repo",
    cmd = detox_build_cmd,
  },
  {
    id = "mobile.detox.test",
    label = "Mobile · Detox test",
    platform = "mobile",
    kind = "test",
    cwd = "repo",
    cmd = detox_test_cmd,
  },
  {
    id = "mobile.e2e.ci",
    label = "Mobile · e2e:ci orchestrator",
    platform = "mobile",
    kind = "test",
    cwd = "repo",
    cmd = function(opts)
      local plat = opts.platform_flag or "ios"
      return "pnpm mobile e2e:ci -- -p " .. plat .. " -b -t"
    end,
  },
  {
    id = "mobile.allure",
    label = "Mobile · Allure report",
    platform = "mobile",
    kind = "report",
    cwd = "repo",
    cmd = "pnpm e2e:mobile allure",
    daemon = true,
  },

  -- ── shared / utility ───────────────────────────────────────────────────────
  {
    id = "shared.lib.watch",
    label = "Lib · watch",
    platform = "shared",
    kind = "daemon",
    cwd = "repo",
    cmd = function(opts)
      local lib = opts.lib or "@ledgerhq/live-common"
      return "pnpm --filter " .. lib .. " run watch"
    end,
    daemon = true,
  },
  {
    id = "shared.adb.reverse",
    label = "Android · adb reverse (8081 + 8099)",
    platform = "mobile",
    kind = "util",
    cwd = "repo",
    cmd = "adb reverse tcp:8081 tcp:8081 && adb reverse tcp:8099 tcp:8099",
  },

  -- ── clean / fixes ──────────────────────────────────────────────────────────
  {
    id = "shared.clean",
    label = "Clean (git clean -fdX)",
    platform = "shared",
    kind = "clean",
    cwd = "repo",
    cmd = "pnpm clean",
  },
  {
    id = "fix.global",
    label = "Fix · reinstall (node_modules + store)",
    platform = "shared",
    kind = "fix",
    cwd = "repo",
    cmd = "rm -rf node_modules && pnpm store prune && pnpm i",
  },
  {
    id = "fix.ios_pod",
    label = "Fix · iOS pods (reset Pods + reinstall)",
    platform = "mobile",
    kind = "fix",
    cwd = "repo",
    cmd = "cd apps/ledger-live-mobile/ios && rm -rf Pods Podfile.lock && cd ../../.. && pnpm mobile pod",
  },
}

-- id -> template
M.by_id = {}
for _, t in ipairs(M.templates) do
  M.by_id[t.id] = t
end

-- Resolve a template id + opts into a concrete spec. `root` defaults to the
-- live repo root; pass it explicitly for pure/testable resolution.
function M.resolve(id, opts, root)
  opts = opts or {}
  local t = M.by_id[id]
  if not t then
    return nil, "unknown template: " .. tostring(id)
  end
  if not root then
    root = require("ledger.detox").get_repo_root()
  end
  local cmd = type(t.cmd) == "function" and t.cmd(opts) or t.cmd
  return {
    id = t.id,
    label = t.label,
    platform = t.platform,
    kind = t.kind,
    cmd = cmd,
    cwd = M.resolve_cwd(t.cwd, root),
    env = t.env and vim.deepcopy(t.env) or nil,
    daemon = t.daemon or false,
    artifact = t.artifact and (root .. "/" .. t.artifact) or nil,
  }
end

-- All template ids, optionally filtered by platform ("desktop"|"mobile"|"shared").
function M.ids(platform)
  local out = {}
  for _, t in ipairs(M.templates) do
    if not platform or t.platform == platform or t.platform == "shared" then
      table.insert(out, t.id)
    end
  end
  return out
end

return M
