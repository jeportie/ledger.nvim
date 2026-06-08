local M = {}

local config = require("ledger.xray.config")

local function define_highlights()
  local groups = {
    XrayTitle = { link = "Title" },
    XrayTitleFloat = { link = "FloatTitle" },
    XrayBorder = { link = "FloatBorder" },
    XrayNormal = { link = "NormalFloat" },
    XrayKey = { link = "Special" },
    XrayLabel = { link = "Comment" },
    XrayValue = { link = "Normal" },
    XrayType = { link = "Type" },
    XrayPerson = { link = "Function" },
    XrayChip = { link = "String" },
    XrayPlatform = { link = "Keyword" },
    XrayFooter = { link = "Comment" },
    XrayMuted = { link = "Comment" },
    XrayStatusOk = { link = "DiagnosticOk" },
    XrayStatusWarn = { link = "DiagnosticWarn" },
    XrayStatusInfo = { link = "DiagnosticInfo" },
    XrayStatusError = { link = "DiagnosticError" },
    XrayStatusMuted = { link = "Comment" },
    XrayPriorityHigh = { link = "DiagnosticError" },
    XrayPriorityMedium = { link = "DiagnosticWarn" },
    XrayPriorityLow = { link = "Comment" },
    XraySection = { link = "Comment" },
    XraySelected = { link = "Visual" },
    XrayPrompt = { link = "Question" },
    XrayEditFocus = { link = "Search", bold = true },

    XrayTitleLoading = { fg = "#ffffff", bg = "#cc3333", bold = true },
    XrayTitleLoaded = { fg = "#ffffff", bg = "#228b22", bold = true },
    XrayBorderLoading = { fg = "#cc3333" },
    XrayBorderLoaded = { fg = "#228b22" },
  }
  for name, def in pairs(groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
  end
end

local function k_handler()
  local id = require("ledger.xray.util").cword_id()
  if id then
    require("ledger.xray.hover").trigger(id)
    return
  end
  vim.cmd("Lspsaga hover_doc")
end

local function install_buffer_k(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.keymap.set("n", "K", k_handler, {
    buffer = buf,
    desc = "Xray/LSP hover",
  })
end

local function install_k_everywhere()
  vim.keymap.set("n", "K", k_handler, { desc = "Xray/LSP hover" })

  vim.api.nvim_create_autocmd({ "LspAttach", "BufEnter" }, {
    group = vim.api.nvim_create_augroup("xray_k_immediate", { clear = true }),
    callback = function(args)
      vim.schedule(function()
        install_buffer_k(args.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "LspAttach", "BufEnter" }, {
    group = vim.api.nvim_create_augroup("xray_k_deferred", { clear = true }),
    callback = function(args)
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(args.buf) then
          install_buffer_k(args.buf)
        end
      end, 300)
    end,
  })

  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("xray_k_vimenter", { clear = true }),
    once = true,
    callback = function()
      for _, delay in ipairs({ 50, 300, 1000 }) do
        vim.defer_fn(function()
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) then
              install_buffer_k(buf)
            end
          end
        end, delay)
      end
    end,
  })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.schedule(function()
        install_buffer_k(buf)
      end)
    end
  end

  local orig_hover = vim.lsp.buf.hover
  vim.lsp.buf.hover = function(...)
    local id = require("ledger.xray.util").cword_id()
    if id then
      require("ledger.xray.hover").trigger(id)
      return
    end
    return orig_hover(...)
  end
end

function M.setup(opts)
  config.setup(opts)
  define_highlights()
  install_k_everywhere()
  require("ledger.xray.prefetch").setup()

  vim.defer_fn(function()
    pcall(function()
      require("ledger.xray.ui.picker").prefetch_list()
    end)
  end, 500)

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("xray_colors", { clear = true }),
    callback = define_highlights,
  })
end

function M.show(key)
  if not key or not key:match("^[%w]+%-%d+$") then
    vim.notify("xray: invalid ticket key: " .. tostring(key), vim.log.levels.ERROR)
    return
  end
  require("ledger.xray.hover").trigger(key)
end

function M.hover_or_fallback()
  require("ledger.xray.hover").hover_or_lsp()
end

function M.search()
  require("ledger.xray.ui.picker").open()
end

function M.insert_at_cursor(key)
  require("ledger.xray.insert").smart_insert(key)
end

function M.coverage()
  require("ledger.xray.pickers.coverage").run()
end

return M
