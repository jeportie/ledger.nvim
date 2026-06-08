local detox = require("ledger.detox")

local M = {}

local function in_ledger_live()
  if detox.get_e2e_desktop_root() or detox.get_e2e_mobile_root() then
    return true
  end
  local cwd = vim.fn.getcwd()
  if cwd:match("[Ll]edger%-?[Ll]ive") then
    return true
  end
  local dir = cwd
  for _ = 1, 8 do
    if
      vim.fn.isdirectory(dir .. "/apps/ledger-live-desktop") == 1
      or vim.fn.isdirectory(dir .. "/apps/ledger-live-mobile") == 1
    then
      return true
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir or parent == "" then
      break
    end
    dir = parent
  end
  return false
end

local _seed_cache = nil
local function get_seed()
  if _seed_cache then
    return _seed_cache
  end
  if not in_ledger_live() then
    return ""
  end
  local seed = os.getenv("SEED")
  if seed and seed ~= "" then
    _seed_cache = seed
    return seed
  end
  local result = vim.fn.system('security find-generic-password -a "$USER" -s ledger-e2e-seed -w 2>/dev/null')
  if vim.v.shell_error == 0 and result and result ~= "" then
    _seed_cache = result:gsub("%s+$", "")
    return _seed_cache
  end
  vim.notify("SEED not available — check keychain item 'ledger-e2e-seed' or export SEED", vim.log.levels.WARN)
  return ""
end

M.in_ledger_live = in_ledger_live
M.get_seed = get_seed

local function playwright_adapter()
  return require("neotest-playwright").adapter({
    options = {
      persist_project_selection = true,
      enable_dynamic_test_discovery = true,

      get_playwright_binary = function()
        local root = detox.get_e2e_desktop_root()
        if root then
          return root .. "/node_modules/.bin/playwright"
        end
        return "./node_modules/.bin/playwright"
      end,

      get_playwright_config = function()
        local root = detox.get_e2e_desktop_root()
        if root then
          return root .. "/playwright.config.ts"
        end
        return "playwright.config.ts"
      end,

      get_cwd = function()
        return detox.get_e2e_desktop_root() or (vim.uv or vim.loop).cwd()
      end,

      env = {
        MOCK = os.getenv("MOCK") or "0",
        SEED = get_seed(),
        COINAPPS = os.getenv("COINAPPS") or "",
        SPECULOS_IMAGE_TAG = os.getenv("SPECULOS_IMAGE_TAG") or "",
        SPECULOS_DEVICE = os.getenv("SPECULOS_DEVICE") or "nanoSP",
        DISABLE_TRANSACTION_BROADCAST = os.getenv("DISABLE_TRANSACTION_BROADCAST") or "1",
      },

      filter_dir = function(name)
        return name ~= "node_modules" and name ~= "allure-results" and name ~= "artifacts"
      end,

      is_test_file = function(file_path)
        return file_path:match("e2e/desktop/.*%.spec%.ts$") ~= nil
      end,
    },
  })
end

local function detox_adapter()
  return require("neotest-jest")({
    jestCommand = function()
      local root = detox.get_e2e_mobile_root()
      local bin = root and (root .. "/node_modules/.bin/detox") or "detox"
      return bin .. " test -c " .. detox.get_detox_config() .. " --"
    end,

    jestConfigFile = function()
      local root = detox.get_e2e_mobile_root()
      return root and (root .. "/jest.config.js") or "jest.config.js"
    end,

    cwd = function()
      return detox.get_e2e_mobile_root() or (vim.uv or vim.loop).cwd()
    end,

    env = function(specEnv)
      local root = detox.get_e2e_mobile_root()
      local bin_path = root and (root .. "/node_modules/.bin") or ""
      return vim.tbl_extend("force", {
        MOCK = os.getenv("MOCK") or "0",
        SEED = get_seed(),
        SPECULOS_DEVICE = os.getenv("SPECULOS_DEVICE") or "nanoSP",
        SPECULOS_IMAGE_TAG = os.getenv("SPECULOS_IMAGE_TAG") or "",
        DISABLE_TRANSACTION_BROADCAST = os.getenv("DISABLE_TRANSACTION_BROADCAST") or "1",
        PATH = bin_path .. ":" .. (os.getenv("PATH") or ""),
      }, specEnv or {})
    end,

    isTestFile = function(file_path)
      return file_path ~= nil and file_path:match("e2e/mobile/specs/.*%.spec%.ts$") ~= nil
    end,
  })
end

function M.apply(opts)
  opts = opts or {}

  opts.run = opts.run or {}
  local prev_augment = opts.run.augment
  opts.run.augment = function(tree, args)
    if vim.g._neotest_pw_debug then
      vim.g._neotest_pw_debug = false
      args.extra_args = args.extra_args or {}
      table.insert(args.extra_args, "--debug")
    end
    if vim.g._neotest_detox_debug then
      vim.g._neotest_detox_debug = false
      args.env = args.env or {}
      args.env.DEBUG_DETOX = "1"
    end
    if prev_augment then
      return prev_augment(tree, args)
    end
    return args
  end

  opts.consumers = opts.consumers or {}
  opts.consumers.detox_both = function(client)
    client.listeners.results = function(adapter_id, results, partial)
      detox.on_results(adapter_id, results, partial)
    end
    return {}
  end

  opts.floating = opts.floating
    or {
      border = "rounded",
      options = {
        winhighlight = "FloatBorder:XrayBorder,NormalFloat:XrayNormal",
      },
    }

  opts.adapters = opts.adapters or {}

  opts.adapters["neotest-vitest"] = opts.adapters["neotest-vitest"]
    or {
      command = "npx vitest",
      cwd = function(path)
        return require("lspconfig.util").root_pattern("vitest.config.ts", "package.json", ".git")(path)
      end,
    }

  opts.adapters["neotest-ctest"] = opts.adapters["neotest-ctest"] or {}

  table.insert(opts.adapters, playwright_adapter())
  table.insert(opts.adapters, detox_adapter())

  return opts
end

function M.register_commands()
  vim.api.nvim_create_user_command("NeotestDetoxPlatform", function()
    local platforms = { "ios", "android", "both" }
    vim.ui.select(platforms, {
      prompt = "Detox platform:",
      format_item = function(item)
        local marker = detox.config.platform == item and "* " or "  "
        return marker .. detox.platform_labels[item]
      end,
    }, function(choice)
      if choice then
        detox.config.platform = choice
        if choice == "both" then
          detox.config.both_mode = detox.config.both_mode or "sequential"
        end
        vim.notify("Detox: " .. detox.platform_labels[choice])
      end
    end)
  end, { desc = "Select Detox platform (iOS / Android / Both)" })

  vim.api.nvim_create_user_command("NeotestDetoxBuild", function(cmd_opts)
    local config = cmd_opts.args ~= "" and cmd_opts.args or nil
    if config then
      detox.build(config)
    else
      local configs = detox.get_active_configs()
      if #configs == 1 then
        detox.build(configs[1])
      else
        vim.ui.select(configs, { prompt = "Build which platform?" }, function(choice)
          if choice then
            detox.build(choice)
          end
        end)
      end
    end
  end, {
    nargs = "?",
    desc = "Build Detox app for current platform",
    complete = function()
      return vim.tbl_keys(detox.build_cmds)
    end,
  })

  vim.api.nvim_create_user_command("NeotestDetoxMetro", function()
    detox.toggle_metro()
  end, { desc = "Toggle Metro bundler" })

  vim.api.nvim_create_user_command("NeotestSmartRun", function(cmd_opts)
    detox.smart_run(cmd_opts.args ~= "" and cmd_opts.args or "nearest")
  end, {
    nargs = "?",
    desc = "Smart test run with Detox pre-checks",
    complete = function()
      return { "nearest", "file", "all" }
    end,
  })
end

return M
