local M = {}

local config = require("ledger.jira.config")

local function basic_auth(email, token)
  local raw = email .. ":" .. token
  if vim.base64 and vim.base64.encode then
    return "Basic " .. vim.base64.encode(raw)
  end
  local ok, b64 = pcall(require, "plenary.base64")
  if ok and b64.encode then
    return "Basic " .. b64.encode(raw)
  end
  error("jira: no base64 encoder available (need Neovim 0.10+ or plenary)")
end

local function headers(creds)
  return {
    ["Authorization"] = basic_auth(creds.email, creds.token),
    ["Accept"] = "application/json",
    ["Content-Type"] = "application/json",
  }
end

local function parse_json(body)
  if not body or body == "" then return nil end
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok then return nil end
  return decoded
end

function M.request(opts, callback)
  local creds, err = config.credentials()
  if not creds then
    vim.schedule(function() callback(nil, err) end)
    return
  end

  local curl = require("plenary.curl")
  curl.request({
    url = creds.url .. opts.path,
    method = opts.method or "get",
    headers = headers(creds),
    query = opts.query,
    body = opts.body,
    timeout = config.options.timeout_ms,
    callback = function(response)
      vim.schedule(function()
        if not response then
          callback(nil, "jira: no response")
          return
        end
        if response.status >= 400 then
          local msg = "jira: " .. tostring(response.status)
          local parsed = parse_json(response.body)
          if parsed and parsed.errorMessages and parsed.errorMessages[1] then
            msg = msg .. " — " .. parsed.errorMessages[1]
          end
          callback(nil, msg)
          return
        end
        if not response.body or response.body == "" then
          callback({}, nil)
          return
        end
        local decoded = parse_json(response.body)
        if not decoded then
          callback(nil, "jira: failed to parse response")
          return
        end
        callback(decoded, nil)
      end)
    end,
  })
end

local FIELDS_ALL = { "*all", "-worklog", "-attachment" }

function M.get_issue(key, callback)
  M.request({
    path = "/rest/api/3/issue/" .. key,
    query = {
      fields = table.concat(FIELDS_ALL, ","),
      expand = "names",
    },
  }, callback)
end

function M.list_fields(callback)
  M.request({ path = "/rest/api/3/field" }, callback)
end

function M.search_issues(jql, callback, opts)
  opts = opts or {}
  local query = {
    jql = jql,
    fields = opts.fields or table.concat({ "summary", "status", "issuetype" }, ","),
    maxResults = opts.max_results or 100,
  }
  if opts.expand then query.expand = opts.expand end
  if opts.next_page_token then query.nextPageToken = opts.next_page_token end
  M.request({ path = "/rest/api/3/search/jql", query = query }, callback)
end

function M.search_all(jql, opts, on_page, on_done)
  opts = opts or {}
  local page_cap = opts.page_cap or 50
  local page_size = opts.max_results or 100
  local fields = opts.fields
  local expand = opts.expand
  local pages_loaded = 0

  local function fetch(token)
    M.search_issues(jql, function(data, err)
      if err then on_done(err); return end
      pages_loaded = pages_loaded + 1
      local issues = (data and data.issues) or {}
      local is_last = data and data.isLast
      on_page(issues, { page = pages_loaded, is_last = is_last })
      if data and data.nextPageToken and not is_last and pages_loaded < page_cap then
        fetch(data.nextPageToken)
      else
        on_done(nil, { pages = pages_loaded, truncated = pages_loaded >= page_cap and not is_last })
      end
    end, { max_results = page_size, next_page_token = token, fields = fields, expand = expand })
  end

  fetch(nil)
end

function M.add_comment(key, adf_body, callback)
  M.request({
    method = "post",
    path = "/rest/api/3/issue/" .. key .. "/comment",
    body = vim.json.encode({ body = adf_body }),
  }, callback)
end

function M.get_myself(callback)
  M.request({ path = "/rest/api/3/myself" }, callback)
end

function M.search_users(query, callback)
  M.request({
    path = "/rest/api/3/user/search",
    query = { query = query or "", maxResults = 20 },
  }, callback)
end

function M.set_assignee(key, account_id, callback)
  local body
  if account_id == nil or account_id == vim.NIL then
    body = vim.json.encode({ fields = { assignee = vim.NIL } })
  else
    body = vim.json.encode({ fields = { assignee = { accountId = account_id } } })
  end
  M.request({
    method = "put",
    path = "/rest/api/3/issue/" .. key,
    body = body,
  }, callback)
end

function M.set_reporter(key, account_id, callback)
  local body
  if account_id == nil or account_id == vim.NIL then
    body = vim.json.encode({ fields = { reporter = vim.NIL } })
  else
    body = vim.json.encode({ fields = { reporter = { accountId = account_id } } })
  end
  M.request({
    method = "put",
    path = "/rest/api/3/issue/" .. key,
    body = body,
  }, callback)
end

function M.update_field(key, field_id, value, callback)
  M.request({
    method = "put",
    path = "/rest/api/3/issue/" .. key,
    body = vim.json.encode({ fields = { [field_id] = value } }),
  }, callback)
end

function M.get_transitions(key, callback)
  M.request({
    path = "/rest/api/3/issue/" .. key .. "/transitions",
  }, callback)
end

function M.do_transition(key, transition_id, callback)
  M.request({
    method = "post",
    path = "/rest/api/3/issue/" .. key .. "/transitions",
    body = vim.json.encode({ transition = { id = tostring(transition_id) } }),
  }, callback)
end

return M
