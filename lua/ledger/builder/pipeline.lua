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

-- Build-ready pipelines: each makes a target ready to TEST (testing itself is a
-- separate action — the "Run tests" button). `clean` leads as an `optional`
-- (non-gating) step that the controller flags "recommended" after a failure;
-- `install` is diff-driven (its status reflects whether node_modules is stale
-- vs the lockfile). Running daemons live in the Processes pane, not here.

-- `clean` runs `git clean -fdX` under `pnpm clean`, so detect either form.
local CLEAN_MATCH = { "pnpm%S* clean", "git clean" }

-- Desktop (Playwright / Electron). `match` is a Lua pattern (or a list of
-- patterns) used to detect the step's command running in ANY terminal
-- (cross-session "in progress"). `nx_project` ties a no-artifact build step to
-- its Nx project so its done/failed + log can be read from the Nx cache.
M.desktop = {
  {
    id = "clean",
    label = "clean",
    template = "shared.clean",
    optional = true,
    match = CLEAN_MATCH,
  },
  {
    id = "install",
    label = "install deps",
    template = "desktop.install",
    artifact = "node_modules/.modules.yaml",
    sources = { "pnpm-lock.yaml" },
    match = "pnpm%S* i",
  },
  {
    -- build:lld:deps also builds @ledgerhq/live-e2e-shared (part of the deps graph).
    id = "libs",
    label = "build:lld:deps",
    template = "desktop.build.deps",
    match = "build:lld:deps",
    nx_project = "ledger-live-desktop",
  },
  {
    id = "cli",
    label = "build CLI",
    template = "desktop.build.cli",
    match = "build:cli",
    nx_project = "@ledgerhq/live-cli",
  },
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
    id = "clean",
    label = "clean",
    template = "shared.clean",
    optional = true,
    match = CLEAN_MATCH,
  },
  {
    id = "install",
    label = "install deps",
    template = "mobile.install",
    artifact = "node_modules/.modules.yaml",
    sources = { "pnpm-lock.yaml" },
    match = "pnpm%S* i",
  },
  {
    -- build:llm:deps also builds @ledgerhq/live-e2e-shared (part of the deps graph).
    id = "libs",
    label = "build:llm:deps",
    template = "mobile.build.deps",
    match = "build:llm:deps",
    nx_project = "live-mobile",
  },
  {
    id = "cli",
    label = "build CLI",
    template = "mobile.build.cli",
    match = "build:cli",
    nx_project = "@ledgerhq/live-cli",
  },
  {
    id = "pod",
    label = "pod install",
    template = "mobile.pod",
    -- Pods are in sync only when the installed Pods/Manifest.lock still matches
    -- Podfile.lock (CocoaPods' own "sandbox not in sync" check). A native-dep bump
    -- (e.g. MMKV) changes Podfile.lock → this flips to needs_update → gates the
    -- detox build. Manifest.lock missing (never installed) → missing.
    artifact = "apps/ledger-live-mobile/ios/Pods/Manifest.lock",
    synced_with = "apps/ledger-live-mobile/ios/Podfile.lock",
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
    id = "clean",
    label = "clean",
    template = "shared.clean",
    optional = true,
    match = CLEAN_MATCH,
  },
  {
    id = "install",
    label = "install deps",
    template = "mobile.install",
    artifact = "node_modules/.modules.yaml",
    sources = { "pnpm-lock.yaml" },
    match = "pnpm%S* i",
  },
  {
    -- build:llm:deps also builds @ledgerhq/live-e2e-shared (part of the deps graph).
    id = "libs",
    label = "build:llm:deps",
    template = "mobile.build.deps",
    match = "build:llm:deps",
    nx_project = "live-mobile",
  },
  {
    id = "cli",
    label = "build CLI",
    template = "mobile.build.cli",
    match = "build:cli",
    nx_project = "@ledgerhq/live-cli",
  },
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

-- Step status: "missing" | "needs_update" | "done" | "failed".
-- (The controller overlays "in_progress" when the step's task is running, and
-- derives the clean step's "recommended" / "idle" from the others.)
-- ctx = {
--   root, config,
--   detox_binary(config) -> rel path | nil,
--   artifact_exists(abs) -> bool,
--   is_stale(abs, abs_sources) -> bool,
--   files_equal(abs_a, abs_b) -> bool,  -- content match (synced_with steps)
--   proc_alive(name) -> bool,
--   last_result(step) -> { code, … } | nil,  -- last run: per-repo store, or the
--                                             -- Nx cache for nx_project steps
-- }
function M.status(step, ctx)
  -- A failed last run trumps everything (a stale artifact may still linger).
  local res = ctx.last_result and ctx.last_result(step)
  if res and res.code and res.code ~= 0 then
    return "failed"
  end
  if step.proc then
    return ctx.proc_alive(step.proc) and "done" or "missing"
  end
  if step.artifact then
    local path = M.resolve_artifact(step, ctx)
    if not path or not ctx.artifact_exists(path) then
      return "missing"
    end
    -- `synced_with`: the artifact is an install manifest that must still MATCH a
    -- source lockfile (CocoaPods' Pods/Manifest.lock vs Podfile.lock). A content
    -- mismatch = the installed sandbox is out of sync → rebuild. Content compare
    -- (not mtime) so a branch switch that only touches mtimes doesn't false-flag.
    if step.synced_with and ctx.files_equal and not ctx.files_equal(path, ctx.root .. "/" .. step.synced_with) then
      return "needs_update"
    end
    if step.sources and #step.sources > 0 and ctx.is_stale(path, resolve_sources(step, ctx)) then
      return "needs_update"
    end
    return "done"
  end
  -- stateless step (clean / cli / libs): driven by the last run's exit code
  return (res and res.code == 0) and "done" or "missing"
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
