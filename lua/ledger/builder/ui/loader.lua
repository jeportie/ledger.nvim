-- ledger.builder.ui.loader
--
-- A small centered "Loading" float with a braille spinner, shown briefly while
-- the Builder gathers status (port/docker probes, staleness). Ported from
-- wrapped.nvim's ui/loading.lua. Honors the builder border option and uses the
-- shared highlight namespace for an opaque panel.

local api = vim.api
local M = {}

local st = { buf = nil, win = nil, timer = nil, index = 1 }

-- Open the loader. Returns immediately; call M.close() when ready.
function M.open(text)
  if st.win and api.nvim_win_is_valid(st.win) then
    return
  end
  text = text or "Loading Ledger Builder"
  local cfg = require("ledger.config").get().builder or {}
  local border = cfg.border and "single" or "none"
  local pattern = require("ledger.builder.ui.spin").get(cfg.spinner and cfg.spinner.loader)
  local frames = pattern.frames
  local interval = pattern.interval or 80

  -- widest frame so a multi-cell pattern (e.g. material) never overflows
  local maxfw = 1
  for _, f in ipairs(frames) do
    maxfw = math.max(maxfw, vim.fn.strdisplaywidth(f))
  end

  local pad = 2
  local tw = vim.fn.strdisplaywidth(text)
  local w = pad * 2 + tw + 1 + maxfw
  local h = 1 + 2
  st.buf = api.nvim_create_buf(false, true)
  st.win = api.nvim_open_win(st.buf, false, {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2) - 1,
    col = math.floor((vim.o.columns - w) / 2),
    style = "minimal",
    border = border,
    zindex = 300,
  })
  local hl = require("ledger.builder.ui.hl")
  local ns = hl.setup()
  pcall(api.nvim_win_set_hl_ns, st.win, ns)

  local blank = string.rep(" ", w)
  api.nvim_buf_set_lines(st.buf, 0, -1, false, { blank, "", blank })

  st.index = 1
  st.timer = vim.uv.new_timer()
  st.timer:start(
    0,
    interval,
    vim.schedule_wrap(function()
      if not (st.buf and api.nvim_buf_is_valid(st.buf)) then
        return
      end
      st.index = (st.index % #frames) + 1
      local frame = frames[st.index]
      local prefix = string.rep(" ", pad)
      api.nvim_buf_set_lines(st.buf, 1, 2, false, { prefix .. text .. " " .. frame })
      pcall(api.nvim_buf_set_extmark, st.buf, ns, 1, pad, {
        id = 1,
        end_col = pad + #text + 1 + #frame,
        hl_group = "LedgerBlue0",
      })
    end)
  )
end

function M.close()
  if st.timer then
    st.timer:stop()
    if not st.timer:is_closing() then
      st.timer:close()
    end
    st.timer = nil
  end
  if st.win and api.nvim_win_is_valid(st.win) then
    pcall(api.nvim_win_close, st.win, true)
  end
  if st.buf and api.nvim_buf_is_valid(st.buf) then
    pcall(api.nvim_buf_delete, st.buf, { force = true })
  end
  st.win, st.buf, st.index = nil, nil, 1
end

return M
