-- ledger.builder.pipeline
--
-- The desktop / mobile E2E flow as an ordered list of steps. Each step maps to
-- a ledger.tasks template and declares how to tell whether it's already
-- satisfied:
--   * artifact + sources -> mtime staleness ("done" | "stale" | "pending")
--   * proc               -> liveness via the process registry ("done" | "pending")
--   * neither            -> "ready" (actionable, no persistent state: installs,
--                           cache-managed builds, test/report runs)
--
-- `status(step, ctx)` is pure given an injected ctx, so it's unit-testable.

local M = {}

-- Build-focused pipelines (running daemons live in the Processes pane, not
-- here). `optional=true` steps (clean / install) are off by default and shown
-- with a toggle; the controller's run-all only includes them when toggled on.

-- Build-ready pipelines: each makes a target ready to TEST (testing itself is a
-- separate action — the "Run tests" button). `install` is diff-driven (its
-- status reflects whether node_modules is stale vs the lockfile). `clean` is a
-- maintenance action (run-all "clean + reinstall" / Fix menu), not a table step.

-- Desktop (Playwright / Electron). `match` is a substring used to detect the
-- step's command running in ANY terminal (cross-session "in progress").
M.desktop = {
  {
    id = "install",
    label = "install deps",
    template = "desktop.install",
    artifact = "node_modules",
    sources = { "pnpm-lock.yaml" },
    match = "pnpm i",
  },
  { id = "libs", label = "build:lld:deps", template = "desktop.build.deps", match = "build:lld:deps" },
  { id = "cli", label = "build CLI", template = "desktop.build.cli", match = "build:cli" },
  {
    id = "build",
    label = "build:testing",
    template = "desktop.build.testing",
    artifact = "apps/ledger-live-desktop/.webpack/main.bundle.js",
    sources = { "apps/ledger-live-desktop/src", "apps/ledger-live-desktop/tools" },
  },
}

-- iOS (Detox debug — needs pods + Metro at run time).
M.ios = {
  {
    id = "install",
    label = "install deps",
    template = "mobile.install",
    artifact = "node_modules",
    sources = { "pnpm-lock.yaml" },
    match = "pnpm i",
  },
  { id = "libs", label = "build:llm:deps", template = "mobile.build.deps", match = "build:llm:deps" },
  { id = "cli", label = "build CLI", template = "mobile.build.cli", match = "build:cli" },
  {
    id = "pod",
    label = "pod install",
    template = "mobile.pod",
    artifact = "apps/ledger-live-mobile/ios/Podfile.lock",
    match = "mobile pod",
  },
  {
    id = "build",
    label = "e2e:build ios.sim.debug",
    template = "mobile.detox.build",
    artifact = "@detox-binary",
    sources = { "apps/ledger-live-mobile/src" },
  },
}

-- Android (Detox release — no pods, no Metro).
M.android = {
  {
    id = "install",
    label = "install deps",
    template = "mobile.install",
    artifact = "node_modules",
    sources = { "pnpm-lock.yaml" },
    match = "pnpm i",
  },
  { id = "libs", label = "build:llm:deps", template = "mobile.build.deps", match = "build:llm:deps" },
  { id = "cli", label = "build CLI", template = "mobile.build.cli", match = "build:cli" },
  {
    id = "build",
    label = "e2e:build android.emu.release",
    template = "mobile.detox.build",
    artifact = "@detox-binary",
    sources = { "apps/ledger-live-mobile/src" },
  },
}

-- Ordered steps for a platform. desktop → M.desktop; mobile → M.ios or
-- M.android per `opts.platform_flag`. Returns shallow copies so callers can
-- annotate without mutating the definitions. The `build` step follows the
-- chosen env: mobile shows `e2e:build <config>`; desktop shows `build:<profile>`
-- and runs `desktop.build.<profile>` (testing | staging).
function M.steps(platform, opts)
  opts = opts or {}
  local list = M.desktop
  if platform == "mobile" then
    list = opts.platform_flag == "android" and M.android or M.ios
  end
  local out = {}
  for _, s in ipairs(list) do
    out[#out + 1] = vim.tbl_extend("keep", {}, s)
  end
  for _, s in ipairs(out) do
    if s.id == "build" then
      if platform == "mobile" then
        local cfg = opts.config or (opts.platform_flag == "android" and "android.emu.release" or "ios.sim.debug")
        s.label = "e2e:build " .. cfg
        s.match = "e2e:build"
      else
        local profile = opts.desktop_build or "testing"
        s.label = "build:" .. profile
        s.template = "desktop.build." .. profile
        s.match = "build:" .. profile
      end
    end
  end
  return out
end

-- Resolve a step's artifact to an absolute path (handles the @detox-binary
-- sentinel which depends on the active config).
function M.resolve_artifact(step, ctx)
  if not step.artifact or not ctx.root then
    return nil
  end
  if step.artifact == "@detox-binary" then
    local rel = ctx.detox_binary(ctx.config)
    return rel and (ctx.root .. "/" .. rel) or nil
  end
  return ctx.root .. "/" .. step.artifact
end

-- Resolve a step's source dirs to absolute paths.
local function resolve_sources(step, ctx)
  local out = {}
  for _, s in ipairs(step.sources or {}) do
    out[#out + 1] = ctx.root .. "/" .. s
  end
  return out
end

-- Step status: "missing" | "needs_update" | "done".
-- (The controller overlays "in_progress" when the step's task is running.)
-- ctx = {
--   root, config,
--   detox_binary(config) -> rel path | nil,
--   artifact_exists(abs) -> bool,
--   is_stale(abs, abs_sources) -> bool,
--   proc_alive(name) -> bool,
--   last_ok(template) -> true | false | nil,  -- last run succeeded? (no-artifact steps)
-- }
function M.status(step, ctx)
  if step.proc then
    return ctx.proc_alive(step.proc) and "done" or "missing"
  end
  if step.artifact then
    local path = M.resolve_artifact(step, ctx)
    if not path or not ctx.artifact_exists(path) then
      return "missing"
    end
    if step.sources and #step.sources > 0 and ctx.is_stale(path, resolve_sources(step, ctx)) then
      return "needs_update"
    end
    return "done"
  end
  -- stateless step (clean / cli / libs / pw_setup / test): driven by last run
  return (ctx.last_ok and ctx.last_ok(step.template)) and "done" or "missing"
end

-- Global state for the target, derived from per-step statuses.
-- "in_progress" if any step is running; "ready" if every non-optional step is
-- done; otherwise "not_ready".
function M.target_state(steps, statuses)
  local any_running, all_done = false, true
  for _, step in ipairs(steps or {}) do
    local s = (statuses or {})[step.id]
    if s == "in_progress" then
      any_running = true
    end
    if not step.optional and s ~= "done" then
      all_done = false
    end
  end
  if any_running then
    return "in_progress"
  end
  return all_done and "ready" or "not_ready"
end

return M
