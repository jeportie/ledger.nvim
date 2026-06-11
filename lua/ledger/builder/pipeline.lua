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

-- Desktop pipeline (Playwright / Electron).
M.desktop = {
  { id = "deps", label = "deps installed", template = "desktop.install", artifact = "node_modules" },
  { id = "libs", label = "libs + cli built", template = "desktop.build.deps" },
  {
    id = "build",
    label = "testing build",
    template = "desktop.build.testing",
    artifact = "apps/ledger-live-desktop/.webpack/main.bundle.js",
    sources = { "apps/ledger-live-desktop/src", "apps/ledger-live-desktop/tools" },
  },
  { id = "pw_setup", label = "playwright browser", template = "desktop.pw.setup" },
  { id = "run", label = "playwright run", template = "desktop.pw.run", kind = "test" },
  { id = "report", label = "allure report", template = "desktop.allure", kind = "report" },
}

-- Mobile pipeline. The native-build artifact depends on the active Detox
-- configuration, so `build.artifact` is resolved from ledger.detox.binary_paths
-- at status time (see resolve_artifact).
M.mobile = {
  { id = "deps", label = "deps installed", template = "mobile.install", artifact = "node_modules" },
  { id = "libs", label = "libs + cli built", template = "mobile.build.deps" },
  {
    id = "pod",
    label = "pods installed",
    template = "mobile.pod",
    artifact = "apps/ledger-live-mobile/ios/Podfile.lock",
    ios_only = true,
  },
  {
    id = "build",
    label = "native app built",
    template = "mobile.detox.build",
    artifact = "@detox-binary",
    sources = { "apps/ledger-live-mobile/src" },
  },
  { id = "metro", label = "metro", template = "mobile.metro", proc = "metro", daemon = true },
  { id = "device", label = "simulator / emulator", proc = "ios_sim", daemon = true },
  { id = "test", label = "detox test", template = "mobile.detox.test", kind = "test" },
  { id = "report", label = "allure report", template = "mobile.allure", kind = "report" },
}

-- Ordered steps for a platform. `opts.config` selects the mobile build target;
-- `opts.platform_flag` ("ios"|"android") tweaks the device step proc.
function M.steps(platform, opts)
  opts = opts or {}
  local list = platform == "mobile" and M.mobile or M.desktop
  -- shallow copy so per-session resolution (device proc) doesn't mutate defs
  local out = {}
  for _, s in ipairs(list) do
    local step = vim.tbl_extend("keep", {}, s)
    if step.id == "device" and opts.platform_flag == "android" then
      step.proc = "android_emu"
      step.label = "emulator"
    end
    out[#out + 1] = step
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
