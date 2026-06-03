local M = {}

local api = require("ledger.jira.api")

-- GET /rest/agile/1.0/board?name=<name>&projectKeyOrId=<key>
function M.find_boards(opts, callback)
  opts = opts or {}
  local query = { maxResults = 50 }
  if opts.name then query.name = opts.name end
  if opts.project then query.projectKeyOrId = opts.project end
  if opts.type then query.type = opts.type end
  api.request({ path = "/rest/agile/1.0/board", query = query }, callback)
end

-- GET /rest/agile/1.0/board/{id}/configuration
function M.get_board_config(board_id, callback)
  api.request({
    path = "/rest/agile/1.0/board/" .. tostring(board_id) .. "/configuration",
  }, callback)
end

-- GET /rest/agile/1.0/board/{id}/issue
function M.get_board_issues(board_id, opts, callback)
  opts = opts or {}
  local query = {
    maxResults = opts.max_results or 100,
    fields = opts.fields or "summary,status,priority,assignee,labels,issuetype",
  }
  if opts.jql then query.jql = opts.jql end
  if opts.start_at then query.startAt = opts.start_at end
  api.request({
    path = "/rest/agile/1.0/board/" .. tostring(board_id) .. "/issue",
    query = query,
  }, callback)
end

-- Page through board issues using startAt pagination
function M.get_all_board_issues(board_id, opts, on_done)
  opts = opts or {}
  local page_cap = opts.page_cap or 20
  local page_size = opts.max_results or 100
  local acc = {}
  local pages_loaded = 0

  local function fetch(start_at)
    M.get_board_issues(board_id, {
      max_results = page_size,
      start_at = start_at,
      jql = opts.jql,
      fields = opts.fields,
    }, function(data, err)
      if err then on_done(nil, err); return end
      pages_loaded = pages_loaded + 1
      local issues = (data and data.issues) or {}
      for _, i in ipairs(issues) do table.insert(acc, i) end
      local total = (data and data.total) or 0
      local fetched = (start_at or 0) + #issues
      if fetched < total and #issues > 0 and pages_loaded < page_cap then
        fetch(fetched)
      else
        on_done(acc, nil, {
          pages = pages_loaded,
          total = total,
          truncated = fetched < total,
        })
      end
    end)
  end

  fetch(0)
end

-- Convenience: find a single board by exact name match (returns first exact match,
-- else first fuzzy match, else nil)
function M.find_board_by_name(name, project, callback)
  M.find_boards({ name = name, project = project }, function(data, err)
    if err then callback(nil, err); return end
    local values = (data and data.values) or {}
    if #values == 0 then
      callback(nil, "jira: no board matching '" .. name .. "'")
      return
    end
    for _, b in ipairs(values) do
      if b.name == name then callback(b, nil); return end
    end
    callback(values[1], nil)
  end)
end

return M
