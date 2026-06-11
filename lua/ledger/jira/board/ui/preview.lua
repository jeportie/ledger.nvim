local M = {}

local api = vim.api
local volt = require("volt")
local jira_api = require("ledger.jira.api")
local jira_adf = require("ledger.jira.adf")
local jira_util = require("ledger.jira.util")
local hl = require("ledger.jira.board.ui.hl")
local icons = require("ledger.jira.icons")

local function dw(s)
  return vim.fn.strdisplaywidth(s or "")
end

local function present(v)
  if v == nil or v == vim.NIL then
    return nil
  end
  return v
end

local function fresh_state()
  return {
    buf = nil,
    win = nil,
    ns = nil,
    key = nil,
    issue = nil,
    children = nil,
    loading = false,
    error = nil,
  }
end

-- _state = currently active (top-most) preview.
-- _stack = list of previews sitting BELOW the active one. Pushed when the user
-- drills into a sub-issue from within the preview; popped on close.
local _state = fresh_state()
local _stack = {}

-- Forward declaration: close() / refresh_preview_issue() and the closures in
-- build_left/right_panel all call rerender() (assigned much later in the file).
-- Must be declared before close() below or those calls resolve to a global.
local rerender

local function push_state()
  table.insert(_stack, _state)
  _state = fresh_state()
end

local function close()
  if _state.win and api.nvim_win_is_valid(_state.win) then
    pcall(api.nvim_win_close, _state.win, true)
  end
  if _state.buf and api.nvim_buf_is_valid(_state.buf) then
    pcall(api.nvim_buf_delete, _state.buf, { force = true })
  end
  _state = fresh_state()
  if #_stack > 0 then
    _state = table.remove(_stack)
    if _state.win and api.nvim_win_is_valid(_state.win) then
      pcall(api.nvim_set_current_win, _state.win)
    end
    -- Refresh the restored preview in case a fetch completed while it was
    -- pushed under a stacked child preview.
    if rerender then
      pcall(rerender)
    end
  else
    -- No previews left — restore board scroll.
    pcall(function()
      require("ledger.jira.board.ui.window").unlock_scroll()
    end)
  end
end

local function pad_right(s, w)
  local n = w - dw(s)
  if n <= 0 then
    return s
  end
  return s .. string.rep(" ", n)
end

local function truncate(s, w)
  s = s or ""
  if dw(s) <= w then
    return s
  end
  if w <= 1 then
    return "…"
  end
  local total = vim.fn.strchars(s)
  local lo, hi = 0, total
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    local piece = vim.fn.strcharpart(s, 0, mid)
    if dw(piece) <= w - 1 then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return vim.fn.strcharpart(s, 0, lo) .. "…"
end

local function wrap_text(s, w)
  s = (s or ""):gsub("\r", "")
  local paragraphs = {}
  for chunk in (s .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(paragraphs, chunk)
  end
  local out = {}
  for _, para in ipairs(paragraphs) do
    if para == "" then
      table.insert(out, "")
    else
      local words = {}
      for tok in string.gmatch(para, "%S+") do
        table.insert(words, tok)
      end
      if #words == 0 then
        table.insert(out, "")
      else
        local cur = ""
        for _, word in ipairs(words) do
          local candidate = cur == "" and word or (cur .. " " .. word)
          if dw(candidate) <= w then
            cur = candidate
          else
            if cur ~= "" then
              table.insert(out, cur)
            end
            cur = dw(word) <= w and word or truncate(word, w)
          end
        end
        if cur ~= "" then
          table.insert(out, cur)
        end
      end
    end
  end
  return out
end

-- Focus navigation: cycle over volt-registered clickables, grouped by "side"
-- (left = summary + description + lists, right = details panel). The row a
-- clickable sits on is the focus unit; multi-segment clickables collapse to
-- their leftmost col_start.
local function collect_focus_rows(buf)
  local ok, vstate = pcall(require, "volt.state")
  if not ok or not vstate or not vstate[buf] or not vstate[buf].clickables then
    return {}
  end
  local rows = {}
  local divider = _state.divider_col or 0
  for row, list in pairs(vstate[buf].clickables) do
    -- Skip rows 1-2: the ticket-key + close (✕) row, and its rule separator.
    -- They're header decorations, not editable attributes.
    if list and #list > 0 and row > 2 then
      local min_col = math.huge
      for _, item in ipairs(list) do
        if item.col_start < min_col then
          min_col = item.col_start
        end
      end
      table.insert(rows, {
        row = row,
        col = min_col,
        side = (min_col >= divider) and "right" or "left",
      })
    end
  end
  table.sort(rows, function(a, b)
    return a.row < b.row
  end)
  return rows
end

local function render_focus(buf, row)
  _state.focus_ns = _state.focus_ns or api.nvim_create_namespace("jira_board_preview_focus")
  pcall(api.nvim_buf_clear_namespace, buf, _state.focus_ns, 0, -1)
  if not row then
    return
  end
  pcall(api.nvim_buf_set_extmark, buf, _state.focus_ns, row - 1, 0, {
    line_hl_group = "JiraBoardFocus",
    priority = 200,
    hl_eol = true,
  })
end

local function set_focus(buf, target)
  if not target then
    return
  end
  local win = _state.win
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  pcall(api.nvim_win_set_cursor, win, { target.row, target.col })
  render_focus(buf, target.row)
  _state.focus_row = target.row
  _state.focus_side = target.side
end

local function current_focus_idx(rows, cursor_row)
  for i, r in ipairs(rows) do
    if r.row == cursor_row then
      return i
    end
  end
  return nil
end

local function focus_nav(buf, mode)
  local rows = collect_focus_rows(buf)
  if #rows == 0 then
    return
  end
  local win = _state.win
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  local cursor = api.nvim_win_get_cursor(win)
  local cur_row = cursor[1]
  local cur_idx = current_focus_idx(rows, cur_row)
  local cur_side = cur_idx and rows[cur_idx].side or ((cursor[2] >= (_state.divider_col or 0)) and "right" or "left")

  if mode == "toggle_side" then
    local new_side = (cur_side == "left") and "right" or "left"
    local best, best_dist = nil, math.huge
    for _, r in ipairs(rows) do
      if r.side == new_side then
        local d = math.abs(r.row - cur_row)
        if d < best_dist then
          best_dist = d
          best = r
        end
      end
    end
    set_focus(buf, best)
    return
  end

  local step = (mode == "down") and 1 or -1
  -- Start from the cursor's position; if we're already on a focus row, move
  -- off it; otherwise walk until we find a clickable on the same side.
  local start_i = cur_idx or (step > 0 and 0 or #rows + 1)
  local i = start_i + step
  while i >= 1 and i <= #rows do
    if rows[i].side == cur_side then
      set_focus(buf, rows[i])
      return
    end
    i = i + step
  end
  -- Fell off the edge — wrap to the first/last on this side.
  if step > 0 then
    for j = 1, #rows do
      if rows[j].side == cur_side then
        set_focus(buf, rows[j])
        return
      end
    end
  else
    for j = #rows, 1, -1 do
      if rows[j].side == cur_side then
        set_focus(buf, rows[j])
        return
      end
    end
  end
end

local function focus_first(buf)
  local rows = collect_focus_rows(buf)
  if #rows == 0 then
    return
  end
  -- Prefer the first LEFT-side clickable so the user starts on the summary/
  -- description area; fall back to the first clickable.
  for _, r in ipairs(rows) do
    if r.side == "left" then
      set_focus(buf, r)
      return
    end
  end
  set_focus(buf, rows[1])
end

-- Refresh the top-level board view after a preview-driven mutation.
local function refresh_board_in_background()
  pcall(function()
    local win = require("ledger.jira.board.ui.window")
    if win.is_open() then
      require("ledger.jira.board.actions").refresh()
    end
  end)
end

-- Re-fetch the currently-previewed issue into my_state and rerender if this
-- preview is still the active one.
local function refresh_preview_issue(my_state)
  local key = my_state.key
  if not key then
    return
  end
  jira_api.get_issue(key, function(data, err)
    vim.schedule(function()
      if not (my_state.buf and api.nvim_buf_is_valid(my_state.buf)) then
        return
      end
      if err or not data then
        return
      end
      my_state.issue = data
      if my_state == _state and rerender then
        pcall(rerender)
      end
    end)
  end)
end

-- Open the status picker for the previewed issue without closing the preview.
local function trigger_transition()
  local my_state = _state
  if not (my_state and my_state.key) then
    return
  end
  local issue = my_state.issue or {}
  local cur_status = issue.fields and issue.fields.status and issue.fields.status.name
  local status_picker = require("ledger.jira.pickers.status")
  status_picker.open(my_state.key, cur_status, function(to_name, err)
    if err or not to_name then
      return
    end
    vim.schedule(function()
      refresh_preview_issue(my_state)
      refresh_board_in_background()
    end)
  end)
end

-- Open the assignee picker for the previewed issue without closing the preview.
local function trigger_assign_other()
  local my_state = _state
  if not (my_state and my_state.key) then
    return
  end
  local picker = require("ledger.jira.pickers.assignee")
  local cur = my_state.issue and my_state.issue.fields and my_state.issue.fields.assignee
  local current_assignee = nil
  if cur and cur ~= vim.NIL and cur.accountId and cur.accountId ~= vim.NIL then
    current_assignee = { accountId = cur.accountId }
  end
  picker.open(my_state.key, current_assignee, function(result, err)
    if err or not result then
      return
    end
    vim.schedule(function()
      refresh_preview_issue(my_state)
      refresh_board_in_background()
    end)
  end)
end

-- Assign the previewed issue to the current user.
local function trigger_assign_me()
  local my_state = _state
  if not (my_state and my_state.key) then
    return
  end
  local store = require("ledger.jira.board.store")
  local key = my_state.key
  local function do_assign(account_id)
    jira_api.set_assignee(key, account_id, function(_, err)
      vim.schedule(function()
        if err then
          vim.notify("jira-board: assign failed — " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        refresh_preview_issue(my_state)
        refresh_board_in_background()
      end)
    end)
  end
  local me = store.state.me
  if me and me.accountId then
    do_assign(me.accountId)
  else
    jira_api.get_myself(function(m, err)
      vim.schedule(function()
        if err or not m or not m.accountId then
          vim.notify("jira-board: whoami failed — " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        local urls = m.avatarUrls or {}
        local avatar_url = urls["48x48"] or urls["32x32"]
        store.set_me(m.accountId, m.displayName or m.emailAddress or "me", avatar_url)
        do_assign(m.accountId)
      end)
    end)
  end
end

-- Reporter — use the assignee picker with a custom setter.
local function trigger_reporter()
  local my_state = _state
  if not (my_state and my_state.key) then
    return
  end
  local picker = require("ledger.jira.pickers.assignee")
  local cur = my_state.issue and my_state.issue.fields and my_state.issue.fields.reporter
  local current_reporter = nil
  if cur and cur ~= vim.NIL and cur.accountId and cur.accountId ~= vim.NIL then
    current_reporter = { accountId = cur.accountId }
  end
  picker.open(my_state.key, current_reporter, function(result, err)
    if err or not result then
      return
    end
    vim.schedule(function()
      refresh_preview_issue(my_state)
      refresh_board_in_background()
    end)
  end, { setter = jira_api.set_reporter, title = "Reporter" })
end

-- Priority picker.
local function trigger_priority()
  local my_state = _state
  if not (my_state and my_state.key) then
    return
  end
  local pr = my_state.issue and my_state.issue.fields and my_state.issue.fields.priority
  local cur = pr and pr.name or nil
  require("ledger.jira.board.ui.priority_picker").open(my_state.key, cur, function(ok)
    if not ok then
      return
    end
    vim.schedule(function()
      refresh_preview_issue(my_state)
      refresh_board_in_background()
    end)
  end)
end

-- Labels editor.
local function trigger_labels()
  local my_state = _state
  if not (my_state and my_state.key) then
    return
  end
  local labels = (my_state.issue and my_state.issue.fields and my_state.issue.fields.labels) or {}
  require("ledger.jira.board.ui.labels_picker").open(my_state.key, labels, function(new)
    if new == nil then
      return
    end
    vim.schedule(function()
      refresh_preview_issue(my_state)
      refresh_board_in_background()
    end)
  end)
end

-- Description editor (plain-text; wrapped into ADF when saving).
local function trigger_description()
  local my_state = _state
  if not (my_state and my_state.key) then
    return
  end
  local issue = my_state.issue
  local initial = ""
  if issue and issue.fields and issue.fields.description then
    local d = issue.fields.description
    if type(d) == "string" then
      initial = d
    elseif type(d) == "table" then
      local ok, lines = pcall(jira_adf.to_lines, d, 10000)
      if ok and type(lines) == "table" then
        initial = table.concat(lines, "\n")
      end
    end
  end
  require("ledger.jira.board.ui.text_editor").open({
    title = "Description — " .. my_state.key,
    initial = initial,
    on_save = function(text)
      local adf_body = {
        type = "doc",
        version = 1,
        content = {},
      }
      for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
          table.insert(adf_body.content, {
            type = "paragraph",
            content = { { type = "text", text = line } },
          })
        else
          table.insert(adf_body.content, { type = "paragraph", content = {} })
        end
      end
      if #adf_body.content == 0 then
        adf_body.content[1] = { type = "paragraph", content = {} }
      end
      jira_api.update_field(my_state.key, "description", adf_body, function(_, err)
        vim.schedule(function()
          if err then
            vim.notify("jira-board: description update failed — " .. tostring(err), vim.log.levels.ERROR)
            return
          end
          refresh_preview_issue(my_state)
          refresh_board_in_background()
        end)
      end)
    end,
  })
end

-- New comment editor.
local function trigger_comment()
  local my_state = _state
  if not (my_state and my_state.key) then
    return
  end
  require("ledger.jira.board.ui.text_editor").open({
    title = "New comment — " .. my_state.key,
    initial = "",
    on_save = function(text)
      if text == "" then
        return
      end
      local adf_body = {
        type = "doc",
        version = 1,
        content = {},
      }
      for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
          table.insert(adf_body.content, {
            type = "paragraph",
            content = { { type = "text", text = line } },
          })
        else
          table.insert(adf_body.content, { type = "paragraph", content = {} })
        end
      end
      jira_api.add_comment(my_state.key, adf_body, function(_, err)
        vim.schedule(function()
          if err then
            vim.notify("jira-board: add comment failed — " .. tostring(err), vim.log.levels.ERROR)
            return
          end
          vim.notify("jira-board: comment added")
          refresh_preview_issue(my_state)
        end)
      end)
    end,
  })
end

-- Expose keymap-triggerable wrappers so M.open's kmap bindings can reach them.
M._trigger_transition = trigger_transition
M._trigger_assign_me = trigger_assign_me
M._trigger_assign_other = trigger_assign_other
M._trigger_reporter = trigger_reporter
M._trigger_priority = trigger_priority
M._trigger_labels = trigger_labels
M._trigger_description = trigger_description
M._trigger_comment = trigger_comment

-- Split plain-text description lines into intro + named sections (Context,
-- Tickets-to-cover, etc.) based on markdown headings. Returns:
--   { intro = {...}, context = {...} | nil, cover = {...} | nil,
--     extras = { { title, content = {...} }, ... } }
local function parse_description_sections(desc_lines)
  local intro = {}
  local sections = {}
  local current = intro
  for _, line in ipairs(desc_lines or {}) do
    local heading = line:match("^#+%s*(.+)$")
    if heading and heading ~= "" then
      current = {}
      table.insert(sections, { title = heading, content = current })
    else
      table.insert(current, line)
    end
  end
  local function trim(t)
    while #t > 0 and t[1] == "" do
      table.remove(t, 1)
    end
    while #t > 0 and t[#t] == "" do
      table.remove(t)
    end
  end
  trim(intro)
  for _, s in ipairs(sections) do
    trim(s.content)
  end

  local out = { intro = intro, context = nil, cover = nil, extras = {} }
  for _, s in ipairs(sections) do
    local lt = s.title:lower()
    if lt:match("^context%s*[:%.]?$") or lt:match("^context%s") then
      out.context = s.content
    elseif lt:match("tickets?%s+to%s+cover") or lt:match("tests?%s+to%s+cover") then
      out.cover = s.content
    else
      table.insert(out.extras, s)
    end
  end
  return out
end

-- Parse a markdown table (lines starting with `|`). Returns (header, rows) or
-- (nil, nil) if the block isn't a table.
local function parse_md_table(lines)
  local header, rows
  local in_table = false
  for _, raw in ipairs(lines) do
    local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if line:sub(1, 1) == "|" then
      local cells = {}
      for cell in line:gmatch("|([^|]*)") do
        table.insert(cells, (cell:gsub("^%s+", ""):gsub("%s+$", "")))
      end
      if #cells > 0 and cells[#cells] == "" then
        table.remove(cells)
      end
      if not in_table then
        header = cells
        rows = {}
        in_table = true
      else
        local is_sep = true
        for _, c in ipairs(cells) do
          if not c:match("^[:%-]+$") then
            is_sep = false
            break
          end
        end
        if not is_sep then
          table.insert(rows, cells)
        end
      end
    elseif in_table and line == "" then
      -- allow blank lines inside a table block? break instead
      break
    elseif in_table then
      break
    end
  end
  if header and rows then
    return header, rows
  end
  return nil, nil
end

-- Pad a row of segments so its total display width equals target_w.
local function pad_segs_to(segs, target_w, fill_hl)
  local total = 0
  for _, s in ipairs(segs) do
    total = total + dw(s[1])
  end
  local diff = target_w - total
  if diff > 0 then
    table.insert(segs, { string.rep(" ", diff), fill_hl or "JiraBoardNormal" })
  end
  return segs
end

local function build_left_panel(w, issue)
  local lines = {}
  local function row(segs)
    table.insert(lines, pad_segs_to(segs, w))
  end
  local function blank()
    row({ { string.rep(" ", w), "JiraBoardNormal" } })
  end
  local function hline()
    row({
      { "  ", "JiraBoardNormal" },
      { string.rep("─", w - 4), "JiraBoardColRule" },
      { "  ", "JiraBoardNormal" },
    })
  end

  local content_w = math.max(8, w - 4)
  local fields = (issue and issue.fields) or {}
  local summary = present(fields.summary) or ""

  local function body_line(text, hl_group)
    local wrapped = (text == "" or text == nil) and { "" } or wrap_text(text, content_w)
    for _, l in ipairs(wrapped) do
      row({
        { "  ", "JiraBoardNormal" },
        { pad_right(l, content_w), hl_group or "JiraBoardCardSum" },
        { "  ", "JiraBoardNormal" },
      })
    end
  end

  local function section(icon, title, click)
    local actions = click and { click = click } or nil
    local cap = click and " ✎" or ""
    row({
      { "  ", "JiraBoardNormal" },
      { (icon or "") .. " ", "JiraBoardColHdr", actions },
      { pad_right(title .. cap, content_w - 3), "JiraBoardColHdr", actions },
      { "  ", "JiraBoardNormal" },
    })
    hline()
    blank()
  end

  -- Summary (bold)
  blank()
  local summary_lines = wrap_text(summary, content_w)
  if #summary_lines == 0 then
    summary_lines = { "" }
  end
  for _, l in ipairs(summary_lines) do
    row({
      { "  ", "JiraBoardNormal" },
      { pad_right(l, content_w), "JiraBoardTitle" },
      { "  ", "JiraBoardNormal" },
    })
  end
  blank()

  -- Description (handle both ADF docs and legacy string payloads).
  -- We also parse it for Context / Tickets-to-cover sub-sections that Ledger
  -- QA templates embed in the description body, so they can render as
  -- distinct, visually separated preview sections.
  local description = present(fields.description)
  local desc_lines = {}
  if type(description) == "table" then
    local ok, res = pcall(jira_adf.to_lines, description, 200)
    if ok and type(res) == "table" then
      desc_lines = res
    end
  elseif type(description) == "string" and description ~= "" then
    for line in (description .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(desc_lines, line)
    end
  end
  local parsed = parse_description_sections(desc_lines)
  _state.description_cover = parsed.cover -- surfaced later for the lookup

  section(icons.LABEL.summary, "Description", M._trigger_description)
  if description == nil then
    body_line("(no description)", "JiraBoardMuted")
  elseif #parsed.intro == 0 and #parsed.extras == 0 and not parsed.context and not parsed.cover then
    body_line("(empty)", "JiraBoardMuted")
  else
    for _, raw in ipairs(parsed.intro) do
      body_line(raw or "", "JiraBoardCardSum")
    end
    -- Render non-Context / non-Tickets-to-cover sub-sections inline.
    for _, s in ipairs(parsed.extras) do
      if #parsed.intro > 0 then
        blank()
      end
      body_line("" .. s.title, "JiraBoardTitle")
      for _, l in ipairs(s.content) do
        body_line(l or "", "JiraBoardCardSum")
      end
    end
  end
  blank()

  -- Context (pulled out of description).
  if parsed.context then
    section(icons.LABEL.summary, "Context")
    if #parsed.context == 0 then
      body_line("(empty)", "JiraBoardMuted")
    else
      for _, l in ipairs(parsed.context) do
        body_line(l or "", "JiraBoardCardSum")
      end
    end
    blank()
  end

  -- Linked Issues
  local links = fields.issuelinks
  section(icons.LABEL.ticket, "Linked issues (" .. ((type(links) == "table" and #links) or 0) .. ")")
  if type(links) == "table" and #links > 0 then
    local groups, order = {}, {}
    for _, link in ipairs(links) do
      local outward = present(link.outwardIssue)
      local inward = present(link.inwardIssue)
      local target = outward or inward
      if target then
        local rel = "related to"
        local t = present(link.type)
        if t then
          if outward then
            rel = present(t.outward) or rel
          else
            rel = present(t.inward) or rel
          end
        end
        if not groups[rel] then
          groups[rel] = {}
          table.insert(order, rel)
        end
        table.insert(groups[rel], target)
      end
    end
    for _, rel in ipairs(order) do
      row({
        { "  ", "JiraBoardNormal" },
        { pad_right(rel, content_w), "JiraBoardMuted" },
        { "  ", "JiraBoardNormal" },
      })
      for _, t in ipairs(groups[rel]) do
        local k = present(t.key) or "?"
        local s = (t.fields and present(t.fields.summary)) or ""
        local st = t.fields and t.fields.status and present(t.fields.status.name)
        local st_hl = hl.status_hl(st or "")
        local suffix = st and ("  " .. icons.status(st) .. " " .. st) or ""
        local avail = content_w - dw("    ") - dw(k .. "  ") - dw(suffix)
        if avail < 4 then
          avail = 4
        end
        local child_key = k
        local link_actions = {
          click = function()
            local open = require("ledger.jira.board.ui.preview").open
            open({ key = child_key }, { stack = true })
          end,
        }
        row({
          { "  ", "JiraBoardNormal" },
          { "    ", "JiraBoardNormal", link_actions },
          { k .. "  ", "JiraBoardCardKey", link_actions },
          { pad_right(truncate(s, avail), avail), "JiraBoardCardSum", link_actions },
          { suffix, st_hl, link_actions },
          { "  ", "JiraBoardNormal" },
        })
      end
    end
  else
    body_line("(none)", "JiraBoardMuted")
  end
  blank()

  -- Sub-tasks
  local subtasks = fields.subtasks
  section(icons.LABEL.ticket, "Sub-tasks (" .. ((type(subtasks) == "table" and #subtasks) or 0) .. ")")
  if type(subtasks) == "table" and #subtasks > 0 then
    for _, t in ipairs(subtasks) do
      local k = present(t.key) or "?"
      local s = (t.fields and present(t.fields.summary)) or ""
      local st = t.fields and t.fields.status and present(t.fields.status.name)
      local st_hl = hl.status_hl(st or "")
      local suffix = st and ("  " .. icons.status(st) .. " " .. st) or ""
      local avail = content_w - dw(k .. "  ") - dw(suffix)
      if avail < 4 then
        avail = 4
      end
      local child_key = k
      local link_actions = {
        click = function()
          local open = require("ledger.jira.board.ui.preview").open
          open({ key = child_key }, { stack = true })
        end,
      }
      row({
        { "  ", "JiraBoardNormal" },
        { k .. "  ", "JiraBoardCardKey", link_actions },
        { pad_right(truncate(s, avail), avail), "JiraBoardCardSum", link_actions },
        { suffix, st_hl, link_actions },
        { "  ", "JiraBoardNormal" },
      })
    end
  else
    body_line("(none)", "JiraBoardMuted")
  end
  blank()

  -- Tickets to cover. Sources, in order of preference:
  --   1. A "Tickets to cover" markdown table embedded in the description.
  --   2. Linked-issue / epic-child data fetched over REST.
  if parsed.cover then
    section(icons.LABEL.ticket, "Tickets to cover")
    local md_header, md_rows = parse_md_table(parsed.cover)
    if md_header and #md_rows > 0 then
      -- Pretty-render the markdown table using the same column widths as the
      -- fetched table. The first cell is treated as the ticket key when it
      -- looks like PROJECT-NNN, making the row clickable.
      local n = #md_header
      local col_w = math.max(10, math.floor((content_w - 2 - (n - 1)) / n))
      local hdr_row = { { "  ", "JiraBoardNormal" } }
      for i, h in ipairs(md_header) do
        table.insert(hdr_row, { pad_right(truncate(h, col_w), col_w), "JiraBoardColHdr" })
        if i < n then
          table.insert(hdr_row, { " ", "JiraBoardNormal" })
        end
      end
      table.insert(hdr_row, { "  ", "JiraBoardNormal" })
      row(hdr_row)
      row({
        { "  ", "JiraBoardNormal" },
        { string.rep("─", n * col_w + (n - 1)), "JiraBoardColRule" },
        { "  ", "JiraBoardNormal" },
      })
      for _, r_cells in ipairs(md_rows) do
        local first = r_cells[1] or ""
        local ticket_key = first:match("([A-Z][A-Z0-9]+%-%d+)")
        local click = nil
        if ticket_key then
          local child_key = ticket_key
          click = {
            click = function()
              require("ledger.jira.board.ui.preview").open({ key = child_key }, { stack = true })
            end,
          }
        end
        local data_row = { { "  ", "JiraBoardNormal" } }
        for i = 1, n do
          local txt = pad_right(truncate(r_cells[i] or "", col_w), col_w)
          local hl_group = (i == 1 and ticket_key) and "JiraBoardTitle" or "JiraBoardNormal"
          table.insert(data_row, { txt, hl_group, click })
          if i < n then
            table.insert(data_row, { " ", "JiraBoardNormal" })
          end
        end
        table.insert(data_row, { "  ", "JiraBoardNormal" })
        row(data_row)
      end
    elseif #parsed.cover == 0 then
      body_line("(empty)", "JiraBoardMuted")
    else
      for _, l in ipairs(parsed.cover) do
        body_line(l or "", "JiraBoardCardSum")
      end
    end
    blank()
    goto after_tickets_to_cover
  end

  -- Fallback: fetched children (Epic JQL or linked-issue details).
  do
    local children = _state.children
    local loading = children == nil
    children = children or {}
    local count = #children

    -- Progress bar
    local done = 0
    for _, c in ipairs(children) do
      local cat = c.fields and c.fields.status and c.fields.status.statusCategory
      local key_cat = (cat and (cat.key or (cat.name and cat.name:lower())))
      if key_cat == "done" then
        done = done + 1
      end
    end
    local pct = (count > 0) and math.floor((done / count) * 100) or 0

    if count > 0 then
      section(icons.LABEL.ticket, "Tickets to cover (" .. done .. "/" .. count .. " — " .. pct .. "%)")
    else
      section(icons.LABEL.ticket, "Tickets to cover")
    end

    if loading then
      body_line("(loading…)", "JiraBoardMuted")
    elseif count == 0 then
      body_line("(none)", "JiraBoardMuted")
    else
      local bar_w = content_w - 10
      if bar_w < 10 then
        bar_w = 10
      end
      local filled = math.floor((done / count) * bar_w + 0.5)
      if filled > bar_w then
        filled = bar_w
      end
      row({
        { "  ", "JiraBoardNormal" },
        { string.rep("█", filled), "JiraBoardStDone" },
        { string.rep("░", bar_w - filled), "JiraBoardMuted" },
        { "  " .. pct .. "%", "JiraBoardNormal" },
        { "  ", "JiraBoardNormal" },
      })
      blank()

      -- Table layout: Key | Summary | Status | Priority | Assignee
      local key_w = 11
      local status_w = 14
      local priority_w = 9
      local assignee_w = 12
      local summary_w = content_w - key_w - status_w - priority_w - assignee_w - 4
      if summary_w < 10 then
        summary_w = 10
      end

      -- Table header
      row({
        { "  ", "JiraBoardNormal" },
        { pad_right("Key", key_w), "JiraBoardColHdr" },
        { " ", "JiraBoardNormal" },
        { pad_right("Summary", summary_w), "JiraBoardColHdr" },
        { " ", "JiraBoardNormal" },
        { pad_right("Status", status_w), "JiraBoardColHdr" },
        { " ", "JiraBoardNormal" },
        { pad_right("Pri", priority_w), "JiraBoardColHdr" },
        { " ", "JiraBoardNormal" },
        { pad_right("Assignee", assignee_w), "JiraBoardColHdr" },
        { "  ", "JiraBoardNormal" },
      })
      row({
        { "  ", "JiraBoardNormal" },
        { string.rep("─", key_w + summary_w + status_w + priority_w + assignee_w + 4), "JiraBoardColRule" },
        { "  ", "JiraBoardNormal" },
      })

      for _, c in ipairs(children) do
        local k = present(c.key) or "?"
        local s = (c.fields and present(c.fields.summary)) or ""
        local st = c.fields and c.fields.status and present(c.fields.status.name)
        local st_hl = hl.status_hl(st or "")
        local pr = c.fields and c.fields.priority and present(c.fields.priority.name)
        local pr_hl = hl.priority_hl(pr or "")
        local asn = c.fields and present(c.fields.assignee)
        local asn_name = asn and (present(asn.displayName) or present(asn.emailAddress)) or "—"

        local status_cell = st and (icons.status(st) .. " " .. st) or "—"
        local priority_cell = pr or "—"
        local child_key = k
        local click = {
          click = function()
            local open = require("ledger.jira.board.ui.preview").open
            open({ key = child_key }, { stack = true })
          end,
        }

        row({
          { "  ", "JiraBoardNormal" },
          { pad_right(truncate(k, key_w), key_w), "JiraBoardTitle", click },
          { " ", "JiraBoardNormal" },
          { pad_right(truncate(s, summary_w), summary_w), "JiraBoardNormal", click },
          { " ", "JiraBoardNormal" },
          { pad_right(truncate(status_cell, status_w), status_w), st_hl, click },
          { " ", "JiraBoardNormal" },
          { pad_right(truncate(priority_cell, priority_w), priority_w), pr_hl, click },
          { " ", "JiraBoardNormal" },
          { pad_right(truncate(asn_name, assignee_w), assignee_w), "JiraBoardMuted", click },
          { "  ", "JiraBoardNormal" },
        })
      end
    end
    blank()
  end
  ::after_tickets_to_cover::

  -- Comments (click the header to add a new comment)
  local comment_box = present(fields.comment)
  local comments = (type(comment_box) == "table" and comment_box.comments) or {}
  section(icons.LABEL.summary, "Comments (" .. #comments .. ") + add", M._trigger_comment)
  if #comments == 0 then
    body_line("(no comments)", "JiraBoardMuted")
  else
    for i, c in ipairs(comments) do
      local author = (c.author and present(c.author.displayName)) or "someone"
      local created = present(c.created) or ""
      if created ~= "" then
        created = created:sub(1, 10)
      end
      local header = author
      if created ~= "" then
        header = header .. " · " .. created
      end
      row({
        { "  ", "JiraBoardNormal" },
        { pad_right(truncate(header, content_w), content_w), "JiraBoardMuted" },
        { "  ", "JiraBoardNormal" },
      })
      local body_lines = {}
      if type(c.body) == "table" then
        local ok, res = pcall(jira_adf.to_lines, c.body, 30)
        if ok and type(res) == "table" then
          body_lines = res
        end
      elseif type(c.body) == "string" and c.body ~= "" then
        for line in (c.body .. "\n"):gmatch("([^\n]*)\n") do
          table.insert(body_lines, line)
        end
      end
      if #body_lines > 0 then
        for _, raw in ipairs(body_lines) do
          local wrapped = (raw == "" or raw == nil) and { "" } or wrap_text(raw, content_w - 2)
          for _, l in ipairs(wrapped) do
            row({
              { "  ", "JiraBoardNormal" },
              { "  ", "JiraBoardNormal" },
              { pad_right(l, content_w - 2), "JiraBoardCardSum" },
              { "  ", "JiraBoardNormal" },
            })
          end
        end
      else
        row({
          { "  ", "JiraBoardNormal" },
          { "  ", "JiraBoardNormal" },
          { pad_right("(no text content)", content_w - 2), "JiraBoardMuted" },
          { "  ", "JiraBoardNormal" },
        })
      end
      if i < #comments then
        blank()
      end
    end
  end
  blank()

  return lines
end

local function build_right_panel(w, issue)
  local lines = {}
  local function row(segs)
    table.insert(lines, pad_segs_to(segs, w, "JiraBoardNormal"))
  end
  local function blank()
    row({ { string.rep(" ", w), "JiraBoardNormal" } })
  end
  local function hline()
    row({
      { "  ", "JiraBoardNormal" },
      { string.rep("─", w - 4), "JiraBoardColRule" },
      { "  ", "JiraBoardNormal" },
    })
  end

  local content_w = math.max(8, w - 4)
  local fields = (issue and issue.fields) or {}
  local L = icons.LABEL

  -- Details header (same theme as the left panel's section headers).
  row({
    { "  ", "JiraBoardNormal" },
    { icons.SECTION .. " ", "JiraBoardColHdr" },
    { pad_right("Details", content_w - 3), "JiraBoardColHdr" },
    { "  ", "JiraBoardNormal" },
  })
  hline()
  blank()

  -- Inline detail: a single row per field with `Label   Value`. Continuation
  -- lines (for long wrapped values) align under the value column.
  local label_w = 18
  if label_w > content_w - 10 then
    label_w = math.max(10, content_w - 10)
  end
  local value_w = content_w - label_w - 1

  local function detail(icon, label, value, opts)
    opts = opts or {}
    local value_hl = opts.value_hl
    local click = opts.click
    local actions = click and { click = click } or nil
    local display = (value == nil or value == "") and "(none)" or tostring(value)
    local empty_hl = (value == nil or value == "") and "JiraBoardMuted" or nil
    local label_seg = (icon or "") .. " " .. label
    local value_lines = wrap_text(display, value_w)
    if #value_lines == 0 then
      value_lines = { display }
    end
    -- First line: label (muted) + first value chunk.
    row({
      { "  ", "JiraBoardNormal" },
      { pad_right(truncate(label_seg, label_w), label_w), "JiraBoardMuted", actions },
      { " ", "JiraBoardNormal" },
      { pad_right(value_lines[1], value_w), empty_hl or value_hl or "JiraBoardNormal", actions },
      { "  ", "JiraBoardNormal" },
    })
    -- Continuation lines: blank label column, aligned value.
    for i = 2, #value_lines do
      row({
        { "  ", "JiraBoardNormal" },
        { string.rep(" ", label_w), "JiraBoardNormal" },
        { " ", "JiraBoardNormal" },
        { pad_right(value_lines[i], value_w), empty_hl or value_hl or "JiraBoardNormal", actions },
        { "  ", "JiraBoardNormal" },
      })
    end
    -- Breathing room between attributes.
    blank()
  end

  local function opt_value(v)
    if type(v) ~= "table" then
      return present(v)
    end
    return present(v.value) or present(v.name) or present(v.displayName)
  end

  local function join_option_list(arr)
    if type(arr) ~= "table" then
      return nil
    end
    local names = {}
    for _, p in ipairs(arr) do
      local name = opt_value(p)
      if name then
        table.insert(names, name)
      end
    end
    if #names == 0 then
      return nil
    end
    return table.concat(names, ", ")
  end

  local st = present(fields.status)
  st = st and present(st.name)
  local pr = present(fields.priority)
  pr = pr and present(pr.name)
  local a = present(fields.assignee)
  local assignee = a and (present(a.displayName) or present(a.emailAddress)) or nil
  local r = present(fields.reporter)
  local reporter = r and (present(r.displayName) or present(r.emailAddress)) or nil
  local c = present(fields.creator)
  local creator = c and (present(c.displayName) or present(c.emailAddress)) or nil
  local it = present(fields.issuetype)
  it = it and present(it.name)

  detail(icons.status(st or ""), "Status", st, {
    value_hl = hl.status_hl(st or ""),
    click = M._trigger_transition,
  })
  detail(icons.priority(pr or ""), "Priority", pr, {
    value_hl = hl.priority_hl(pr or ""),
    click = M._trigger_priority,
  })
  detail(L.assignee, "Assignee", assignee, {
    click = M._trigger_assign_other,
  })
  detail(L.reporter, "Reporter", reporter, {
    click = M._trigger_reporter,
  })
  if creator and creator ~= reporter then
    detail(L.reporter, "Creator", creator)
  end

  -- "Dream Team" is the correct field attribute name.
  detail(L.team, "Dream Team", opt_value(fields.customfield_10332))

  local sprint_txt = nil
  local sprints = fields.customfield_10010
  if type(sprints) == "table" then
    local names = {}
    for _, s in ipairs(sprints) do
      if type(s) == "table" then
        local n = present(s.name)
        if n then
          table.insert(names, n)
        end
      end
    end
    if #names > 0 then
      sprint_txt = table.concat(names, ", ")
    end
  end
  detail(L.updated, "Sprint", sprint_txt)

  local labels_txt = nil
  if type(fields.labels) == "table" and #fields.labels > 0 then
    labels_txt = table.concat(fields.labels, ", ")
  end
  detail(L.labels, "Labels", labels_txt, { click = M._trigger_labels })

  local parent = present(fields.parent)
  local parent_txt = nil
  if parent then
    local pkey = present(parent.key) or ""
    local psum = parent.fields and present(parent.fields.summary) or ""
    parent_txt = pkey .. (psum ~= "" and (" · " .. psum) or "")
  end
  detail(L.ticket, "Parent", parent_txt)

  local function date10(v)
    local s = present(v)
    if not s then
      return nil
    end
    return tostring(s):sub(1, 10)
  end

  detail(L.updated, "Created", date10(fields.created))
  detail(L.updated, "Updated", date10(fields.updated))

  return lines
end

-- Build the body lines given current state.
local function build_lines(inner_w)
  local lines = {}
  local function row_raw(segs)
    table.insert(lines, segs)
  end
  local function blank()
    row_raw({ { string.rep(" ", inner_w), "JiraBoardNormal" } })
  end

  -- Header: key on left, close cross on right.
  local key = _state.key or "?"
  local key_txt = " " .. key .. " "
  local close_txt = " ✕ "
  local close_actions = {
    click = function()
      close()
    end,
  }
  local mid = inner_w - dw(key_txt) - dw(close_txt)
  if mid < 1 then
    mid = 1
  end
  row_raw({
    { key_txt, "JiraBoardTitle" },
    { string.rep(" ", mid), "JiraBoardNormal" },
    { close_txt, "JiraBoardClose", close_actions },
  })
  row_raw({ { string.rep("─", inner_w), "JiraBoardColRule" } })

  if _state.loading then
    blank()
    row_raw({
      { "  ", "JiraBoardNormal" },
      { "loading…", "JiraBoardMuted" },
      { string.rep(" ", inner_w - 2 - dw("loading…")), "JiraBoardNormal" },
    })
    blank()
    return lines
  end

  if _state.error then
    blank()
    row_raw({
      { "  ", "JiraBoardNormal" },
      { "error: " .. _state.error, "JiraBoardFilterOn" },
      { string.rep(" ", math.max(0, inner_w - 2 - dw("error: " .. _state.error))), "JiraBoardNormal" },
    })
    blank()
    return lines
  end

  -- Two-panel layout: left (summary + description), right (details).
  local divider_w = 3 -- " │ "
  local left_w = math.floor(inner_w * 0.60)
  if left_w < 30 then
    left_w = math.min(30, inner_w - divider_w - 20)
  end
  local right_w = inner_w - left_w - divider_w
  if right_w < 20 then
    right_w = 20
    left_w = inner_w - divider_w - right_w
  end
  -- Record the divider column so nav code can tell left-from-right clickables.
  _state.divider_col = left_w + divider_w

  local left_lines = build_left_panel(left_w, _state.issue)
  local right_lines = build_right_panel(right_w, _state.issue)

  local max_h = math.max(#left_lines, #right_lines)
  for i = 1, max_h do
    local left = left_lines[i]
    if not left then
      left = pad_segs_to({}, left_w)
    end
    local right = right_lines[i]
    if not right then
      right = pad_segs_to({}, right_w, "JiraBoardNormal")
    end
    local merged = {}
    for _, s in ipairs(left) do
      table.insert(merged, s)
    end
    table.insert(merged, { " │ ", "JiraBoardColRule" })
    for _, s in ipairs(right) do
      table.insert(merged, s)
    end
    row_raw(merged)
  end

  return lines
end

rerender = function()
  local s = _state
  if not (s.buf and api.nvim_buf_is_valid(s.buf)) then
    return
  end
  local screen_w = vim.o.columns
  local screen_h = vim.o.lines
  local w = math.min(120, screen_w - 6)
  local inner_w = w
  local lines = build_lines(inner_w)
  local h = math.min(#lines, screen_h - 6)

  api.nvim_set_option_value("modifiable", true, { buf = s.buf })
  volt.set_empty_lines(s.buf, #lines, inner_w)
  s.layout = { {
    name = "body",
    lines = function()
      return lines
    end,
  } }
  volt.gen_data({ { buf = s.buf, xpad = 0, layout = s.layout, ns = s.ns } })
  volt.redraw(s.buf, "all")
  api.nvim_set_option_value("modifiable", false, { buf = s.buf })

  -- Resize window to fit content (capped at screen).
  if s.win and api.nvim_win_is_valid(s.win) then
    local row = math.floor((screen_h - h) / 2) - 1
    local col = math.floor((screen_w - w) / 2)
    pcall(api.nvim_win_set_config, s.win, {
      relative = "editor",
      row = row,
      col = col,
      width = w,
      height = h,
    })
  end

  -- Re-apply the focus highlight. The click row count changes after every
  -- render, so try to preserve the previous focus_row; if it no longer
  -- holds a clickable, focus the first on the preferred side.
  if s.buf and api.nvim_buf_is_valid(s.buf) then
    local rows = collect_focus_rows(s.buf)
    if #rows > 0 then
      local kept
      for _, r in ipairs(rows) do
        if r.row == s.focus_row and r.side == s.focus_side then
          kept = r
          break
        end
      end
      if kept then
        set_focus(s.buf, kept)
      else
        focus_first(s.buf)
      end
    end
  end
end

function M.open(issue, opts)
  opts = opts or {}
  local key = issue and issue.key or nil
  if not key then
    return
  end

  -- Stack semantics: if a preview is already open and the caller passes
  -- opts.stack, push the current one so the new preview layers on top.
  -- Without opts.stack, we replace the current preview.
  if _state.win and api.nvim_win_is_valid(_state.win) then
    if opts.stack then
      push_state()
    else
      close()
    end
  end

  -- Freeze the board's scroll while any preview is visible.
  pcall(function()
    require("ledger.jira.board.ui.window").lock_scroll()
  end)

  local depth = #_stack -- 0 for the root preview, 1+ for stacked drill-ins
  local zindex = 160 + 10 * depth

  local screen_w = vim.o.columns
  local screen_h = vim.o.lines
  local w = math.min(120, screen_w - 6)
  local h = math.min(24, screen_h - 6)
  local row = math.floor((screen_h - h) / 2) - 1 + 2 * depth
  local col = math.floor((screen_w - w) / 2) + 4 * depth

  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = w,
    height = h,
    style = "minimal",
    border = "single",
    zindex = zindex,
  })
  jira_util.clean_float_window(win)
  vim.wo[win].cursorline = false
  vim.bo[buf].filetype = "jira-board-preview"

  local ns = api.nvim_create_namespace("jira_board_preview_hl")
  hl.define(ns)
  api.nvim_win_set_hl_ns(win, ns)
  api.nvim_set_hl(ns, "FloatBorder", { link = "JiraBoardBorder" })
  api.nvim_set_hl(ns, "Normal", { link = "JiraBoardNormal" })

  _state.buf = buf
  _state.win = win
  _state.ns = ns
  _state.key = key
  _state.issue = issue -- show summary-level data immediately
  _state.loading = true
  _state.error = nil
  local my_state = _state

  -- gen_data must run before volt.run (which internally calls redraw).
  local initial_lines = build_lines(w)
  _state.layout = { {
    name = "body",
    lines = function()
      return initial_lines
    end,
  } }
  volt.gen_data({ { buf = buf, xpad = 0, layout = _state.layout, ns = ns } })
  local total_h = require("volt.state")[buf].h
  volt.run(buf, { h = total_h, w = w })
  do
    local sh = vim.o.lines
    local sw = vim.o.columns
    local new_h = math.min(total_h, sh - 6)
    local new_row = math.floor((sh - new_h) / 2) - 1 + 2 * depth
    local new_col = math.floor((sw - w) / 2) + 4 * depth
    pcall(api.nvim_win_set_config, win, {
      relative = "editor",
      row = new_row,
      col = new_col,
      width = w,
      height = new_h,
    })
  end

  require("volt.events").add(buf)
  if not vim.g.extmarks_events then
    require("volt.events").enable()
  end

  -- When a picker closes and focus lands back on the preview, force normal
  -- mode: pickers start in insert and Neovim's mode is global, so without
  -- this the preview would inherit the picker's insert state.
  api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    buffer = buf,
    callback = function()
      if vim.fn.mode():sub(1, 1) == "i" then
        vim.cmd("stopinsert")
      end
    end,
  })

  -- Drop the initial focus on the first clickable so the user sees the
  -- navigable-field highlight right away.
  focus_first(buf)

  local function kmap(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  kmap("q", close)
  kmap("<Esc>", close)
  kmap("p", close)
  kmap("y", function()
    vim.fn.setreg("+", key)
    vim.fn.setreg('"', key)
    vim.notify("jira-board: yanked " .. key)
  end)
  kmap("<CR>", function()
    -- Activate the click action under the cursor (volt's built-in keyboard
    -- handler only fires on sliders). No browser fallback — use `b` for that.
    local cur = api.nvim_win_get_cursor(0)
    local rownum, colnum = cur[1], cur[2]
    local ok, vstate = pcall(require, "volt.state")
    if ok and vstate and vstate[buf] and vstate[buf].clickables then
      local row_items = vstate[buf].clickables[rownum]
      if row_items then
        for _, item in ipairs(row_items) do
          if item.col_start <= colnum and item.col_end >= colnum then
            local actions = item.actions
            local fn = type(actions) == "table" and actions.click or actions
            if type(fn) == "function" then
              fn()
              return
            end
            if type(fn) == "string" then
              vim.cmd(fn)
              return
            end
          end
        end
      end
    end
  end)
  kmap("b", function()
    jira_util.open_url(jira_util.ticket_url(key))
  end)
  -- In-preview actions (pickers open on top, preview stays visible).
  kmap("m", function()
    M._trigger_assign_me()
  end)
  kmap("a", function()
    M._trigger_assign_other()
  end)
  kmap("t", function()
    M._trigger_transition()
  end)
  kmap("?", function()
    require("ledger.jira.board.ui.preview_help").toggle()
  end)
  -- Focus navigation: Tab toggles between left/right sections; j/k/arrows
  -- cycle the editable fields within the currently-focused side.
  kmap("<Tab>", function()
    focus_nav(buf, "toggle_side")
  end)
  kmap("<S-Tab>", function()
    focus_nav(buf, "toggle_side")
  end)
  kmap("j", function()
    focus_nav(buf, "down")
  end)
  kmap("k", function()
    focus_nav(buf, "up")
  end)
  kmap("l", function()
    focus_nav(buf, "down")
  end)
  kmap("h", function()
    focus_nav(buf, "up")
  end)
  kmap("<Down>", function()
    focus_nav(buf, "down")
  end)
  kmap("<Up>", function()
    focus_nav(buf, "up")
  end)
  kmap("<Right>", function()
    focus_nav(buf, "down")
  end)
  kmap("<Left>", function()
    focus_nav(buf, "up")
  end)

  -- Fetch full issue, then fetch full details for its children so the
  -- tickets-to-cover table has assignee / priority / status populated.
  jira_api.get_issue(key, function(data, err)
    vim.schedule(function()
      if not (my_state.buf and api.nvim_buf_is_valid(my_state.buf)) then
        return
      end
      my_state.loading = false
      if err then
        my_state.error = tostring(err)
        if my_state == _state then
          rerender()
        end
        return
      end
      if not data then
        return
      end
      my_state.issue = data
      if my_state == _state then
        rerender()
      end

      local it = data.fields and data.fields.issuetype
      local is_epic = it and (it.name == "Epic" or (it.hierarchyLevel or 0) >= 1)
      local fetch_opts = {
        fields = "summary,status,priority,assignee,issuetype",
        max_results = 100,
      }
      local function on_children(sdata, serr)
        vim.schedule(function()
          if serr or not sdata then
            return
          end
          if not (my_state.buf and api.nvim_buf_is_valid(my_state.buf)) then
            return
          end
          my_state.children = sdata.issues or {}
          if my_state == _state and rerender then
            pcall(rerender)
          end
        end)
      end
      if is_epic then
        jira_api.search_issues('parent = "' .. key .. '" ORDER BY status, key', on_children, fetch_opts)
      else
        local keys = {}
        local seen = {}
        local links = data.fields and data.fields.issuelinks
        if type(links) == "table" then
          for _, link in ipairs(links) do
            local t = (link.outwardIssue and present(link.outwardIssue))
              or (link.inwardIssue and present(link.inwardIssue))
            local k = t and present(t.key) or nil
            if k and not seen[k] then
              seen[k] = true
              table.insert(keys, k)
            end
          end
        end
        if #keys == 0 then
          my_state.children = {}
          if my_state == _state and rerender then
            pcall(rerender)
          end
        else
          jira_api.search_issues("issueKey in (" .. table.concat(keys, ",") .. ")", on_children, fetch_opts)
        end
      end
    end)
  end)
end

function M.close()
  close()
end

return M
