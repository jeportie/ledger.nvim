local M = {}

local function fresh()
  return {
    board_id = nil,
    board_name = nil,
    columns = {},
    status_to_column = {},
    issues = {},
    -- Legacy single-assignee filter (used by 'A' keymap).
    filter_assignee = nil,
    filter_assignee_label = nil,
    -- Multi-category filter sets. Key = value, Val = label string.
    filters = {
      assignees = {},
      epics     = {},
      types     = {},
      labels    = {},
    },
    hide_backlog = false,
    collapsed_epics = {}, -- set keyed by epic key ("" for "No Epic" bucket)
    loading = false,
    error = nil,
    me = nil,
  }
end

M.state = fresh()

function M.reset() M.state = fresh() end

function M.set_board(id, name)
  M.state.board_id = id
  M.state.board_name = name
end

function M.set_columns(columns)
  M.state.columns = columns or {}
  M.state.status_to_column = {}
  for i, col in ipairs(M.state.columns) do
    for _, id in ipairs(col.status_ids or {}) do
      M.state.status_to_column[tostring(id)] = i
    end
    for _, st in ipairs(col.statuses or {}) do
      M.state.status_to_column[st] = i
    end
  end
end

function M.set_issues(issues)
  M.state.issues = issues or {}
end

function M.set_filter(account_id, label)
  M.state.filter_assignee = account_id
  M.state.filter_assignee_label = label
end

function M.set_me(account_id, label, avatar_url)
  M.state.me = { accountId = account_id, label = label, avatar_url = avatar_url }
end

-- Replace a filter category entirely. values is a map {id = label}.
function M.set_filter_category(category, values)
  if not M.state.filters[category] then return end
  M.state.filters[category] = values or {}
end

function M.clear_filters()
  for cat in pairs(M.state.filters) do M.state.filters[cat] = {} end
  M.state.filter_assignee = nil
  M.state.filter_assignee_label = nil
end

function M.has_active_filters()
  for _, set in pairs(M.state.filters) do
    if next(set) ~= nil then return true end
  end
  return M.state.filter_assignee ~= nil
end

function M.filter_summary()
  local bits = {}
  for cat, set in pairs(M.state.filters) do
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    if n > 0 then table.insert(bits, cat .. ":" .. n) end
  end
  return bits
end

function M.toggle_backlog()
  M.state.hide_backlog = not M.state.hide_backlog
  return M.state.hide_backlog
end

local function epic_slot(key) return key or "__no_epic__" end

function M.is_epic_collapsed(key)
  return M.state.collapsed_epics[epic_slot(key)] == true
end

function M.toggle_epic_collapsed(key)
  local slot = epic_slot(key)
  if M.state.collapsed_epics[slot] then
    M.state.collapsed_epics[slot] = nil
  else
    M.state.collapsed_epics[slot] = true
  end
  return M.state.collapsed_epics[slot] == true
end

function M.set_all_epics_collapsed(value)
  M.state.collapsed_epics = {}
  if value then
    for _, b in ipairs(M.epic_groups() or {}) do
      M.state.collapsed_epics[epic_slot(b.key)] = true
    end
  end
end

-- True when there is at least one epic and every epic is collapsed.
function M.all_epics_collapsed()
  local bands = M.epic_groups() or {}
  if #bands == 0 then return false end
  for _, b in ipairs(bands) do
    if not M.state.collapsed_epics[epic_slot(b.key)] then return false end
  end
  return true
end

function M.visible_columns()
  local out = {}
  for _, col in ipairs(M.state.columns) do
    if not (M.state.hide_backlog and col.name and col.name:lower():find("backlog")) then
      table.insert(out, col)
    end
  end
  return out
end

function M.visible_column_index(original_idx)
  local visible = M.visible_columns()
  local col = M.state.columns[original_idx]
  if not col then return nil end
  for i, v in ipairs(visible) do
    if v == col then return i end
  end
  return nil
end

function M.original_column_index(visible_idx)
  local visible = M.visible_columns()
  local col = visible[visible_idx]
  if not col then return nil end
  for i, c in ipairs(M.state.columns) do
    if c == col then return i end
  end
  return nil
end

local function present(v)
  if v == nil or v == vim.NIL then return nil end
  return v
end

local function set_has(set)
  return next(set) ~= nil
end

local function issue_matches_filters(issue)
  local f = M.state.filters
  local fields = issue.fields or {}

  -- Legacy single assignee filter
  if M.state.filter_assignee then
    local a = present(fields.assignee)
    if not (a and present(a.accountId) == M.state.filter_assignee) then
      return false
    end
  end

  if set_has(f.assignees) then
    local a = present(fields.assignee)
    local aid = a and present(a.accountId) or nil
    if not (aid and f.assignees[aid]) then return false end
  end

  if set_has(f.types) then
    local it = present(fields.issuetype)
    local name = it and present(it.name) or nil
    if not (name and f.types[name]) then return false end
  end

  if set_has(f.labels) then
    local labels = fields.labels
    if type(labels) ~= "table" or #labels == 0 then return false end
    local ok = false
    for _, l in ipairs(labels) do
      if f.labels[l] then ok = true; break end
    end
    if not ok then return false end
  end

  if set_has(f.epics) then
    local parent = present(fields.parent)
    local pkey = parent and present(parent.key) or nil
    if not (pkey and f.epics[pkey]) then return false end
  end

  return true
end

local function issues_matching(col)
  if not col then return {} end
  local ids = {}
  for _, id in ipairs(col.status_ids or {}) do ids[tostring(id)] = true end
  local names = {}
  for _, st in ipairs(col.statuses or {}) do names[st] = true end

  local out = {}
  for _, issue in ipairs(M.state.issues) do
    local status = present(issue.fields and issue.fields.status)
    local sid = status and present(status.id) and tostring(status.id)
    local sname = status and present(status.name)
    local match = (sid and ids[sid]) or (sname and names[sname])
    if match and issue_matches_filters(issue) then
      table.insert(out, issue)
    end
  end

  -- Sort by epic key so same-epic issues are adjacent (stable fallback on key).
  table.sort(out, function(a, b)
    local pa = present(a.fields and a.fields.parent); pa = pa and present(pa.key) or ""
    local pb = present(b.fields and b.fields.parent); pb = pb and present(pb.key) or ""
    if pa ~= pb then return pa < pb end
    return (a.key or "") < (b.key or "")
  end)
  return out
end

-- Expose unique options per filter category, derived from loaded issues.
function M.filter_options(category)
  local seen = {}
  local options = {} -- list of { id = ..., label = ... }
  for _, issue in ipairs(M.state.issues) do
    local f = issue.fields or {}
    if category == "assignees" then
      local a = present(f.assignee)
      local id = a and present(a.accountId) or nil
      if id and not seen[id] then
        seen[id] = true
        table.insert(options, { id = id, label = present(a.displayName) or present(a.emailAddress) or id })
      end
    elseif category == "types" then
      local it = present(f.issuetype)
      local name = it and present(it.name) or nil
      if name and not seen[name] then
        seen[name] = true
        table.insert(options, { id = name, label = name })
      end
    elseif category == "labels" then
      if type(f.labels) == "table" then
        for _, l in ipairs(f.labels) do
          if l and l ~= "" and not seen[l] then
            seen[l] = true
            table.insert(options, { id = l, label = l })
          end
        end
      end
    elseif category == "epics" then
      local parent = present(f.parent)
      local pkey = parent and present(parent.key) or nil
      if pkey and not seen[pkey] then
        seen[pkey] = true
        local psum = parent.fields and present(parent.fields.summary) or ""
        table.insert(options, { id = pkey, label = pkey .. (psum ~= "" and (" · " .. psum) or "") })
      end
    end
  end
  table.sort(options, function(a, b) return a.label < b.label end)
  return options
end

function M.issues_in_column(idx)
  return issues_matching(M.state.columns[idx])
end

function M.issues_in_visible_column(vidx)
  return issues_matching(M.visible_columns()[vidx])
end

function M.total_filtered()
  local n = 0
  for _, col in ipairs(M.visible_columns()) do
    n = n + #issues_matching(col)
  end
  return n
end

-- List of unique epics currently visible after filters, sorted by key.
function M.visible_epics()
  local seen = {}
  local out = {}
  for _, col in ipairs(M.visible_columns()) do
    for _, issue in ipairs(issues_matching(col)) do
      local p = present(issue.fields and issue.fields.parent)
      local k = p and present(p.key) or nil
      if k and not seen[k] then
        seen[k] = true
        local sum = (p.fields and present(p.fields.summary)) or ""
        table.insert(out, { key = k, summary = sum })
      end
    end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

-- Group visible issues by epic. Returns an ordered list of bands:
--   { { key = "QAA-…", summary = "…", issues_by_col = { [vidx] = { issue, … }, … }, total = N }, … }
-- The last band is always the orphan bucket with key = nil and label = "No Epic".
-- issues_by_col is indexed by visible-column index (1-based).
function M.epic_groups()
  local vcols = M.visible_columns()
  local bands = {} -- key-indexed accumulator
  local order = {} -- stable order of seen epic keys
  local orphan = { key = nil, summary = "No Epic", issues_by_col = {}, total = 0 }
  for i = 1, #vcols do orphan.issues_by_col[i] = {} end

  local function ensure_band(key, summary)
    local b = bands[key]
    if not b then
      b = { key = key, summary = summary or "", issues_by_col = {}, total = 0 }
      for i = 1, #vcols do b.issues_by_col[i] = {} end
      bands[key] = b
      table.insert(order, key)
    end
    return b
  end

  for vidx, col in ipairs(vcols) do
    for _, issue in ipairs(issues_matching(col)) do
      local parent = present(issue.fields and issue.fields.parent)
      local pkey = parent and present(parent.key) or nil
      if pkey then
        local psum = (parent.fields and present(parent.fields.summary)) or ""
        local band = ensure_band(pkey, psum)
        table.insert(band.issues_by_col[vidx], issue)
        band.total = band.total + 1
      else
        table.insert(orphan.issues_by_col[vidx], issue)
        orphan.total = orphan.total + 1
      end
    end
  end

  table.sort(order)
  local out = {}
  for _, k in ipairs(order) do table.insert(out, bands[k]) end
  if orphan.total > 0 then table.insert(out, orphan) end
  return out
end

return M
