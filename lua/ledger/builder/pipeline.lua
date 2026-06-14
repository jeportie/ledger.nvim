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

-- Desktop (Playwright / Electron).
M.desktop = {
  { id = "clean", label = "clean", template = "shared.clean", optional = true },
  { id = "install", label = "install deps", template = "desktop.install", optional = true, artifact = "node_modules" },
  { id = "cli", label = "build CLI", template = "desktop.build.cli" },
  { id = "libs", label = "build:lld:deps", template = "desktop.build.deps" },
  {
    id = "build",
    label = "build:testing",
    template = "desktop.build.testing",
    artifact = "apps/ledger-live-desktop/.webpack/main.bundle.js",
    sources = { "apps/ledger-live-desktop/src", "apps/ledger-live-desktop/tools" },
  },
  { id = "pw_setup", label = "playwright browser", template = "desktop.pw.setup", optional = true },
  { id = "test", label = "playwright run", template = "desktop.pw.run", kind = "test" },
}

-- iOS (Detox debug — needs pods + Metro at run time).
M.ios = {
  { id = "clean", label = "clean", template = "shared.clean", optional = true },
  { id = "install", label = "install deps", template = "mobile.install", optional = true, artifact = "node_modules" },
  { id = "cli", label = "build CLI", template = "mobile.build.cli" },
  { id = "libs", label = "build:llm:deps", template = "mobile.build.deps" },
  {
    id = "pod",
    label = "pod install",
    template = "mobile.pod",
    artifact = "apps/ledger-live-mobile/ios/Podfile.lock",
  },
  {
    id = "build",
    label = "e2e:build ios.sim.debug",
    template = "mobile.detox.build",
    artifact = "@detox-binary",
    sources = { "apps/ledger-live-mobile/src" },
  },
  { id = "test", label = "detox test (iOS)", template = "mobile.detox.test", kind = "test" },
}

-- Android (Detox release — no pods, no Metro).
M.android = {
  { id = "clean", label = "clean", template = "shared.clean", optional = true },
  { id = "install", label = "install deps", template = "mobile.install", optional = true, artifact = "node_modules" },
  { id = "cli", label = "build CLI", template = "mobile.build.cli" },
  { id = "libs", label = "build:llm:deps", template = "mobile.build.deps" },
  {
    id = "build",
    label = "e2e:build android.emu.release",
    template = "mobile.detox.build",
    artifact = "@detox-binary",
    sources = { "apps/ledger-live-mobile/src" },
  },
  { id = "test", label = "detox test (Android)", template = "mobile.detox.test", kind = "test" },
}

-- Ordered steps for a platform. desktop → M.desktop; mobile → M.ios or
-- M.android per `opts.platform_flag`. Returns shallow copies so callers can
-- annotate without mutating the definitions.
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

-- Step status: "done" | "stale" | "pending" | "ready".
-- ctx = {
--   root, config,
--   detox_binary(config) -> rel path | nil,
--   artifact_exists(abs) -> bool,
--   is_stale(abs, abs_sources) -> bool,
--   proc_alive(name) -> bool,
-- }
function M.status(step, ctx)
  if step.proc then
    return ctx.proc_alive(step.proc) and "done" or "pending"
  end
  if step.artifact then
    local path = M.resolve_artifact(step, ctx)
    if not path or not ctx.artifact_exists(path) then
      return "pending"
    end
    if step.sources and #step.sources > 0 and ctx.is_stale(path, resolve_sources(step, ctx)) then
      return "stale"
    end
    return "done"
  end
  return "ready"
end

return M
