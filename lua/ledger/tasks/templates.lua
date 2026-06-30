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

-- Build command for a detox configuration. Pods are installed by the dedicated
-- `mobile.pod` pipeline step (and run_all orders it before the build), so the
-- build no longer reinstalls them on every run.
local function detox_build_cmd(opts)
  local cfg = opts.config or "ios.sim.debug"
  return "pnpm mobile e2e:build -c " .. cfg
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
-- / `opts.name`; `opts.pwdebug` prefixes `PWDEBUG=1` (Inspector); `opts.mock`
-- prefixes `MOCK=1` (mocked device).
local function pw_run_cmd(opts)
  local base = "pnpm e2e:desktop test:playwright"
  local scope = opts.scope or "all"
  if scope == "file" and opts.spec and opts.spec ~= "" then
    base = base .. " " .. opts.spec
  elseif scope == "name" and opts.name and opts.name ~= "" then
    base = base .. ' --grep "' .. opts.name .. '"'
  end
  local prefix = ""
  if opts.mock then
    prefix = "MOCK=1 " .. prefix
  end
  if opts.pwdebug then
    prefix = prefix .. "PWDEBUG=1 "
  end
  return prefix .. base
end

-- Guided iOS-simulator setup — resolves xcodebuild "Found no destinations for the
-- scheme". xcodebuild builds against the iphonesimulator SDK (e.g. iOS 26.5), so a
-- simulator runtime of that EXACT version must exist; an older runtime (e.g. 26.4)
-- is ineligible. If the matching runtime is missing we print the one-time multi-GB
-- install command and stop; otherwise we create + boot a simulator named
-- "iOS Simulator" (the device name detox targets) on that runtime.
-- NB: no `set -e` — be resilient (a booted device can't be deleted, simctl can
-- exit non-zero on benign races); guard each step and print a manual fallback.
local IOS_SIM_FIX = [[
SDK=$(xcodebuild -showsdks 2>/dev/null | grep -oE "iphonesimulator[0-9.]+" | head -1 | sed 's/iphonesimulator//')
if [ -z "$SDK" ]; then
  echo "Could not determine the iphonesimulator SDK version (is Xcode selected?)."
  exit 1
fi
if ! xcrun simctl list runtimes 2>/dev/null | grep -q "iOS $SDK "; then
  echo "xcodebuild builds against the iOS $SDK simulator SDK, but no iOS $SDK runtime is installed."
  echo "(An older runtime is ineligible — the simulator version must match the SDK.)"
  echo "Install it (one-time, multi-GB), then re-run:"
  echo "    xcodebuild -downloadPlatform iOS"
  echo "  or: Xcode > Settings > Components > iOS $SDK Simulator"
  exit 1
fi
RT=$(xcrun simctl list runtimes | grep "iOS $SDK " | grep -oE "com.apple.CoreSimulator.SimRuntime.iOS[^ ]*" | tail -1)
DT=$(xcrun simctl list devicetypes | grep -oE "com.apple.CoreSimulator.SimDeviceType.iPhone[^ )]*" | tail -1)
# detox targets a device NAMED "iOS Simulator"; keep exactly one, on the SDK runtime.
TARGET=$(xcrun simctl list devices "$RT" 2>/dev/null | grep "iOS Simulator (" | grep -oiE "[0-9a-f-]{36}" | head -1)
for u in $(xcrun simctl list devices 2>/dev/null | grep "iOS Simulator (" | grep -oiE "[0-9a-f-]{36}"); do
  [ "$u" = "$TARGET" ] && continue
  xcrun simctl shutdown "$u" 2>/dev/null
  xcrun simctl delete "$u" 2>/dev/null
done
if [ -z "$TARGET" ]; then
  echo "Creating 'iOS Simulator' ($DT on iOS $SDK)"
  TARGET=$(xcrun simctl create "iOS Simulator" "$DT" "$RT" 2>/dev/null)
fi
if [ -z "$TARGET" ]; then
  echo "Could not create the simulator. Create it manually, then retry:"
  echo "    xcrun simctl create \"iOS Simulator\" \"$DT\" \"$RT\""
  exit 1
fi
xcrun simctl boot "$TARGET" 2>/dev/null
open -a Simulator 2>/dev/null
echo "iOS Simulator ready (UDID $TARGET on iOS $SDK)."
]]

-- The matrix. Order is roughly pipeline order per platform.
M.templates = {
  -- ── desktop ──────────────────────────────────────────────────────────────
  {
    id = "desktop.install",
    label = "Desktop · install deps",
    platform = "desktop",
    kind = "install",
    cwd = "repo",
    -- `--config.confirm-modules-purge=false`: the Builder runs without a TTY, so
    -- pnpm can't prompt before removing node_modules (e.g. after a lockfile
    -- change) — pre-answer it to avoid ERR_PNPM_ABORTED_REMOVE_MODULE_DIR_NO_TTY.
    cmd = "pnpm i --config.confirm-modules-purge=false "
      .. '--filter="ledger-live-desktop..." --filter="live-cli..." '
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
    id = "desktop.run.prod",
    label = "Desktop · run app (production bundle)",
    platform = "desktop",
    kind = "run",
    cwd = "repo",
    -- always build:js then run: the on-disk .webpack bundle is whatever ran last
    -- (dev/testing/prod share one path), and a dev bundle pins the window to the
    -- :8080 dev server → white screen. build:js is minified, __DEV__=false, loads
    -- the renderer from file://. NB: this overwrites the build:testing bundle —
    -- rebuild that before Playwright e2e.
    cmd = "pnpm desktop build:js && pnpm desktop start:prod",
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
    cmd = "pnpm i --config.confirm-modules-purge=false "
      .. '--filter="live-mobile..." --filter="ledger-live" '
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
    id = "mobile.sim.logs",
    label = "Mobile · iOS simulator logs",
    platform = "mobile",
    kind = "daemon",
    cwd = "repo",
    -- stream the booted sim's app log (unbounded → daemon; kill via the proc card)
    cmd = "xcrun simctl spawn booted log stream --level info --style compact --color none --predicate 'process == \"ledgerlivemobile\"'",
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
    id = "mobile.run.ios",
    label = "Mobile · run app (iOS sim)",
    platform = "mobile",
    kind = "run",
    cwd = "repo",
    cmd = "pnpm mobile ios",
  },
  {
    id = "mobile.run.android",
    label = "Mobile · run app (Android emu)",
    platform = "mobile",
    kind = "run",
    cwd = "repo",
    cmd = "pnpm mobile android",
  },
  {
    id = "mobile.run.ios.staging",
    label = "Mobile · run app (iOS sim · Staging)",
    platform = "mobile",
    kind = "run",
    cwd = "repo",
    cmd = "pnpm mobile ios:staging",
  },
  {
    id = "mobile.run.android.staging",
    label = "Mobile · run app (Android emu · Staging)",
    platform = "mobile",
    kind = "run",
    cwd = "repo",
    cmd = "pnpm mobile staging-android",
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
    id = "shared.nx.watch",
    label = "Nx · watch (auto-rebuild libs)",
    platform = "shared",
    kind = "daemon",
    cwd = "repo",
    cmd = function(opts)
      if opts.cmd and opts.cmd ~= "" then
        return opts.cmd
      end
      local b = (require("ledger.config").get() or {}).builder or {}
      return b.watch_cmd or "pnpm nx watch --all -- pnpm nx build $NX_PROJECT_NAME"
    end,
    -- nx watch needs the Nx daemon; this repo disables it globally
    -- (useDaemonProcess:false), so force it on just for the watch process.
    env = { NX_DAEMON = "true" },
    daemon = true,
  },
  {
    id = "shared.nx.build",
    label = "Nx · build (targeted)",
    platform = "shared",
    kind = "build",
    cwd = "repo",
    -- Targeted build: `opts.projects` (a list) or `opts.filter` (a raw -p glob).
    -- `--excludeTaskDependencies` builds ONLY the named project(s), not their
    -- dependency graph — the libs/build:lld:deps step does the full graph build;
    -- this is the fast, incremental single-project path for watch + targeting.
    cmd = function(opts)
      local sel = (opts.filter and opts.filter ~= "" and opts.filter) or table.concat(opts.projects or {}, " ")
      return "pnpm nx run-many -t build -p " .. sel .. " --excludeTaskDependencies"
    end,
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
  {
    id = "fix.ios_sim",
    label = "Fix · iOS simulator (create + boot 'iOS Simulator')",
    platform = "mobile",
    kind = "fix",
    cwd = "repo",
    cmd = IOS_SIM_FIX,
  },
}

-- id -> template
M.by_id = {}
for _, t in ipairs(M.templates) do
  M.by_id[t.id] = t
end

-- Force plain, streamed output from Nx/turbo so the Builder Logs read cleanly
-- (jobstart is non-TTY; these belt-and-suspenders the static output style).
-- NOTE: adjust to your Nx/turbo version if needed.
local NX_PLAIN = {
  NX_TUI = "false",
  NX_TASKS_RUNNER_DYNAMIC_OUTPUT = "false",
  TURBO_UI = "false",
  FORCE_COLOR = "0",
}

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
  local env = t.env and vim.deepcopy(t.env) or nil
  if t.kind == "build" or t.kind == "install" then
    -- build/install run via Nx/turbo → force readable streamed output in the Logs
    env = vim.tbl_extend("force", {}, NX_PLAIN, env or {})
  end
  return {
    id = t.id,
    label = t.label,
    platform = t.platform,
    kind = t.kind,
    cmd = cmd,
    cwd = M.resolve_cwd(t.cwd, root),
    env = env,
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
