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
    port = 8099,
  },
  {
    name = "speculos",
    label = "Speculos",
    docker = "name=speculos",
  },
  {
    name = "ios_sim",
    label = "iOS simulator",
    probe = "xcrun simctl list devices booted | grep -qi iphone",
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
    -- node/electron process with no stable listening port; tracked via the
    -- managed task rather than a shell probe (status falls back to managed).
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
