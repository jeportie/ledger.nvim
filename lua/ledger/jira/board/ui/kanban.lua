local M = {}

local store = require("ledger.jira.board.store")
local card = require("ledger.jira.board.ui.card")
local cfg = require("ledger.jira.board.config")

local function dw(s) return vim.fn.strdisplaywidth(s or "") end

local function pad_right(s, w)
  local n = w - dw(s)
  if n <= 0 then return s end
  return s .. string.rep(" ", n)
end

local function truncate(s, w)
  s = s or ""
  if dw(s) <= w then return s end
  if w <= 1 then return "…" end
  return s:sub(1, math.max(0, w - 1)) .. "…"
end

local function compute_col_width(screen_w, ncols)
  local pad = 1
  local usable = screen_w - 2
  local w = math.floor(usable / math.max(1, ncols)) - pad
  local c = cfg.get()
  if w < c.card_min_width then w = c.card_min_width end
  if w > c.card_max_width then w = c.card_max_width end
  return w
end

local function col_header_lines(col, count, col_w)
  local title = col.name or "Column"
  local right = " " .. count .. " "
  local left_budget = col_w - dw(right) - 3
  if dw(title) > left_budget then
    title = truncate(title, left_budget)
  end
  local spacer = col_w - dw(title) - dw(right) - 2
  if spacer < 1 then spacer = 1 end
  local header = {
    { " ", "JiraBoardColHdr" },
    { title, "JiraBoardColHdr" },
    { string.rep(" ", spacer), "JiraBoardColHdr" },
    { right, "JiraBoardColCount" },
    { " ", "JiraBoardColHdr" },
  }
  local rule = { { string.rep("─", col_w), "JiraBoardColRule" } }
  local gap  = { { string.rep(" ", col_w), "JiraBoardColGap" } }
  return { header, rule, gap }
end

local function empty_col_line(col_w)
  return { { string.rep(" ", col_w), "JiraBoardColGap" } }
end

local function pad_columns(col_sections)
  local max_h = 0
  for _, s in ipairs(col_sections) do
    if #s.lines > max_h then max_h = #s.lines end
  end
  for _, s in ipairs(col_sections) do
    while #s.lines < max_h do
      table.insert(s.lines, { { string.rep(" ", s.w), "JiraBoardColGap" } })
    end
  end
  return max_h
end

local function divider_lines(h)
  local lines = {}
  for _ = 1, h do
    table.insert(lines, { { "│", "JiraBoardColRule" } })
  end
  return lines
end

local function epic_header_line(band, board_w, collapsed, toggle_action)
  local key = band.key or "No Epic"
  local summary = band.summary or ""
  local count_str = band.total == 1 and "1 issue" or (band.total .. " issues")
  local icon = collapsed and "▸ " or "▾ "
  local mid_budget = board_w - dw(icon) - dw(key) - dw(count_str) - 4
  if mid_budget < 0 then mid_budget = 0 end
  local sum_txt = ""
  if summary ~= "" and mid_budget > 3 then
    sum_txt = "  " .. truncate(summary, mid_budget - 2)
  end
  local used = dw(icon) + dw(key) + dw(sum_txt) + dw(count_str) + 2
  local spacer = board_w - used
  if spacer < 1 then spacer = 1 end
  local actions = toggle_action and { click = toggle_action } or nil
  return {
    { " ",                         "JiraBoardEpicHdr", actions },
    { icon,                        "JiraBoardEpicHdr", actions },
    { key,                         "JiraBoardEpicHdr", actions },
    { sum_txt,                     "JiraBoardEpicSum", actions },
    { string.rep(" ", spacer),     "JiraBoardEpicHdr", actions },
    { count_str,                   "JiraBoardEpicSum", actions },
    { " ",                         "JiraBoardEpicHdr", actions },
  }
end

-- Build a single band: epic header + column headers + cards grouped by column.
-- Returns: { lines = {...}, cards_offset = int (0-based row where first card can live
--           relative to the first line of this band), col_heights = {...} }
local function build_band(band, band_idx, vcols, col_w, board_w, selected_card_key, collapsed)
  local lines = {}
  local toggle_action = function()
    require("ledger.jira.board.actions").toggle_epic(band.key)
  end
  -- 1. Epic header row
  table.insert(lines, epic_header_line(band, board_w, collapsed, toggle_action))

  if collapsed then
    -- Collapsed band: just a trailing blank. No column headers or cards.
    table.insert(lines, { { string.rep(" ", board_w), "JiraBoardNormal" } })
    return {
      lines = lines,
      cards_offset = 2, -- no cards reachable, but keep a sane offset
      collapsed = true,
    }
  end

  -- 2. Blank gap under header
  table.insert(lines, { { string.rep(" ", board_w), "JiraBoardNormal" } })

  -- 3. Column sections (header + rule + gap + cards)
  local col_sections = {}
  for vidx, col in ipairs(vcols) do
    local col_lines = {}
    local issues = band.issues_by_col[vidx] or {}
    for _, l in ipairs(col_header_lines(col, #issues, col_w)) do
      table.insert(col_lines, l)
    end
    if #issues == 0 then
      table.insert(col_lines, empty_col_line(col_w))
    else
      for idx, issue in ipairs(issues) do
        local is_sel = selected_card_key == issue.key
        local bi, vi, ci = band_idx, vidx, idx
        local actions = {
          click = function()
            require("ledger.jira.board.ui.window").on_card_click(bi, vi, ci)
          end,
        }
        local status_actions = {
          click = function()
            require("ledger.jira.board.ui.window").on_card_click(bi, vi, ci)
            vim.schedule(function()
              require("ledger.jira.board.actions").transition_selected()
            end)
          end,
        }
        local crendered = card.render(issue, col_w, is_sel, actions, status_actions)
        for _, l in ipairs(crendered) do table.insert(col_lines, l) end
      end
    end
    table.insert(col_sections, { w = col_w, pad = 0, lines = col_lines })
  end

  local body_h = pad_columns(col_sections)

  -- 4. Interleave dividers
  local interleaved = {}
  for i, s in ipairs(col_sections) do
    table.insert(interleaved, s)
    if i < #col_sections then
      table.insert(interleaved, { w = 1, pad = 0, lines = divider_lines(body_h) })
    end
  end
  local grid_col = require("volt.ui.grid_col")
  local body = grid_col(interleaved)
  for _, l in ipairs(body) do table.insert(lines, l) end

  return {
    lines = lines,
    -- cards_offset = lines before cards within this band:
    --   1 (epic hdr) + 1 (blank) + 3 (col hdr + rule + gap) = 5
    cards_offset = 5,
  }
end

function M.build(opts)
  opts = opts or {}
  local screen_w = opts.screen_w or vim.o.columns
  local vcols = store.visible_columns()
  local ncols = #vcols
  if ncols == 0 then
    return { grid = { { { "", "JiraBoardNormal" } } }, board_w = 10, board_h = 1, col_w = 10, ncols = 0, bands = {} }
  end
  local col_w = compute_col_width(screen_w - 4, ncols)
  local board_w = ncols * col_w + (ncols - 1)

  local bands = store.epic_groups()
  if #bands == 0 then
    local line = { { pad_right("  No tickets to display.", board_w), "JiraBoardMuted" } }
    return { grid = { line }, board_w = board_w, board_h = 1, col_w = col_w, ncols = ncols, bands = {} }
  end

  local grid = {}
  local band_meta = {}
  for i, band in ipairs(bands) do
    local start_row = #grid -- 0-based first line of this band within grid
    local collapsed = store.is_epic_collapsed(band.key)
    local built = build_band(band, i, vcols, col_w, board_w, opts.selected_card_key, collapsed)
    for _, l in ipairs(built.lines) do table.insert(grid, l) end
    -- When collapsed, expose an empty issues_by_col so navigation skips over it.
    local visible_issues_by_col = band.issues_by_col
    if collapsed then
      visible_issues_by_col = {}
      for vi = 1, #vcols do visible_issues_by_col[vi] = {} end
    end
    table.insert(band_meta, {
      key = band.key,
      summary = band.summary,
      total = band.total,
      issues_by_col = visible_issues_by_col,
      start_row = start_row,
      cards_offset = built.cards_offset,
      end_row = #grid - 1, -- inclusive
      collapsed = collapsed,
    })
    if i < #bands then
      -- blank separator line between bands
      table.insert(grid, { { string.rep(" ", board_w), "JiraBoardColGap" } })
    end
  end

  return {
    grid = grid,
    board_w = board_w,
    board_h = #grid,
    col_w = col_w,
    ncols = ncols,
    bands = band_meta,
  }
end

return M
