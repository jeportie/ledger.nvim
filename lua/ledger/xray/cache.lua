local M = {}

local store = {}
local pending = {}

M.ttl = 5 * 60

function M.get(key)
  local entry = store[key]
  if not entry then return nil end
  if (os.time() - entry.at) > M.ttl then
    store[key] = nil
    return nil
  end
  return entry.issue
end

function M.set(key, issue)
  if not issue then return end
  store[key] = { issue = issue, at = os.time() }
end

function M.clear(key)
  if key then store[key] = nil else store = {} end
end

function M.register_pending(key, callback)
  if pending[key] then
    table.insert(pending[key], callback)
    return false
  end
  pending[key] = { callback }
  return true
end

function M.resolve_pending(key, issue, err)
  local waiters = pending[key]
  pending[key] = nil
  if not waiters then return end
  for _, cb in ipairs(waiters) do
    pcall(cb, issue, err)
  end
end

function M.fetch(key, callback)
  local cached = M.get(key)
  if cached then
    vim.schedule(function() callback(cached, nil) end)
    return
  end
  if not M.register_pending(key, callback) then
    return
  end
  require("ledger.xray.api").get_issue(key, function(issue, err)
    if issue then M.set(key, issue) end
    M.resolve_pending(key, issue, err)
  end)
end

function M.fetch_batch(keys, callback)
  local missing, seen = {}, {}
  for _, k in ipairs(keys) do
    if not seen[k] and not M.get(k) then
      seen[k] = true
      table.insert(missing, k)
    end
  end
  if #missing == 0 then
    if callback then vim.schedule(function() callback(nil) end) end
    return
  end
  require("ledger.xray.api").get_issues_by_keys(missing, function(issues, err)
    if err then
      if callback then vim.schedule(function() callback(err) end) end
      return
    end
    for _, issue in ipairs(issues or {}) do
      if issue.key then M.set(issue.key, issue) end
    end
    if callback then vim.schedule(function() callback(nil) end) end
  end)
end

return M
