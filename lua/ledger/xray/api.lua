local M = {}

local jira = require("ledger.jira.api")
local config = require("ledger.xray.config")

M.request = jira.request
M.get_issue = jira.get_issue
M.list_fields = jira.list_fields
M.search_issues = jira.search_issues
M.search_all = jira.search_all
M.add_comment = jira.add_comment
M.get_myself = jira.get_myself
M.search_users = jira.search_users
M.set_assignee = jira.set_assignee
M.update_field = jira.update_field
M.get_transitions = jira.get_transitions
M.do_transition = jira.do_transition

local FIELDS_ALL = { "*all", "-worklog", "-attachment" }

function M.get_issues_by_keys(keys, callback)
  if not keys or #keys == 0 then
    vim.schedule(function()
      callback({}, nil)
    end)
    return
  end

  local creds = config.credentials()
  if not creds then
    vim.schedule(function()
      callback(nil, "xray: missing credentials")
    end)
    return
  end

  local project = config.options.project_key
  local quoted = {}
  for _, k in ipairs(keys) do
    table.insert(quoted, '"' .. k .. '"')
  end
  local jql = string.format("project = %s AND issuekey in (%s)", project, table.concat(quoted, ", "))

  M.search_issues(jql, function(data, err)
    if err then
      callback(nil, err)
      return
    end
    callback((data and data.issues) or {}, nil)
  end, {
    fields = table.concat(FIELDS_ALL, ","),
    expand = "names",
    max_results = math.min(#keys, 100),
  })
end

function M.build_jql(project_key, query)
  if not query or query == "" then
    return string.format("project = %s ORDER BY updated DESC", project_key)
  end

  local id = query:match("[Bb]2[Cc][Qq][Aa]%-%d+")
  if id then
    return string.format('project = %s AND issuekey = "%s"', project_key, id:upper())
  end

  local numeric = query:match("^%d+$")
  if numeric then
    return string.format('project = %s AND issuekey = "%s-%s" ORDER BY updated DESC', project_key, project_key, numeric)
  end

  local escaped = query:gsub('"', '\\"')
  return string.format(
    'project = %s AND (summary ~ "%s" OR text ~ "%s") ORDER BY updated DESC',
    project_key,
    escaped,
    escaped
  )
end

return M
