local M = {}

local defaults = {
  env = {
    email = "JIRA_EMAIL",
    token = "JIRA_API_TOKEN",
    url = "JIRA_URL",
  },
  timeout_ms = 10000,
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", defaults, opts or {})
end

local function env(key)
  local v = vim.env[key]
  if v == nil or v == "" then
    return nil
  end
  return v
end

function M.credentials()
  local email = env(M.options.env.email)
  local token = env(M.options.env.token)
  local url = env(M.options.env.url)

  local missing = {}
  if not email then
    table.insert(missing, M.options.env.email)
  end
  if not token then
    table.insert(missing, M.options.env.token)
  end
  if not url then
    table.insert(missing, M.options.env.url)
  end

  if #missing > 0 then
    return nil, "jira: missing env var(s): " .. table.concat(missing, ", ")
  end

  return {
    email = email,
    token = token,
    url = url:gsub("/+$", ""),
  }
end

return M
