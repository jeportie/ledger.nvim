local M = {}

local icons = require("ledger.xray.icons")
local adf = require("ledger.xray.adf")

local PLATFORM_SHORT = {
  Windows = "Win",
  MacOS = "Mac",
  Linux = "Linux",
  Android = "Droid",
  iOS = "iOS",
}

local STATUS_GROUP = {
  ["Done"]                = "XrayStatusOk",
  ["Closed"]              = "XrayStatusOk",
  ["Automated"]           = "XrayStatusOk",
  ["Automation Required"] = "XrayStatusWarn",
  ["In Progress"]         = "XrayStatusWarn",
  ["Manual Test"]         = "XrayStatusInfo",
  ["To Do"]               = "XrayStatusInfo",
  ["Open"]                = "XrayStatusInfo",
  ["Ready"]               = "XrayStatusInfo",
  ["Blocked"]             = "XrayStatusError",
  ["Reviewing"]           = "XrayStatusWarn",
}

local PRIORITY_GROUP = {
  Highest = "XrayPriorityHigh",
  High    = "XrayPriorityHigh",
  Medium  = "XrayPriorityMedium",
  Low     = "XrayPriorityLow",
  Lowest  = "XrayPriorityLow",
}

local YESNO_GROUP = {
  Yes = "XrayStatusWarn",
  No  = "XrayStatusOk",
}

local SEVERITY_GROUP = {
  Critical = "XrayStatusError",
  High     = "XrayStatusError",
  Major    = "XrayStatusError",
  Medium   = "XrayStatusWarn",
  Low      = "XrayStatusInfo",
  Minor    = "XrayStatusInfo",
  Trivial  = "XrayStatusMuted",
}

local function status_group(name)
  return STATUS_GROUP[name] or "XrayStatusMuted"
end

local function priority_group(name)
  return PRIORITY_GROUP[name] or "XrayStatusMuted"
end

local function severity_group(name)
  return SEVERITY_GROUP[name] or "XrayStatusMuted"
end

local function option_value(v)
  if v == nil or v == vim.NIL then return nil end
  if type(v) == "string" then return v ~= "" and v or nil end
  if type(v) == "number" then return tostring(v) end
  if type(v) ~= "table" then return nil end
  if vim.tbl_isempty(v) then return nil end
  if v.value then return v.value end
  if v.name then return v.name end
  return nil
end

local function options_list(v)
  if type(v) ~= "table" or vim.tbl_isempty(v) then return {} end
  local names = {}
  for _, opt in ipairs(v) do
    local name = (type(opt) == "table" and (opt.value or opt.name)) or tostring(opt)
    table.insert(names, name)
  end
  return names
end

local function field_id_by_name(names_map, target)
  if type(names_map) ~= "table" then return nil end
  for id, label in pairs(names_map) do
    if label == target then return id end
  end
  return nil
end

local function field_by_name(issue, target)
  local id = field_id_by_name(issue.names, target)
  if not id then return nil end
  return (issue.fields or {})[id]
end

local function parse_iso(iso)
  if type(iso) ~= "string" then return nil end
  local y, mo, d, h, mi, s = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  return os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  })
end

local function time_ago(iso)
  local t = parse_iso(iso)
  if not t then return nil end
  local now = os.time()
  local diff = now - t
  if diff < 60 then return "just now" end
  if diff < 3600 then return math.floor(diff / 60) .. "m ago" end
  if diff < 86400 then return math.floor(diff / 3600) .. "h ago" end
  if diff < 86400 * 30 then return math.floor(diff / 86400) .. "d ago" end
  if diff < 86400 * 365 then return math.floor(diff / (86400 * 30)) .. "mo ago" end
  return math.floor(diff / (86400 * 365)) .. "y ago"
end

local function pad_display(s, w)
  s = s or ""
  local len = vim.fn.strdisplaywidth(s)
  if len >= w then return s, 0 end
  return s .. string.rep(" ", w - len), w - len
end

local function wrap_text(text, max_w)
  local out = {}
  local remaining = text
  while #remaining > 0 do
    if vim.fn.strdisplaywidth(remaining) <= max_w then
      table.insert(out, remaining)
      break
    end
    local slice = remaining:sub(1, max_w)
    local break_at = slice:find("%s[^%s]*$") or max_w
    local line = (remaining:sub(1, break_at):gsub("%s+$", ""))
    table.insert(out, line)
    remaining = (remaining:sub(break_at + 1):gsub("^%s+", ""))
  end
  return out
end

-- Label area is 15 display cells (icon + "  " + name, padded). After that, a fixed
-- 3-space gap separates label from value. Every value — icon-prefixed or plain —
-- starts at display column 18, so alignment is consistent across all rows.
local LABEL_W = 15
local LABEL_GAP = "   "
local MAX_WIDTH = 76

function M.ticket_lines(issue)
  local f = issue.fields or {}
  local lines = {}
  local hl = {}
  local regions = {}

  local function push(text) table.insert(lines, text); return #lines - 1 end
  local function mark(lineno, col_start, col_end, group)
    table.insert(hl, { line = lineno, col_start = col_start, col_end = col_end, hl_group = group })
  end
  local function region(field, lineno, col_start, col_end, current)
    table.insert(regions, {
      field = field,
      line = lineno,
      col_start = col_start,
      col_end = col_end,
      current = current,
    })
  end

  local function row(label_icon, label_text, value, value_group, extra_hl)
    local label_part = label_icon .. "  " .. label_text
    local padded = pad_display(label_part, LABEL_W)
    local prefix = padded .. LABEL_GAP
    local line = prefix .. (value or "—")
    local lnum = push(line)
    mark(lnum, 0, #label_part, "XrayLabel")
    if value and value_group then
      mark(lnum, #prefix, #line, value_group)
    end
    if extra_hl then
      for _, h in ipairs(extra_hl) do
        mark(lnum, h.col_start, h.col_end, h.hl_group)
      end
    end
    return lnum
  end

  local function chips_row(label_icon, label_text, items, group, empty_text)
    local label_part = label_icon .. "  " .. label_text
    local padded = pad_display(label_part, LABEL_W)
    local prefix = padded .. LABEL_GAP
    if #items == 0 then
      local line = prefix .. (empty_text or "—")
      local lnum = push(line)
      mark(lnum, 0, #label_part, "XrayLabel")
      mark(lnum, #prefix, #line, "XrayStatusMuted")
      return
    end
    local chips_str = ""
    local ranges = {}
    for i, item in ipairs(items) do
      if i > 1 then chips_str = chips_str .. "  " end
      local start = #prefix + #chips_str
      chips_str = chips_str .. item
      table.insert(ranges, { col_start = start, col_end = start + #item, hl_group = group or "XrayChip" })
    end
    local line = prefix .. chips_str
    local lnum = push(line)
    mark(lnum, 0, #label_part, "XrayLabel")
    for _, r in ipairs(ranges) do
      mark(lnum, r.col_start, r.col_end, r.hl_group)
    end
  end

  local function section_header(text)
    local s = "── " .. text .. " "
    local lnum = push(s)
    mark(lnum, 0, #s, "XraySection")
  end

  -- Header line
  local itype = (type(f.issuetype) == "table" and f.issuetype.name) or "Issue"
  local header = icons.LABEL.ticket .. "  " .. (issue.key or "?") .. "   " .. itype
  local ln = push(header)
  mark(ln, 0, #icons.LABEL.ticket, "XrayLabel")
  local key_start = #icons.LABEL.ticket + 2
  local key_end = key_start + #(issue.key or "?")
  mark(ln, key_start, key_end, "XrayKey")
  mark(ln, key_end + 3, #header, "XrayType")

  -- Summary
  local summary = f.summary or "(no summary)"
  local wrapped = wrap_text(summary, MAX_WIDTH)
  for _, line in ipairs(wrapped) do
    local sln = push(line)
    mark(sln, 0, #line, "XrayTitle")
  end
  push("")

  -- Description
  if type(f.description) == "table" then
    local desc_lines = adf.to_lines(f.description, 20)
    if #desc_lines > 0 then
      section_header("Description")
      for _, dl in ipairs(desc_lines) do
        local wrapped_desc = wrap_text(dl, MAX_WIDTH)
        if #wrapped_desc == 0 then
          push("")
        else
          for _, wl in ipairs(wrapped_desc) do
            local lnum = push(wl)
            mark(lnum, 0, #wl, "XrayValue")
          end
        end
      end
      push("")
    end
  end

  -- Core
  section_header("Details")
  local status_name = (type(f.status) == "table" and f.status.name) or "—"
  local status_display = icons.status(status_name) .. " " .. status_name
  local status_lnum = row(icons.LABEL.status, "Status", status_display, status_group(status_name))
  do
    local label_part = icons.LABEL.status .. "  Status"
    local padded = pad_display(label_part, LABEL_W)
    local vstart = #padded + #LABEL_GAP
    region("status", status_lnum, vstart, vstart + #status_display, status_name)
  end

  row(icons.LABEL.type, "Type", itype, "XrayType")

  local priority_name = (type(f.priority) == "table" and f.priority.name) or "—"
  local priority_icon = priority_name ~= "—" and icons.priority(priority_name) or ""
  local priority_display = priority_icon ~= ""
    and (priority_icon .. " " .. priority_name)
    or priority_name
  row(icons.LABEL.priority, "Priority", priority_display, priority_group(priority_name))

  local team = option_value(f.customfield_10971) or "—"
  row(icons.LABEL.team, "Team", team, "XrayValue")

  -- Components
  local components = {}
  if type(f.components) == "table" then
    for _, c in ipairs(f.components) do
      if type(c) == "table" and c.name then table.insert(components, c.name) end
    end
  end
  chips_row(icons.LABEL.platforms, "Components", components, "XrayChip", "—")

  -- Fix Versions
  local fix_versions = {}
  if type(f.fixVersions) == "table" then
    for _, v in ipairs(f.fixVersions) do
      if type(v) == "table" and v.name then table.insert(fix_versions, v.name) end
    end
  end
  chips_row(icons.LABEL.updated, "Fix versions", fix_versions, "XrayChip", "None")

  -- Labels
  local labels_list = {}
  if type(f.labels) == "table" then
    for _, l in ipairs(f.labels) do
      if type(l) == "string" and l ~= "" then table.insert(labels_list, l) end
    end
  end
  chips_row(icons.LABEL.labels, "Labels", labels_list, "XrayChip", "—")

  push("")

  -- Test / QA section
  local test_severity = option_value(field_by_name(issue, "Test Severity"))
  local test_status = option_value(field_by_name(issue, "Test Status"))
  local reg_pre = option_value(field_by_name(issue, "Regression prerelease"))
  local reg_feat = option_value(field_by_name(issue, "Regression feature"))

  if test_severity or test_status or reg_pre or reg_feat then
    section_header("Test / QA")
    if test_severity then
      row(icons.LABEL.priority, "Test severity", test_severity, severity_group(test_severity))
    end
    if test_status then
      row(icons.LABEL.status, "Test status", test_status, status_group(test_status))
    end
    if reg_pre then
      row(icons.LABEL.automation, "Regr. prerel.", reg_pre, YESNO_GROUP[reg_pre] or "XrayStatusMuted")
    end
    if reg_feat then
      row(icons.LABEL.automation, "Regr. feature", reg_feat, YESNO_GROUP[reg_feat] or "XrayStatusMuted")
    end
    push("")
  end

  -- Automation section
  section_header("Automation")
  local autoreq = option_value(f.customfield_10976) or "—"
  row(icons.LABEL.automation, "Required", autoreq, YESNO_GROUP[autoreq] or "XrayStatusMuted")

  local platforms = options_list(f.customfield_10977)
  do
    local label_part = icons.LABEL.platforms .. "  Platforms"
    local padded = pad_display(label_part, LABEL_W)
    local prefix = padded .. LABEL_GAP
    if #platforms == 0 then
      local line = prefix .. "—"
      local lnum = push(line)
      mark(lnum, 0, #label_part, "XrayLabel")
      mark(lnum, #prefix, #line, "XrayStatusMuted")
      region("platforms", lnum, #prefix, #line, {})
    else
      local chips_str = ""
      local chip_ranges = {}
      for i, name in ipairs(platforms) do
        local short = PLATFORM_SHORT[name] or name
        local icon = icons.platform(name)
        local chip = icon .. " " .. short
        if i > 1 then chips_str = chips_str .. "   " end
        local start = #prefix + #chips_str
        chips_str = chips_str .. chip
        table.insert(chip_ranges, { col_start = start, col_end = start + #chip, hl_group = "XrayPlatform" })
      end
      local line = prefix .. chips_str
      local lnum = push(line)
      mark(lnum, 0, #label_part, "XrayLabel")
      for _, r in ipairs(chip_ranges) do
        mark(lnum, r.col_start, r.col_end, r.hl_group)
      end
      region("platforms", lnum, #prefix, #line, platforms)
    end
  end

  local autoon = options_list(f.customfield_10975)
  do
    local label_part = icons.LABEL.automated_on .. "  Automated on"
    local padded = pad_display(label_part, LABEL_W)
    -- The automated_on icon (check-circle) renders 1 cell wider than other label
    -- icons in this terminal, pushing the label to 16 display cells. Shrink the
    -- gap by 1 so the value still lands at column 18.
    local prefix = padded .. "  "
    if #autoon == 0 then
      local line = prefix .. "None"
      local lnum = push(line)
      mark(lnum, 0, #label_part, "XrayLabel")
      mark(lnum, #prefix, #line, "XrayStatusMuted")
      region("automated_on", lnum, #prefix, #line, {})
    else
      local chips_str = ""
      local chip_ranges = {}
      for i, name in ipairs(autoon) do
        local short = PLATFORM_SHORT[name] or name
        local icon = icons.platform(name)
        local chip = icon .. " " .. short
        if i > 1 then chips_str = chips_str .. "   " end
        local start = #prefix + #chips_str
        chips_str = chips_str .. chip
        table.insert(chip_ranges, { col_start = start, col_end = start + #chip, hl_group = "XrayStatusOk" })
      end
      local line = prefix .. chips_str
      local lnum = push(line)
      mark(lnum, 0, #label_part, "XrayLabel")
      for _, r in ipairs(chip_ranges) do
        mark(lnum, r.col_start, r.col_end, r.hl_group)
      end
      region("automated_on", lnum, #prefix, #line, autoon)
    end
  end

  push("")

  -- People
  section_header("People")
  local assignee_name = (type(f.assignee) == "table" and f.assignee.displayName) or "Unassigned"
  local assignee_account = (type(f.assignee) == "table" and f.assignee.accountId) or nil
  local assignee_group = (assignee_name == "Unassigned") and "XrayStatusMuted" or "XrayPerson"
  local assignee_lnum = row(icons.LABEL.assignee, "Assignee", assignee_name, assignee_group)
  do
    local label_part = icons.LABEL.assignee .. "  Assignee"
    local padded = pad_display(label_part, LABEL_W)
    local vstart = #padded + #LABEL_GAP
    region("assignee", assignee_lnum, vstart, vstart + #assignee_name,
      { displayName = assignee_name, accountId = assignee_account })
  end

  local reporter_name = (type(f.reporter) == "table" and f.reporter.displayName) or nil
  if reporter_name then
    row(icons.LABEL.reporter, "Reporter", reporter_name, "XrayPerson")
  end

  local updated_ago = time_ago(f.updated)
  if updated_ago then
    row(icons.LABEL.updated, "Updated", updated_ago, "XrayMuted")
  end

  -- Subtasks
  if type(f.subtasks) == "table" and #f.subtasks > 0 then
    push("")
    section_header("Subtasks (" .. #f.subtasks .. ")")
    for _, st in ipairs(f.subtasks) do
      local sf = st.fields or {}
      local st_status = (type(sf.status) == "table" and sf.status.name) or "?"
      local st_summary = sf.summary or ""
      local st_line = string.format("  %s %-12s  %s",
        icons.status(st_status), st.key or "?", st_summary)
      if vim.fn.strdisplaywidth(st_line) > MAX_WIDTH then
        st_line = st_line:sub(1, MAX_WIDTH - 1) .. "…"
      end
      local lnum = push(st_line)
      local key_s = 4
      local key_e = key_s + #(st.key or "?")
      mark(lnum, key_s, key_e, "XrayKey")
      mark(lnum, key_e, #st_line, "XrayValue")
    end
  end

  -- Linked issues
  if type(f.issuelinks) == "table" and #f.issuelinks > 0 then
    push("")
    section_header("Linked issues (" .. #f.issuelinks .. ")")
    for _, link in ipairs(f.issuelinks) do
      local outward = link.outwardIssue
      local inward = link.inwardIssue
      local ltype = (link.type or {})
      local target, relation
      if outward then
        target = outward; relation = ltype.outward or "relates to"
      elseif inward then
        target = inward; relation = ltype.inward or "relates to"
      end
      if target then
        local tf = target.fields or {}
        local t_status = (type(tf.status) == "table" and tf.status.name) or "?"
        local t_summary = tf.summary or ""
        local line = string.format("  %s %s: %-12s  %s",
          icons.status(t_status), relation, target.key or "?", t_summary)
        if vim.fn.strdisplaywidth(line) > MAX_WIDTH then
          line = line:sub(1, MAX_WIDTH - 1) .. "…"
        end
        local lnum = push(line)
        mark(lnum, 0, #line, "XrayValue")
        if target.key then
          region("link", lnum, 0, #line, target.key)
        end
      end
    end
  end

  -- Comments
  local comments_container = type(f.comment) == "table" and f.comment or nil
  local comments = (comments_container and type(comments_container.comments) == "table")
    and comments_container.comments or {}
  push("")
  section_header("Comments (" .. #comments .. ")")
  for _, c in ipairs(comments) do
    local author = (type(c.author) == "table" and c.author.displayName) or "?"
    local when = time_ago(c.updated or c.created) or ""
    local head = "  " .. author .. (when ~= "" and ("  ·  " .. when) or "")
    local hlnum = push(head)
    mark(hlnum, 2, 2 + #author, "XrayPerson")
    if when ~= "" then
      local when_start = 2 + #author + 5
      mark(hlnum, when_start, #head, "XrayMuted")
    end
    if type(c.body) == "table" then
      local body_lines = adf.to_lines(c.body, 10)
      for _, bl in ipairs(body_lines) do
        local wrapped = wrap_text(bl, MAX_WIDTH - 4)
        if #wrapped == 0 then
          push("    ")
        else
          for _, wl in ipairs(wrapped) do
            local indented = "    " .. wl
            local ln2 = push(indented)
            mark(ln2, 4, #indented, "XrayValue")
          end
        end
      end
    end
    push("")
  end

  local add_line = "  + add comment"
  local add_ln = push(add_line)
  mark(add_ln, 0, #add_line, "XrayKey")
  region("add_comment", add_ln, 0, #add_line, nil)

  push("")

  local footer = "  ? help"
  local fln = push(footer)
  mark(fln, 0, #footer, "XrayFooter")

  return { lines = lines, highlights = hl, regions = regions, key = issue.key }
end

function M.search_entry(issue)
  local f = issue.fields or {}
  local status = (type(f.status) == "table" and f.status.name) or "?"
  local summary = f.summary or ""
  return {
    key = issue.key,
    status = status,
    summary = summary,
    display = string.format("%s %-12s  %-22s  %s",
      icons.status(status), issue.key, status:sub(1, 22), summary),
    ordinal = issue.key .. " " .. status .. " " .. summary,
  }
end

return M
