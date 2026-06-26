local M = {}

M.defaults = {
  jira = {
    project_key = "QAA",
    board_name = "Team QA Automation",
  },
  xray = {
    project_key = "B2CQA",
  },
  monorepo_root = nil,
  coinapps_path = nil,
  speculos = {
    device = "nanoSP",
    image_tag = "ghcr.io/ledgerhq/speculos:latest",
  },
  seed = {
    keychain_service = "ledger-e2e-seed",
    env_var = "SEED",
  },
  builder = {
    border = false, -- borderless + filled title bar; true = single border (no title)
    transparent = false, -- opaque panel by default; true = see-through
    loader = true, -- show the loader animation on open
    animation = "max", -- "max" | "tasteful" | "minimal" | "off"
    backdrop = true, -- dim the rest of the editor while open
    -- TEMP (visual review only): seed the Stats panes with per-target mock data
    -- when there's no real history yet. Set false / remove once the look is approved.
    mock_stats = true,
    -- where Playwright installs its browser binaries (once per machine). Leave
    -- nil to auto-detect per OS ($PLAYWRIGHT_BROWSERS_PATH, then the OS default:
    -- ~/Library/Caches/ms-playwright on macOS, ~/.cache/ms-playwright on Linux);
    -- set a path to force it.
    pw_browsers_path = nil,
    -- the Run-tests pipeline row's icon (nf-md-flask).
    test_icon = "󰂓",
    -- the clean step's bullet icon (nf-md-broom) — shown instead of a number.
    clean_icon = "󰃢",
    -- watcher command for the "nx" watch mode (nx watch daemon).
    watch_cmd = "pnpm nx watch --all -- pnpm nx build $NX_PROJECT_NAME",
    -- watch mode started on open: "on-save" (Neovim rebuilds the saved file's nx
    -- project — daemon-free, reliable here), "nx" (nx watch daemon), or "off".
    watch_default = "on-save",
    -- spinner.nvim patterns per role (see lua/ledger/builder/ui/spin.lua).
    -- Any name from require("spinner.pattern") works; falls back to dotsCircle.
    spinner = {
      loader = "dotsCircle", -- the loader float on open
      pipeline = "dots", -- the running-step glyph in the pipeline State column
      step = "star", -- the pipeline Step-column bullet, animated while running
      -- "material" is reserved for a future spot (e.g. a footer build shimmer)
    },
  },
}

M.opts = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.defaults, opts or {})

  if M.opts.jira then
    local jcfg = require("ledger.jira.config")
    if jcfg and type(jcfg) == "table" and jcfg.set then
      jcfg.set(M.opts.jira)
    end
  end

  if M.opts.xray then
    local ok, xray = pcall(require, "ledger.xray")
    if ok and xray.setup then
      xray.setup({ project_key = M.opts.xray.project_key })
    end
  end

  if M.opts.jira and M.opts.jira.project_key then
    local ok, board = pcall(require, "ledger.jira.board")
    if ok and board.setup then
      board.setup({
        project_key = M.opts.jira.project_key,
        board_name = M.opts.jira.board_name,
      })
    end
  end

  -- Builder backend: :LedgerTask / :LedgerTasks
  local ok_tasks, tasks = pcall(require, "ledger.tasks")
  if ok_tasks and tasks.register_commands then
    tasks.register_commands()
  end

  -- Builder dashboard: :LedgerBuilder
  local ok_builder, builder = pcall(require, "ledger.builder")
  if ok_builder and builder.register_commands then
    builder.register_commands()
  end
end

function M.get()
  return M.opts
end

return M
