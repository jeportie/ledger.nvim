-- ledger.builder.proc
--
-- Registry of the long-running processes the Builder dashboard tracks as live
-- cards: Metro, the Detox bridge, Speculos containers, the iOS simulator /
-- Android emulator, library watchers, the desktop dev server, and the Allure
-- report server.
--
-- Detection shells out (lsof / docker / a probe command). The command strings
-- are built by pure functions (`detect_cmd`, `stop_cmd`) so they can be unit
-- tested, and `is_alive` / `status` take an injectable `runner` for the same
-- reason. The default runner uses `vim.system` (Neovim 0.10+).
--
-- Two runner shapes coexist:
--   * synchronous `runner(cmd) -> { code, stdout }` — used by `is_alive` /
--     `status` / `status_all` / `for_platform` and by the unit tests.
--   * asynchronous `runner(cmd, cb)` where `cb` receives `{ code, stdout }` —
--     used by `for_platform_async` so the Builder can probe liveness without
--     blocking the UI thread on `vim.system():wait()`.
-- The async path is purely additive; the synchronous contract is unchanged.

local M = {}

-- Ordered registry. Each entry declares ONE detection strategy:
--   port   = <n>      -> alive if something LISTENs on the port
--   docker = <filter> -> alive if `docker ps` matches (count = #containers)
--   probe  = <cmd>    -> alive if the command exits 0
-- `start` names a ledger.tasks template id used to (re)start the process.
M.registry = {
  {
    name = "metro",
    label = "Metro",
    port = 8081,
    start = "mobile.metro",
  },
  {
    name = "bridge",
    label = "Detox bridge",
    -- Detox 20 binds the bridge to a random ephemeral port, so there's nothing
    -- stable to probe; it's up exactly while the detox test task runs.
    task = "mobile.detox.test",
  },
  {
    name = "speculos",
    label = "Speculos",
    docker = "name=speculos",
    start = "speculos.logs", -- `s` follows the container's docker logs in this card
  },
  {
    name = "ios_sim",
    label = "iOS simulator",
    -- match the detox device named "iOS Simulator" too, not just stock iPhone/iPad names
    probe = "xcrun simctl list devices booted | grep -qiE 'iphone|ipad|ios simulator'",
    start = "mobile.sim.logs", -- `s` streams the booted sim's app log into this card
  },
  {
    name = "android_emu",
    label = "Android emulator",
    probe = "adb devices | grep -qw emulator",
  },
  {
    name = "dev_lld",
    label = "dev:lld",
    start = "desktop.dev",
    port = 8080, -- the rspack dev server dev:lld serves on (also gates double-start)
  },
}

-- name -> entry
M.by_name = {}
for _, e in ipairs(M.registry) do
  M.by_name[e.name] = e
end

-- Ordered list of names.
function M.list()
  local out = {}
  for _, e in ipairs(M.registry) do
    out[#out + 1] = e.name
  end
  return out
end

-- Overlay managed-task liveness onto a status list: a proc with a `task` field is
-- alive iff that task runs. `is_running` is injected (tasks.is_running) so this
-- stays pure/testable. Used for cards with no stable shell probe (e.g. the detox
-- bridge, whose port is random).
function M.apply_task_liveness(procs, is_running)
  for _, p in ipairs(procs) do
    local e = M.by_name[p.name]
    if e and e.task and is_running(e.task) then
      p.alive = true
    end
  end
  return procs
end

-- Pure: the shell command used to detect liveness, or nil if this entry has no
-- shell probe (managed-task only).
function M.detect_cmd(name)
  local e = M.by_name[name]
  if not e then
    return nil
  end
  if e.port then
    return "lsof -ti:" .. e.port .. " -sTCP:LISTEN"
  elseif e.docker then
    return "docker ps --filter " .. e.docker .. " --format '{{.ID}}'"
  elseif e.probe then
    return e.probe
  end
  return nil
end

-- Pure: the shell command used to stop the process, or nil.
function M.stop_cmd(name)
  local e = M.by_name[name]
  if not e then
    return nil
  end
  if e.port then
    return "lsof -ti:" .. e.port .. " | xargs kill -9"
  elseif e.docker then
    return "docker rm -f $(docker ps -aq --filter " .. e.docker .. ")"
  end
  return nil
end

-- Default runner: returns { code = <int>, stdout = <string> }.
local function default_runner(cmd)
  local res = vim.system({ "sh", "-c", cmd }, { text = true }):wait()
  return { code = res.code or 1, stdout = res.stdout or "" }
end

-- Default async runner: runs `cmd` without blocking and invokes `cb` with
-- { code, stdout } when it exits. `vim.system`'s callback fires off the main
-- loop, so callers that touch buffers from `cb` must `vim.schedule`.
local function default_async_runner(cmd, cb)
  vim.system({ "sh", "-c", cmd }, { text = true }, function(res)
    cb({ code = res.code or 1, stdout = res.stdout or "" })
  end)
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Liveness. `runner` defaults to vim.system; tests inject a fake.
function M.is_alive(name, runner)
  runner = runner or default_runner
  local e = M.by_name[name]
  if not e then
    return false
  end
  local cmd = M.detect_cmd(name)
  if not cmd then
    return false
  end
  local r = runner(cmd)
  if e.probe then
    return r.code == 0
  end
  -- port / docker: alive when stdout is non-empty
  return trim(r.stdout or "") ~= ""
end

-- How many docker containers match (0 for non-docker entries).
function M.container_count(name, runner)
  runner = runner or default_runner
  local e = M.by_name[name]
  if not e or not e.docker then
    return 0
  end
  local r = runner(M.detect_cmd(name))
  local n = 0
  for _ in (r.stdout or ""):gmatch("[^\r\n]+") do
    n = n + 1
  end
  return n
end

-- Status of one process: { name, label, alive, port?, count? }.
function M.status(name, runner)
  local e = M.by_name[name]
  if not e then
    return nil
  end
  local st = {
    name = e.name,
    label = e.label,
    alive = M.is_alive(name, runner),
    port = e.port,
  }
  if e.docker then
    st.count = M.container_count(name, runner)
  end
  return st
end

-- Status of every registered process, in order.
function M.status_all(runner)
  local out = {}
  for _, name in ipairs(M.list()) do
    out[#out + 1] = M.status(name, runner)
  end
  return out
end

-- The process names relevant to a platform/flag. Android does NOT use Metro
-- (release bundle is embedded); desktop has no Metro/bridge/simulator.
function M.names_for(platform, flag)
  if platform == "desktop" then
    return { "speculos", "dev_lld" }
  elseif flag == "android" then
    return { "bridge", "speculos", "android_emu" }
  end
  -- mobile / iOS
  return { "metro", "bridge", "speculos", "ios_sim" }
end

-- Status of just the processes relevant to a platform/flag, in order.
function M.for_platform(platform, flag, runner)
  local out = {}
  for _, name in ipairs(M.names_for(platform, flag)) do
    local st = M.status(name, runner)
    if st then
      out[#out + 1] = st
    end
  end
  return out
end

-- ── async liveness (non-blocking) ────────────────────────────────────────────
-- Same status shape as the sync path, but a single probe per process resolved
-- via `vim.system(cmd, cb)` so the UI thread never blocks on `:wait()`.

-- Pure: turn a detect-command result into a status, given the entry. Derives
-- `alive` (+ docker `count`) from ONE command result (no second probe).
local function status_from_result(e, r)
  local st = { name = e.name, label = e.label, port = e.port }
  if e.probe then
    st.alive = r.code == 0
  elseif e.docker then
    local n = 0
    for _ in (r.stdout or ""):gmatch("[^\r\n]+") do
      n = n + 1
    end
    st.count = n
    st.alive = n > 0
  else -- port (or any non-shell entry): alive when stdout is non-empty
    st.alive = trim(r.stdout or "") ~= ""
  end
  return st
end

-- Async status of one process. `cb(status)` always fires exactly once. Entries
-- with no shell probe (managed-only, e.g. dev_lld) resolve to alive=false
-- without a probe, mirroring `status`/`is_alive`.
function M.status_async(name, async_runner, cb)
  async_runner = async_runner or default_async_runner
  local e = M.by_name[name]
  if not e then
    return cb(nil)
  end
  local cmd = M.detect_cmd(name)
  if not cmd then
    local st = { name = e.name, label = e.label, alive = false, port = e.port }
    if e.docker then
      st.count = 0
    end
    return cb(st)
  end
  async_runner(cmd, function(r)
    cb(status_from_result(e, r or { code = 1, stdout = "" }))
  end)
end

-- Async status of the processes relevant to a platform/flag, IN ORDER. Fans the
-- probes out concurrently and invokes `cb(list)` once every probe has returned.
-- `async_runner(cmd, cb)` is injectable (tests pass one that calls back
-- synchronously). With no relevant processes, `cb({})` fires on the next tick.
function M.for_platform_async(platform, flag, cb, async_runner)
  local names = M.names_for(platform, flag)
  local total = #names
  local results, remaining = {}, total
  if total == 0 then
    return vim.schedule(function()
      cb({})
    end)
  end
  local function done()
    remaining = remaining - 1
    if remaining == 0 then
      local out = {}
      for i = 1, total do
        if results[i] then
          out[#out + 1] = results[i]
        end
      end
      cb(out)
    end
  end
  for i, name in ipairs(names) do
    M.status_async(name, async_runner, function(st)
      results[i] = st
      done()
    end)
  end
end

-- Stop a process (executes side effects). Returns true if a stop command ran.
function M.stop(name, runner)
  runner = runner or default_runner
  local cmd = M.stop_cmd(name)
  if not cmd then
    return false
  end
  runner(cmd)
  return true
end

-- Start a process via its ledger.tasks template, if it declares one.
function M.start(name, opts)
  local e = M.by_name[name]
  if not e or not e.start then
    return false, "no start template for " .. tostring(name)
  end
  return require("ledger.tasks").run(e.start, opts)
end

-- Restart = stop then start.
function M.restart(name, opts)
  M.stop(name)
  return M.start(name, opts)
end

return M
