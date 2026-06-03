local M = {}

local icons = require("ledger.jira.icons")
local hl = require("ledger.jira.board.ui.hl")

local function dw(s) return vim.fn.strdisplaywidth(s or "") end

local function present(v)
  if v == nil then return nil end
  if v == vim.NIL then return nil end
  return v
end

local function pad_right(s, w)
  local n = w - dw(s)
  if n <= 0 then return s end
  return s .. string.rep(" ", n)
end

local function initials(display_name)
  if not display_name or display_name == "" then return "—" end
  local parts = {}
  for p in string.gmatch(display_name, "%S+") do
    table.insert(parts, p)
    if #parts == 2 then break end
  end
  if #parts == 0 then return "—" end
  local out = ""
  for _, p in ipairs(parts) do
    out = out .. string.upper(p:sub(1, 1))
  end
  return out
end

local function truncate(s, w)
  s = s or ""
  if dw(s) <= w then return s end
  if w <= 1 then return "…" end
  local total = vim.fn.strchars(s)
  local lo, hi = 0, total
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    local piece = vim.fn.strcharpart(s, 0, mid)
    if dw(piece) <= w - 1 then lo = mid else hi = mid - 1 end
  end
  return vim.fn.strcharpart(s, 0, lo) .. "…"
end

local function wrap_summary(s, w, max_lines)
  s = (s or ""):gsub("\r", ""):gsub("\n", " ")
  local words = {}
  for tok in string.gmatch(s, "%S+") do table.insert(words, tok) end
  local lines, cur = {}, ""
  local i = 1
  while i <= #words do
    local word = words[i]
    local candidate = cur == "" and word or (cur .. " " .. word)
    if dw(candidate) <= w then
      cur = candidate
      i = i + 1
    else
      if cur ~= "" then
        table.insert(lines, cur)
        cur = ""
        if #lines >= max_lines then break end
      else
        table.insert(lines, truncate(word, w))
        i = i + 1
        if #lines >= max_lines then break end
      end
    end
  end
  if cur ~= "" and #lines < max_lines then table.insert(lines, cur) end

  -- If not all words fit, append ellipsis to the last line
  local consumed = 0
  for _, l in ipairs(lines) do
    for _ in string.gmatch(l, "%S+") do consumed = consumed + 1 end
  end
  if consumed < #words and #lines > 0 then
    lines[#lines] = truncate(lines[#lines] .. " …", w)
  end

  while #lines < max_lines do table.insert(lines, "") end
  return lines
end

-- Render a single card as 5 Volt lines.
-- selected=true swaps card hls to their Sel variants.
-- actions (optional): volt action table attached to every card segment so any
-- click on the card triggers the same callback.
function M.render(issue, width, selected, actions, status_actions)
  width = width or 30
  local inner = width - 2
  local key = issue.key or "???"
  local fields = issue.fields or {}
  local summary = present(fields.summary) or ""
  local pr = present(fields.priority)
  local priority = pr and present(pr.name) or ""
  local a = present(fields.assignee)
  local assignee = a and present(a.displayName) or ""
  local st = present(fields.status)
  local status = st and present(st.name) or ""

  local hl_card   = selected and "JiraBoardCardSel"    or "JiraBoardCard"
  local hl_key    = selected and "JiraBoardCardSelKey" or "JiraBoardCardKey"
  local hl_sum    = selected and "JiraBoardCardSel"    or "JiraBoardCardSum"
  local hl_muted  = selected and "JiraBoardCardSelMuted" or "JiraBoardCardMuted"
  local hl_init   = selected and "JiraBoardCardSelKey" or "JiraBoardCardInit"

  -- Line 1: key (left) + priority chip (right)
  local pri_icon = icons.priority(priority)
  local pri_chip_txt = ""
  local pri_chip_w = 0
  if priority ~= "" then
    pri_chip_txt = " " .. (pri_icon ~= "" and (pri_icon .. " ") or "") .. priority:sub(1, 1) .. " "
    pri_chip_w = dw(pri_chip_txt)
  end
  local key_w = dw(key)
  local spacer_w = inner - key_w - pri_chip_w
  if spacer_w < 1 then
    local trim = math.max(0, -(spacer_w - 1))
    key = truncate(key, key_w - trim - 1)
    spacer_w = inner - dw(key) - pri_chip_w
    if spacer_w < 1 then spacer_w = 1 end
  end
  local line1 = {
    { " ", hl_card },
    { key, hl_key },
    { string.rep(" ", spacer_w), hl_card },
  }
  if pri_chip_w > 0 then
    local pri_hl = hl.priority_hl(priority)
    table.insert(line1, { pri_chip_txt, pri_hl })
  end
  table.insert(line1, { " ", hl_card })

  -- Lines 2-3: summary
  local summary_lines = wrap_summary(summary, inner, 2)
  local s1 = {
    { " ", hl_card },
    { pad_right(summary_lines[1], inner), hl_sum },
    { " ", hl_card },
  }
  local s2 = {
    { " ", hl_card },
    { pad_right(summary_lines[2], inner), hl_sum },
    { " ", hl_card },
  }

  -- Line 4: status chip + assignee initials (right-aligned)
  local init_txt = initials(assignee)
  local status_txt = ""
  if status ~= "" then
    status_txt = " " .. icons.status(status) .. " " .. truncate(status, math.max(4, inner - dw(init_txt) - 6)) .. " "
  end
  local status_hl = hl.status_hl(status)
  local status_w = dw(status_txt)
  local init_w = dw(init_txt)
  local mid_pad = inner - status_w - init_w
  if mid_pad < 1 then mid_pad = 1 end

  local line4 = { { " ", hl_card } }
  if status_w > 0 then
    table.insert(line4, { status_txt, status_hl })
  end
  table.insert(line4, { string.rep(" ", mid_pad), hl_card })
  table.insert(line4, { init_txt, hl_init })
  table.insert(line4, { " ", hl_card })

  -- Line 5: inter-card gap (board bg)
  local gap = { { string.rep(" ", width), "JiraBoardColGap" } }

  local lines = { line1, s1, s2, line4, gap }
  if actions then
    for li, line in ipairs(lines) do
      -- Skip the trailing gap row — clicking on it should not select the card.
      if li < #lines then
        for _, seg in ipairs(line) do seg[3] = actions end
      end
    end
  end
  -- Override the status-chip segment with its own action, so clicking the chip
  -- opens the status transition picker instead of selecting the card.
  if status_actions and status_w > 0 then
    -- line4 layout: [leading pad][status_txt][mid_pad][init_txt][trailing pad]
    -- So the status segment is at index 2.
    local status_seg = line4[2]
    if status_seg then status_seg[3] = status_actions end
  end
  return lines, { key = key, height = 5 }
end

M.CARD_HEIGHT = 5

return M
