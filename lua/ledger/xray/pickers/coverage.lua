local M = {}

local util = require("ledger.xray.util")
local float = require("ledger.xray.float")
local icons = require("ledger.xray.icons")

local classify = util.classify_path

-- Session cache of ticket IDs referenced in the ledger-live codebase, used to
-- offer autocomplete in the coverage input prompt.
local _id_cache = { ids = nil, root = nil }

local function verdict(counts)
  if counts.desktop == 0 and counts.mobile == 0 and counts.other == 0 then
    return "No references"
  end
  if counts.desktop > 0 and counts.mobile > 0 then
    return "Both (desktop + mobile)"
  end
  if counts.desktop > 0 then
    return "Desktop-only"
  end
  if counts.mobile > 0 then
    return "Mobile-only"
  end
  return "Other only"
end

local function verdict_icon(v)
  return icons.VERDICT[v] or ""
end

local CATEGORY_META = {
  desktop = { label = "Desktop", icon = icons.COVERAGE.desktop },
  mobile = { label = "Mobile", icon = icons.COVERAGE.mobile },
  other = { label = "Other", icon = icons.COVERAGE.other },
}

local function build_lines_and_index(id, root, groups, counts)
  local v = verdict(counts)
  local lines = {
    icons.LABEL.ticket .. "  ID:      " .. id,
    icons.ACTION.jump .. "  Root:    " .. root,
    verdict_icon(v) .. "  Verdict: " .. v,
    "",
  }
  local index = {}

  local order = { "desktop", "mobile", "other" }

  for _, cat in ipairs(order) do
    local matches = groups[cat]
    local count = counts[cat]
    local meta = CATEGORY_META[cat]
    table.insert(lines, string.format("%s  %s: %d refs", meta.icon, meta.label, count))
    if count > 0 then
      local limit = math.min(#matches, 8)
      for i = 1, limit do
        local m = matches[i]
        local rel = m.path:sub(#root + 2)
        local icon = icons.devicon(m.path)
        table.insert(lines, string.format("   %s %s:%d", icon, rel, m.line))
        index[#lines] = m
      end
      if count > limit then
        table.insert(lines, string.format("   … +%d more", count - limit))
      end
    end
    table.insert(lines, "")
  end

  table.insert(
    lines,
    string.format("%s <CR> jump   <Tab>/<S-Tab> next/prev ref   %s q close", icons.ACTION.jump, icons.ACTION.close)
  )
  return lines, index
end

local function sorted_index_lines(index)
  local keys = {}
  for k in pairs(index) do
    table.insert(keys, k)
  end
  table.sort(keys)
  return keys
end

local function jump_to_ref(m)
  vim.cmd("edit " .. vim.fn.fnameescape(m.path))
  local col = (m.col or 1) - 1
  pcall(vim.api.nvim_win_set_cursor, 0, { m.line, col })
  vim.cmd("normal! zz")
end

local function scan(id)
  local root = util.find_ledger_live_root() or vim.fn.getcwd()

  if vim.fn.executable("rg") ~= 1 then
    vim.notify("xray: ripgrep (rg) not found in PATH", vim.log.levels.ERROR)
    return
  end

  vim.notify("xray: scanning " .. root .. " for " .. id .. "…", vim.log.levels.INFO)

  vim.system({
    "rg",
    "--line-number",
    "--column",
    "--no-heading",
    "--color=never",
    "--fixed-strings",
    id,
    root,
  }, { text = true }, function(obj)
    vim.schedule(function()
      local has_output = obj.stdout and obj.stdout ~= ""
      if obj.code ~= 0 and obj.code ~= 1 and not has_output then
        vim.notify("xray: rg failed: " .. (obj.stderr or ""), vim.log.levels.ERROR)
        return
      end

      local groups = { desktop = {}, mobile = {}, other = {} }
      local counts = { desktop = 0, mobile = 0, other = 0 }

      for line in (obj.stdout or ""):gmatch("[^\n]+") do
        local path, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
        if path and lnum then
          local cat = classify(path)
          local match = {
            path = path,
            line = tonumber(lnum),
            col = tonumber(col),
            text = text,
          }
          table.insert(groups[cat], match)
          counts[cat] = counts[cat] + 1
        end
      end

      local lines, index = build_lines_and_index(id, root, groups, counts)

      local buf, win, close = float.open("Coverage: " .. id, lines, {
        on_enter = function(_, lnum)
          local m = index[lnum]
          if m then
            jump_to_ref(m)
          end
        end,
      })

      local ref_lines = sorted_index_lines(index)
      if #ref_lines > 0 then
        local function jump_to(target)
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_cursor(win, { target, 0 })
          end
        end
        local function next_ref()
          local cur = vim.api.nvim_win_get_cursor(win)[1]
          for _, k in ipairs(ref_lines) do
            if k > cur then
              jump_to(k)
              return
            end
          end
          jump_to(ref_lines[1])
        end
        local function prev_ref()
          local cur = vim.api.nvim_win_get_cursor(win)[1]
          local prev
          for _, k in ipairs(ref_lines) do
            if k < cur then
              prev = k
            else
              break
            end
          end
          jump_to(prev or ref_lines[#ref_lines])
        end
        vim.keymap.set("n", "<Tab>", next_ref, { buffer = buf, nowait = true, silent = true })
        vim.keymap.set("n", "<S-Tab>", prev_ref, { buffer = buf, nowait = true, silent = true })
        jump_to(ref_lines[1])
      end

      local _ = close
    end)
  end)
end

local function validate_and_scan(input)
  local id = util.extract_id(input:upper()) or (input:upper():match("^%d+$") and "B2CQA-" .. input) or input:upper()
  if not id:match("^B2CQA%-%d+$") then
    vim.notify("xray: expected B2CQA-<number>, got " .. input, vim.log.levels.ERROR)
    return
  end
  scan(id)
end

local function load_id_cache()
  local root = util.find_ledger_live_root() or vim.fn.getcwd()
  if _id_cache.ids and _id_cache.root == root then
    return _id_cache.ids
  end
  if vim.fn.executable("rg") ~= 1 then
    return {}
  end

  local obj = vim
    .system({
      "rg",
      "--only-matching",
      "--no-filename",
      "--no-line-number",
      "--color=never",
      "B2CQA-[0-9]+",
      root,
    }, { text = true })
    :wait()

  local seen = {}
  local ids = {}
  for line in (obj.stdout or ""):gmatch("[^\n]+") do
    local id = line:match("B2CQA%-%d+")
    if id and not seen[id] then
      seen[id] = true
      table.insert(ids, id)
    end
  end
  table.sort(ids, function(a, b)
    local na = tonumber(a:match("%d+"))
    local nb = tonumber(b:match("%d+"))
    return na < nb
  end)
  _id_cache.ids = ids
  _id_cache.root = root
  return ids
end

_G.XrayCoverageComplete = function(arg_lead, _, _)
  local ids = load_id_cache()
  local lead = arg_lead:upper()
  if lead == "" then
    return ids
  end
  local matches = {}
  for _, id in ipairs(ids) do
    if id:sub(1, #lead) == lead then
      table.insert(matches, id)
    end
  end
  return matches
end

function M.run()
  local cursor_id = util.cword_id()
  if cursor_id then
    scan(cursor_id)
    return
  end

  vim.schedule(function()
    load_id_cache()
  end)

  local ok, input = pcall(vim.fn.input, {
    prompt = "Xray coverage — ticket ID: ",
    default = "B2CQA-",
    completion = "customlist,v:lua.XrayCoverageComplete",
    cancelreturn = "",
  })
  if not ok or not input or input == "" then
    return
  end
  if input == "B2CQA-" then
    return
  end
  validate_and_scan(input)
end

return M
