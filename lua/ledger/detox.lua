-- Detox test runner utilities for neotest integration
-- Shared module: require("ledger.detox")
local M = {}
local uv = vim.uv or vim.loop

-- ============================================================================
-- Configuration (session-scoped, mutable)
-- ============================================================================

M.config = {
  platform = "ios", -- "ios" | "android" | "both"
  both_mode = "sequential", -- "sequential" | "parallel"
  build_terminal = "float", -- "float" | "split"
  auto_build_check = true, -- check build exists before running
  auto_metro = true, -- auto-start Metro for iOS debug
}

-- Platform -> Detox configuration mapping
M.platform_map = {
  ios = "ios.sim.debug",
  android = "android.emu.release",
}

-- Platform display labels
M.platform_labels = {
  ios = "iOS (debug)",
  android = "Android (release)",
  both = "Both (sequential)",
}

-- Binary paths for build detection (relative to repo root)
M.binary_paths = {
  ["ios.sim.debug"] = "apps/ledger-live-mobile/ios/build/Build/Products/Debug-iphonesimulator/ledgerlivemobile.app",
  ["ios.sim.release"] = "apps/ledger-live-mobile/ios/build/Build/Products/Release-iphonesimulator/ledgerlivemobile.app",
  ["android.emu.release"] = "apps/ledger-live-mobile/android/app/build/outputs/apk/detox/app-arm64-v8a-detox.apk",
}

-- Build commands (run from repo root)
M.build_cmds = {
  ["ios.sim.debug"] = "pnpm mobile pod && pnpm mobile e2e:build -c ios.sim.debug",
  ["ios.sim.release"] = "pnpm mobile pod && pnpm mobile e2e:build -c ios.sim.release",
  ["android.emu.release"] = "pnpm mobile e2e:build -c android.emu.release",
}

-- ============================================================================
-- Internal state (session-scoped)
-- ============================================================================

M._both = {
  pending = false,
  phase = nil, -- "ios" | "android" | nil
  active_config = nil, -- overrides platform_map during "both" run
  last_run_args = nil,
  ios_results = nil,
}

M._metro_job_id = nil
M._metro_buf = nil

-- ============================================================================
-- E2E root detection (luv-safe, works in async context)
-- ============================================================================

function M.get_e2e_subdir(subdir)
  local root = uv.cwd()
  local e2e_dir = root .. "/e2e/" .. subdir
  local stat = uv.fs_stat(e2e_dir)
  if stat and stat.type == "directory" then
    return e2e_dir
  end
  local pattern = "(.*/e2e/" .. subdir .. ")"
  local match = root:match(pattern)
  if match then
    return match
  end
  return nil
end

function M.get_e2e_desktop_root()
  return M.get_e2e_subdir("desktop")
end

function M.get_e2e_mobile_root()
  return M.get_e2e_subdir("mobile")
end

-- True if `root` looks like the ledger-live monorepo (has one of the apps).
function M.is_ledger_root(root)
  if not root or root == "" then
    return false
  end
  return uv.fs_stat(root .. "/apps/ledger-live-desktop") ~= nil or uv.fs_stat(root .. "/apps/ledger-live-mobile") ~= nil
end

function M.get_repo_root()
  local cwd = uv.cwd()
  if uv.fs_stat(cwd .. "/e2e/mobile") then
    return cwd
  end
  local match = cwd:match("(.+)/e2e/mobile")
  if match then
    return match
  end
  local dir = cwd
  while dir and dir ~= "/" do
    if uv.fs_stat(dir .. "/e2e/mobile") then
      return dir
    end
    dir = dir:match("(.+)/[^/]+$")
  end
  return cwd
end

-- ============================================================================
-- Config accessors
-- ============================================================================

function M.get_detox_config()
  if M._both.active_config then
    return M._both.active_config
  end
  return M.platform_map[M.config.platform] or "ios.sim.debug"
end

function M.get_active_configs()
  if M.config.platform == "both" then
    return { M.platform_map.ios, M.platform_map.android }
  end
  return { M.get_detox_config() }
end

function M.needs_metro()
  for _, c in ipairs(M.get_active_configs()) do
    if c:match("^ios%.sim%.debug") then
      return true
    end
  end
  return false
end

-- ============================================================================
-- Build detection
-- ============================================================================

function M.check_build(config)
  local root = M.get_repo_root()
  local rel_path = M.binary_paths[config]
  if not rel_path then
    return true
  end
  local stat = uv.fs_stat(root .. "/" .. rel_path)
  return stat ~= nil
end

function M.get_missing_builds()
  local missing = {}
  for _, c in ipairs(M.get_active_configs()) do
    if not M.check_build(c) then
      table.insert(missing, c)
    end
  end
  return missing
end

-- ============================================================================
-- Terminal management
-- ============================================================================

local function open_float_terminal(cmd, title)
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. (title or "Detox") .. " ",
    title_pos = "center",
  })
  vim.fn.termopen(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          vim.notify((title or "Command") .. " completed", vim.log.levels.INFO)
        else
          vim.notify((title or "Command") .. " failed (exit " .. code .. ")", vim.log.levels.ERROR)
        end
      end)
    end,
  })
  vim.cmd("startinsert")
end

local function open_split_terminal(cmd, title)
  vim.cmd("botright 15split")
  vim.fn.termopen(cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          vim.notify((title or "Command") .. " completed", vim.log.levels.INFO)
        else
          vim.notify((title or "Command") .. " failed (exit " .. code .. ")", vim.log.levels.ERROR)
        end
      end)
    end,
  })
  vim.cmd("startinsert")
end

function M.open_terminal(cmd, title)
  if M.config.build_terminal == "float" then
    open_float_terminal(cmd, title)
  else
    open_split_terminal(cmd, title)
  end
end

-- ============================================================================
-- Build commands
-- ============================================================================

function M.build(config)
  config = config or M.get_detox_config()
  local cmd = M.build_cmds[config]
  if not cmd then
    vim.notify("No build command for: " .. config, vim.log.levels.ERROR)
    return
  end
  local root = M.get_repo_root()
  M.open_terminal("cd " .. root .. " && " .. cmd, "Build " .. config)
end

-- ============================================================================
-- Metro management
-- ============================================================================

function M.start_metro()
  if M._metro_job_id then
    vim.notify("Metro already running", vim.log.levels.INFO)
    return
  end
  if M.is_metro_running() then
    vim.notify("Metro already running (external process on :8081)", vim.log.levels.INFO)
    return
  end
  local root = M.get_repo_root()
  vim.cmd("botright 8split")
  local buf = vim.api.nvim_get_current_buf()
  M._metro_job_id = vim.fn.termopen("cd " .. root .. " && pnpm mobile start", {
    on_exit = function()
      vim.schedule(function()
        M._metro_job_id = nil
        M._metro_buf = nil
        vim.notify("Metro bundler stopped", vim.log.levels.INFO)
      end)
    end,
  })
  M._metro_buf = buf
  vim.cmd("wincmd p")
  vim.notify("Metro bundler starting...", vim.log.levels.INFO)
end

function M.stop_metro()
  if M._metro_job_id then
    vim.fn.jobstop(M._metro_job_id)
    M._metro_job_id = nil
    if M._metro_buf and vim.api.nvim_buf_is_valid(M._metro_buf) then
      vim.api.nvim_buf_delete(M._metro_buf, { force = true })
    end
    M._metro_buf = nil
    vim.notify("Metro bundler stopped", vim.log.levels.INFO)
  else
    vim.notify("Metro not running", vim.log.levels.WARN)
  end
end

function M.toggle_metro()
  if M._metro_job_id then
    M.stop_metro()
  else
    M.start_metro()
  end
end

function M.is_metro_running()
  local handle = io.popen("lsof -i :8081 -sTCP:LISTEN 2>/dev/null | head -1")
  if not handle then
    return false
  end
  local result = handle:read("*a")
  handle:close()
  return result ~= nil and result ~= ""
end

-- ============================================================================
-- Pre-run checks (sync context only — call from keymaps, NOT from build_spec)
-- ============================================================================

function M.pre_run_check()
  if M.config.auto_build_check then
    local missing = M.get_missing_builds()
    if #missing > 0 then
      local msg = "Build missing: " .. table.concat(missing, ", ")
      local choice = vim.fn.confirm(msg, "&Build\n&Run anyway\n&Cancel", 3)
      if choice == 1 then
        for _, c in ipairs(missing) do
          M.build(c)
        end
        return false
      elseif choice == 3 or choice == 0 then
        return false
      end
    end
  end

  if M.config.auto_metro and M.needs_metro() then
    if not M.is_metro_running() and not M._metro_job_id then
      M.start_metro()
      vim.notify("Metro starting — re-run test once bundler is ready", vim.log.levels.INFO)
    end
  end

  return true
end

-- ============================================================================
-- Smart run (pre-checks + "both" mode dispatch)
-- Call from keymaps — wraps neotest.run.run() with Detox awareness.
-- ============================================================================

function M.smart_run(mode)
  mode = mode or "nearest"
  local file = vim.fn.expand("%:p")
  local is_mobile = file:match("e2e/mobile/") ~= nil

  if is_mobile and not M.pre_run_check() then
    return
  end

  local neotest = require("neotest")

  if is_mobile and M.config.platform == "both" then
    M._both.pending = true
    M._both.phase = "ios"
    M._both.active_config = M.platform_map.ios
    M._both.ios_results = nil

    if mode == "nearest" then
      M._both.last_run_args = nil
      neotest.run.run()
    elseif mode == "file" then
      M._both.last_run_args = file
      neotest.run.run(file)
    elseif mode == "all" then
      local cwd = uv.cwd()
      M._both.last_run_args = cwd
      neotest.run.run(cwd)
    end
    return
  end

  if mode == "nearest" then
    neotest.run.run()
  elseif mode == "file" then
    neotest.run.run(file)
  elseif mode == "all" then
    neotest.run.run(uv.cwd())
  end
end

-- ============================================================================
-- "Both" mode: neotest consumer results handler
-- Register via opts.consumers in neotest config.
-- ============================================================================

function M.on_results(adapter_id, results, partial)
  if partial or not M._both.pending then
    return
  end
  if not adapter_id:match("neotest%-jest") then
    return
  end

  if M._both.phase == "ios" then
    M._both.ios_results = results
    M._both.phase = "android"
    M._both.active_config = M.platform_map.android
    vim.schedule(function()
      vim.notify("iOS complete — starting Android...", vim.log.levels.INFO)
      local neotest = require("neotest")
      local args = M._both.last_run_args
      if args then
        neotest.run.run(args)
      else
        neotest.run.run()
      end
    end)
  elseif M._both.phase == "android" then
    M._both.pending = false
    M._both.phase = nil
    M._both.active_config = nil

    vim.schedule(function()
      local ip, if_ = M._count_results(M._both.ios_results or {})
      local ap, af = M._count_results(results)
      local total_fail = if_ + af
      vim.notify(
        string.format(
          "Detox Both Complete:\n  iOS: %d passed, %d failed\n  Android: %d passed, %d failed",
          ip,
          if_,
          ap,
          af
        ),
        total_fail > 0 and vim.log.levels.WARN or vim.log.levels.INFO
      )
      M._both.ios_results = nil
      M._both.last_run_args = nil
    end)
  end
end

function M._count_results(results)
  local pass, fail = 0, 0
  for _, r in pairs(results) do
    if r.status == "passed" then
      pass = pass + 1
    elseif r.status == "failed" then
      fail = fail + 1
    end
  end
  return pass, fail
end

return M
