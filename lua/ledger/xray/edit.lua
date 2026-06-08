local M = {}

local api = require("ledger.xray.api")
local cache = require("ledger.xray.cache")

local PLATFORM_OPTIONS = { "Windows", "MacOS", "Linux", "Android", "iOS" }

local AUTOMATED_ON_OPTIONS = {
  "None",
  "LLD (Playwright)",
  "LLM (Detox)",
  "LLC (Ledger-bot)",
  "Live-app (Playwright)",
  "LLD (Speculos)",
  "LLM (Speculos)",
}

-- Jira multicheckbox fields match options by exact string when given `{value}`,
-- and silently drop non-matching entries. Using `{id}` avoids that whole class
-- of whitespace/encoding mismatches.
local AUTOMATED_ON_ID = {
  ["None"] = "12632",
  ["LLD (Playwright)"] = "12633",
  ["LLM (Detox)"] = "12634",
  ["LLC (Ledger-bot)"] = "12635",
  ["Live-app (Playwright)"] = "13129",
  ["LLD (Speculos)"] = "16715",
  ["LLM (Speculos)"] = "16960",
}

local MULTI_FIELDS = {
  platforms = {
    id = "customfield_10977",
    label = "Platforms",
    options = PLATFORM_OPTIONS,
    is_platform_like = true,
  },
  automated_on = {
    id = "customfield_10975",
    label = "Automated on",
    options = AUTOMATED_ON_OPTIONS,
    is_platform_like = false,
    id_map = AUTOMATED_ON_ID,
  },
}

-- opts: { key, anchor, on_status_change, on_refresh }
--   key              — ticket key (required)
--   anchor           — "cursor" to anchor dispatched pickers near the cursor (e.g., from hover)
--   on_status_change — called as (new_status_name) after a status transition, before on_refresh
--   on_refresh       — called after any successful change; callers should re-render their view
function M.dispatch(r, opts)
  local key = opts.key
  if not key then
    return
  end
  local anchor = opts.anchor

  if r.field == "link" then
    local target = r.current
    if type(target) == "string" and target ~= "" then
      require("ledger.xray.hover").trigger(target, { focus = true })
    end
    return
  end

  if r.field == "status" then
    require("ledger.xray.pickers.status").open(key, r.current, function(new_status, err)
      if err or not new_status then
        return
      end
      cache.clear(key)
      if opts.on_status_change then
        pcall(opts.on_status_change, new_status)
      end
      if opts.on_refresh then
        pcall(opts.on_refresh)
      end
    end, { anchor = anchor })
    return
  end

  if r.field == "add_comment" then
    require("ledger.xray.pickers.comment").open(key, function(ok, err)
      if err or not ok then
        return
      end
      cache.clear(key)
      if opts.on_refresh then
        pcall(opts.on_refresh)
      end
    end, { anchor = anchor })
    return
  end

  if r.field == "assignee" then
    local current = type(r.current) == "table" and r.current or {}
    require("ledger.xray.pickers.assignee").open(key, current, function(result, err)
      if err or result == nil then
        return
      end
      cache.clear(key)
      if opts.on_refresh then
        pcall(opts.on_refresh)
      end
    end, { anchor = anchor })
    return
  end

  local multi = MULTI_FIELDS[r.field]
  if multi then
    require("ledger.xray.pickers.multi_select").open({
      title = multi.label .. " — " .. key,
      options = multi.options,
      current = r.current,
      is_platform_like = multi.is_platform_like,
      anchor = anchor,
      on_done = function(result, _)
        if result == nil then
          return
        end
        local value = {}
        for _, v in ipairs(result) do
          if multi.id_map and multi.id_map[v] then
            table.insert(value, { id = multi.id_map[v] })
          else
            table.insert(value, { value = v })
          end
        end
        api.update_field(key, multi.id, value, function(_, ferr)
          if ferr then
            vim.notify(ferr, vim.log.levels.ERROR)
            return
          end
          cache.clear(key)
          if opts.on_refresh then
            pcall(opts.on_refresh)
          end
        end)
      end,
    })
    return
  end

  vim.notify("xray: edit " .. (r.field or "?") .. " (not wired yet)", vim.log.levels.INFO)
end

return M
