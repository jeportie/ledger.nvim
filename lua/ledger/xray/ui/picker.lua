local M = {}

local api_jira = require("ledger.xray.api")
local cache = require("ledger.xray.cache")
local config = require("ledger.xray.config")
local format = require("ledger.xray.format")
local icons = require("ledger.xray.icons")
local util = require("ledger.xray.util")
local insert_mod = require("ledger.xray.insert")

local LIST_CACHE_TTL = 5 * 60
local list_cache = {
  issues = nil,
  at = 0,
  truncated = false,
  state = "idle", -- "idle" | "loading" | "done"
  subscribers = {},
}

local function cache_notify(new_issues, done, err)
  local subs = list_cache.subscribers
  if done then
    list_cache.subscribers = {}
  end
  for _, sub in ipairs(subs) do
    pcall(sub, new_issues, done, err)
  end
end

local global_fetch_session = 0

local S = {}

local function reset_state()
  S = {
    prompt_win = nil,
    results_win = nil,
    detail_win = nil,
    prompt_buf = nil,
    results_buf = nil,
    detail_buf = nil,
    all_issues = {},
    filtered = {},
    detail_cache = {},
    selected_idx = 0,
    fetch_session = 0,
    fetch_done = false,
    autocmds = {},
    ns = nil,
    focus = "prompt",
    closed = false,
    truncated = false,
  }
end

reset_state()

local function safe_del_autocmd(id)
  pcall(vim.api.nvim_del_autocmd, id)
end

local function close_all()
  if S.closed then
    return
  end
  S.closed = true
  pcall(function()
    require("ledger.xray.help").close()
  end)
  if S.detail_buf then
    pcall(function()
      require("ledger.xray.editor").detach(S.detail_buf)
    end)
  end
  for _, id in ipairs(S.autocmds) do
    safe_del_autocmd(id)
  end
  for _, win in ipairs({ S.prompt_win, S.results_win, S.detail_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ S.prompt_buf, S.results_buf, S.detail_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  reset_state()
end

local function make_display(issue)
  local f = issue.fields or {}
  local status = (type(f.status) == "table" and f.status.name) or "?"
  local itype = (type(f.issuetype) == "table" and f.issuetype.name) or ""
  local summary = f.summary or ""
  return string.format(
    "%s %-12s  %-10s  %-22s  %s",
    icons.status(status),
    issue.key,
    itype:sub(1, 10),
    status:sub(1, 22),
    summary
  )
end

local function render_results()
  if not S.results_buf or not vim.api.nvim_buf_is_valid(S.results_buf) then
    return
  end
  local lines = {}
  if #S.filtered == 0 then
    lines = { "  (no matches)" }
  else
    for _, issue in ipairs(S.filtered) do
      table.insert(lines, make_display(issue))
    end
  end
  vim.bo[S.results_buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.results_buf, 0, -1, false, lines)
  vim.bo[S.results_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(S.results_buf, S.ns, 0, -1)
  if #S.filtered > 0 and S.selected_idx >= 1 and S.selected_idx <= #S.filtered then
    pcall(vim.api.nvim_buf_set_extmark, S.results_buf, S.ns, S.selected_idx - 1, 0, {
      line_hl_group = "XraySelected",
    })
    if S.results_win and vim.api.nvim_win_is_valid(S.results_win) then
      pcall(vim.api.nvim_win_set_cursor, S.results_win, { S.selected_idx, 0 })
    end
  end
end

local function render_detail_content(lines, highlights)
  vim.bo[S.detail_buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.detail_buf, 0, -1, false, lines)
  vim.bo[S.detail_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(S.detail_buf, S.ns, 0, -1)
  for _, h in ipairs(highlights or {}) do
    pcall(vim.api.nvim_buf_set_extmark, S.detail_buf, S.ns, h.line, h.col_start, {
      end_col = h.col_end,
      hl_group = h.hl_group,
    })
  end
end

local function render_detail(issue)
  local content = format.ticket_lines(issue)
  if type(content) == "table" and content.lines then
    render_detail_content(content.lines, content.highlights)
    local editor = require("ledger.xray.editor")
    editor.update(S.detail_buf, content.regions or {})
  else
    render_detail_content(content, {})
    require("ledger.xray.editor").update(S.detail_buf, {})
  end
end

local function update_detail()
  if not S.detail_buf or not vim.api.nvim_buf_is_valid(S.detail_buf) then
    return
  end
  if #S.filtered == 0 then
    render_detail_content({ "", "  (no selection)" }, {})
    return
  end
  local issue = S.filtered[S.selected_idx]
  if not issue then
    return
  end
  local key = issue.key

  if S.detail_cache[key] then
    render_detail(S.detail_cache[key])
    return
  end

  render_detail_content({ "", "  Loading " .. key .. "…" }, {})

  cache.fetch(key, function(full_issue, err)
    if err or not full_issue then
      render_detail_content({ "", "  Error: " .. (err or "unknown") }, {})
      return
    end
    S.detail_cache[key] = full_issue
    local current = S.filtered[S.selected_idx]
    if current and current.key == key and not S.closed then
      render_detail(full_issue)
    end
  end)
end

local FIELD_ALIAS = {
  assignee = "assignee",
  owner = "assignee",
  who = "assignee",
  status = "status",
  state = "status",
  type = "issuetype",
  issuetype = "issuetype",
  priority = "priority",
  platform = "platforms",
  platforms = "platforms",
  team = "team",
  automated = "automated",
  automation = "automated",
}

local function resolve_field_alias(name)
  name = name:lower()
  if FIELD_ALIAS[name] then
    return FIELD_ALIAS[name]
  end
  if #name < 3 then
    return nil
  end
  local canon = nil
  for alias, c in pairs(FIELD_ALIAS) do
    if alias:sub(1, #name) == name then
      if canon and canon ~= c then
        return nil
      end
      canon = c
    end
  end
  return canon
end

local function list_values(field, sep)
  sep = sep or " "
  if type(field) ~= "table" then
    return ""
  end
  local bits = {}
  for _, v in ipairs(field) do
    if type(v) == "table" and v.value then
      table.insert(bits, tostring(v.value))
    elseif type(v) == "string" then
      table.insert(bits, v)
    end
  end
  return table.concat(bits, sep)
end

local function field_haystack(issue, canon)
  local f = issue.fields or {}
  if canon == "assignee" then
    local a = f.assignee
    if type(a) ~= "table" then
      return ""
    end
    return ((a.displayName or "") .. " " .. (a.emailAddress or "")):lower()
  elseif canon == "status" then
    return ((type(f.status) == "table" and f.status.name) or ""):lower()
  elseif canon == "issuetype" then
    return ((type(f.issuetype) == "table" and f.issuetype.name) or ""):lower()
  elseif canon == "priority" then
    return ((type(f.priority) == "table" and f.priority.name) or ""):lower()
  elseif canon == "platforms" then
    return list_values(f.customfield_10977):lower()
  elseif canon == "team" then
    local t = f.customfield_10971
    return ((type(t) == "table" and t.value) or ""):lower()
  elseif canon == "automated" then
    return list_values(f.customfield_10975):lower()
  end
  return ""
end

local function parse_query(q)
  local filters = {}
  local rest = {}
  for token in q:gmatch("%S+") do
    local name, val = token:match("^([%w]+):(.+)$")
    local canon = name and resolve_field_alias(name) or nil
    if canon and val then
      table.insert(filters, { canon = canon, needle = val:lower() })
    else
      table.insert(rest, token)
    end
  end
  return filters, table.concat(rest, " "):lower()
end

local function filter_issues(query)
  if not query or query == "" then
    S.filtered = {}
    for _, issue in ipairs(S.all_issues) do
      table.insert(S.filtered, issue)
    end
    return
  end
  local filters, general = parse_query(query)
  local filtered = {}
  for _, issue in ipairs(S.all_issues) do
    local match = true
    for _, ff in ipairs(filters) do
      if not field_haystack(issue, ff.canon):find(ff.needle, 1, true) then
        match = false
        break
      end
    end
    if match and general ~= "" then
      local f = issue.fields or {}
      local status = (type(f.status) == "table" and f.status.name) or ""
      local hay = (issue.key .. " " .. status .. " " .. (f.summary or "")):lower()
      if not hay:find(general, 1, true) then
        match = false
      end
    end
    if match then
      table.insert(filtered, issue)
    end
  end
  S.filtered = filtered
end

local function get_query()
  if not S.prompt_buf or not vim.api.nvim_buf_is_valid(S.prompt_buf) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(S.prompt_buf, 0, 1, false)
  return (lines[1] or ""):gsub("^> ", "")
end

local function on_prompt_changed()
  local query = get_query()
  filter_issues(query)
  if #S.filtered > 0 then
    if S.selected_idx < 1 or S.selected_idx > #S.filtered then
      S.selected_idx = 1
    end
  else
    S.selected_idx = 0
  end
  render_results()
  update_detail()
end

local function move_selection(delta)
  if #S.filtered == 0 then
    return
  end
  S.selected_idx = math.max(1, math.min(#S.filtered, S.selected_idx + delta))
  render_results()
  update_detail()
end

local function focus_detail()
  if not S.detail_win or not vim.api.nvim_win_is_valid(S.detail_win) then
    return
  end
  if #S.filtered == 0 then
    return
  end
  S.focus = "detail"
  vim.api.nvim_set_current_win(S.detail_win)
  vim.cmd("stopinsert")
end

local function focus_prompt_insert()
  if not S.prompt_win or not vim.api.nvim_win_is_valid(S.prompt_win) then
    return
  end
  S.focus = "prompt"
  vim.api.nvim_set_current_win(S.prompt_win)
  vim.cmd("startinsert!")
  local query = get_query()
  pcall(vim.api.nvim_win_set_cursor, S.prompt_win, { 1, #query + 2 })
end

local function selected_issue()
  if #S.filtered == 0 then
    return nil
  end
  return S.filtered[S.selected_idx]
end

local function do_insert_at_cursor()
  local issue = selected_issue()
  if not issue then
    return
  end
  local key = issue.key
  close_all()
  vim.schedule(function()
    insert_mod.smart_insert(key)
  end)
end

local function do_yank()
  local issue = selected_issue()
  if not issue then
    return
  end
  vim.fn.setreg("+", issue.key)
  vim.fn.setreg('"', issue.key)
  vim.notify("xray: yanked " .. issue.key, vim.log.levels.INFO)
end

local function do_browse()
  local issue = selected_issue()
  if not issue then
    return
  end
  util.open_url(util.ticket_url(issue.key))
end

local function do_help()
  require("ledger.xray.help").open("picker")
end

local function scroll_detail(lines)
  if not S.detail_win or not vim.api.nvim_win_is_valid(S.detail_win) then
    return
  end
  local key = lines > 0 and "\x05" or "\x19" -- <C-e> / <C-y>
  pcall(vim.api.nvim_win_call, S.detail_win, function()
    vim.cmd("normal! " .. math.abs(lines) .. key)
  end)
  -- Force a full terminal redraw. Without this, async reload updates that
  -- rewrite the results buffer mid-scroll can leave phantom summary text in
  -- the gap between panels (old wide content clipped but not repainted).
  vim.cmd("redraw!")
end

local function smart_scroll(delta)
  local pos = vim.fn.getmousepos()
  if pos and pos.winid == S.detail_win then
    scroll_detail(delta)
  else
    move_selection(delta)
  end
end

local function handle_mouse_click()
  local pos = vim.fn.getmousepos()
  if not pos or not pos.winid or pos.winid == 0 then
    return
  end

  if pos.winid == S.results_win then
    if pos.line and pos.line >= 1 and pos.line <= #S.filtered then
      S.selected_idx = pos.line
      render_results()
      update_detail()
    end
  elseif pos.winid == S.prompt_win then
    focus_prompt_insert()
  elseif pos.winid == S.detail_win then
    S.focus = "detail"
    vim.api.nvim_set_current_win(S.detail_win)
    vim.cmd("stopinsert")
    pcall(vim.api.nvim_win_set_cursor, S.detail_win, { pos.line > 0 and pos.line or 1, pos.column - 1 })
  end
end

local function setup_prompt_keymaps(buf)
  local o = { buffer = buf, nowait = true, silent = true }
  local down = function()
    move_selection(1)
  end
  local up = function()
    move_selection(-1)
  end

  vim.keymap.set("n", "<Esc>", close_all, o)
  vim.keymap.set("n", "q", close_all, o)
  vim.keymap.set("n", "?", do_help, o)

  vim.keymap.set({ "i", "n" }, "<CR>", focus_detail, o)
  vim.keymap.set({ "i", "n" }, "<Right>", focus_detail, o)

  vim.keymap.set({ "i", "n" }, "<Down>", down, o)
  vim.keymap.set({ "i", "n" }, "<Up>", up, o)
  vim.keymap.set({ "i", "n" }, "<C-n>", down, o)
  vim.keymap.set({ "i", "n" }, "<C-p>", up, o)
  vim.keymap.set("n", "j", down, o)
  vim.keymap.set("n", "k", up, o)

  vim.keymap.set({ "i", "n" }, "<ScrollWheelDown>", function()
    smart_scroll(3)
  end, o)
  vim.keymap.set({ "i", "n" }, "<ScrollWheelUp>", function()
    smart_scroll(-3)
  end, o)

  vim.keymap.set({ "i", "n" }, "<LeftMouse>", handle_mouse_click, o)

  vim.keymap.set({ "i", "n" }, "<C-y>", do_yank, o)
  vim.keymap.set({ "i", "n" }, "<C-o>", do_browse, o)

  vim.keymap.set("n", "i", function()
    focus_prompt_insert()
  end, o)
  vim.keymap.set("n", "a", function()
    focus_prompt_insert()
  end, o)
end

local function setup_detail_keymaps(buf)
  local o = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", close_all, o)
  vim.keymap.set("n", "<Esc>", focus_prompt_insert, o)
  vim.keymap.set("n", "i", do_insert_at_cursor, o)
  vim.keymap.set("n", "y", do_yank, o)
  vim.keymap.set("n", "b", do_browse, o)
  vim.keymap.set("n", "?", do_help, o)
  vim.keymap.set("n", "K", "<Nop>", o)
  vim.keymap.set("n", "<ScrollWheelDown>", function()
    scroll_detail(3)
  end, o)
  vim.keymap.set("n", "<ScrollWheelUp>", function()
    scroll_detail(-3)
  end, o)
  vim.keymap.set("n", "<C-l>", function()
    vim.cmd("redraw!")
  end, o)

  require("ledger.xray.editor").attach(buf, S.detail_win, {}, {
    on_activate = function(r)
      local issue = selected_issue()
      if not issue then
        return
      end
      require("ledger.xray.edit").dispatch(r, {
        key = issue.key,
        on_status_change = function(new_status)
          if S.closed then
            return
          end
          for _, i in ipairs(S.all_issues) do
            if i.key == issue.key then
              i.fields = i.fields or {}
              i.fields.status = i.fields.status or {}
              i.fields.status.name = new_status
              break
            end
          end
          render_results()
        end,
        on_refresh = function()
          if S.closed then
            return
          end
          S.detail_cache[issue.key] = nil
          update_detail()
        end,
      })
    end,
  })
end

local function setup_results_keymaps(buf)
  local o = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<LeftMouse>", handle_mouse_click, o)
  vim.keymap.set("n", "<ScrollWheelDown>", function()
    smart_scroll(3)
  end, o)
  vim.keymap.set("n", "<ScrollWheelUp>", function()
    smart_scroll(-3)
  end, o)
  vim.keymap.set("n", "q", close_all, o)
  vim.keymap.set("n", "<Esc>", close_all, o)
end

local function update_title(loaded, done, truncated)
  if not S.prompt_win or not vim.api.nvim_win_is_valid(S.prompt_win) then
    return
  end
  local state_str = done and "loaded" or "loading…"
  local marker = done and (icons.status("Done") .. " ") or (icons.ACTION.search .. " ")
  local title =
    string.format(" %s Xray B2CQA — %d %s%s ", marker, loaded, state_str, truncated and " (truncated)" or "")
  local title_hl = done and "XrayTitleLoaded" or "XrayTitleLoading"
  local border_hl = done and "XrayBorderLoaded" or "XrayBorderLoading"
  local cfg = vim.api.nvim_win_get_config(S.prompt_win)
  cfg.title = { { title, title_hl } }
  pcall(vim.api.nvim_win_set_config, S.prompt_win, cfg)
  pcall(function()
    vim.wo[S.prompt_win].winhighlight =
      string.format("FloatTitle:%s,FloatBorder:%s,NormalFloat:XrayNormal", title_hl, border_hl)
  end)
end

local function create_windows()
  local total_w = vim.o.columns
  local total_h = vim.o.lines

  local right_w = math.min(80, math.floor(total_w * 0.40))
  local left_w = math.min(95, math.floor(total_w * 0.48))
  local GAP = 3 -- results right border + 1 cell + detail left border
  local w = left_w + right_w + GAP

  local h_outer = math.floor(total_h * 0.85)
  local row = math.floor((total_h - h_outer) / 2) - 1
  local col = math.floor((total_w - w) / 2)

  local detail_h = h_outer
  local prompt_h = 1
  local results_h = detail_h - prompt_h - 2

  S.results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[S.results_buf].buftype = "nofile"
  vim.bo[S.results_buf].bufhidden = "wipe"
  vim.bo[S.results_buf].filetype = "xray"
  util.disable_completion(S.results_buf)

  S.results_win = vim.api.nvim_open_win(S.results_buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = left_w,
    height = results_h,
    style = "minimal",
    border = "rounded",
    title = " Search results ",
    title_pos = "left",
    focusable = true,
    zindex = 50,
  })
  util.clean_float_window(S.results_win)

  S.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[S.prompt_buf].buftype = "nofile"
  vim.bo[S.prompt_buf].bufhidden = "wipe"
  util.disable_completion(S.prompt_buf)
  vim.api.nvim_buf_set_lines(S.prompt_buf, 0, -1, false, { "> " })

  S.prompt_win = vim.api.nvim_open_win(S.prompt_buf, true, {
    relative = "editor",
    row = row + results_h + 2,
    col = col,
    width = left_w,
    height = prompt_h,
    style = "minimal",
    border = "rounded",
    title = " Xray B2CQA — loading… ",
    title_pos = "left",
    footer = " filter: status:/assignee:/priority:/platforms:/team:/type:   ?=help ",
    footer_pos = "right",
    zindex = 50,
  })
  util.clean_float_window(S.prompt_win)

  S.detail_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[S.detail_buf].buftype = "nofile"
  vim.bo[S.detail_buf].bufhidden = "wipe"
  vim.bo[S.detail_buf].filetype = "xray"
  util.disable_completion(S.detail_buf)

  S.detail_win = vim.api.nvim_open_win(S.detail_buf, false, {
    relative = "editor",
    row = row,
    col = col + left_w + GAP,
    width = right_w,
    height = detail_h,
    style = "minimal",
    border = "rounded",
    title = " Ticket detail ",
    title_pos = "left",
    zindex = 50,
  })
  util.clean_float_window(S.detail_win)

  setup_prompt_keymaps(S.prompt_buf)
  setup_results_keymaps(S.results_buf)
  setup_detail_keymaps(S.detail_buf)

  table.insert(
    S.autocmds,
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = S.prompt_buf,
      callback = function()
        local line = vim.api.nvim_buf_get_lines(S.prompt_buf, 0, 1, false)[1] or ""
        if not line:match("^> ") then
          vim.api.nvim_buf_set_lines(S.prompt_buf, 0, 1, false, { "> " .. line })
          pcall(vim.api.nvim_win_set_cursor, S.prompt_win, { 1, #line + 2 })
        end
        on_prompt_changed()
      end,
    })
  )

  table.insert(
    S.autocmds,
    vim.api.nvim_create_autocmd("WinClosed", {
      callback = function(args)
        local win = tonumber(args.match)
        if win == S.prompt_win or win == S.results_win or win == S.detail_win then
          vim.schedule(close_all)
        end
      end,
    })
  )
end

local function list_cache_fresh()
  return list_cache.issues and #list_cache.issues > 0 and (os.time() - list_cache.at) < LIST_CACHE_TTL
end

local function start_prefetch()
  if list_cache.state == "loading" then
    return
  end
  if list_cache.state == "done" and list_cache_fresh() then
    return
  end
  local creds = select(1, config.credentials())
  if not creds then
    return
  end

  list_cache.state = "loading"
  list_cache.issues = {}
  list_cache.at = os.time()
  list_cache.truncated = false

  local jql = api_jira.build_jql(config.options.project_key, "")
  local search_fields = table.concat({
    "summary",
    "status",
    "issuetype",
    "assignee",
    "priority",
    "customfield_10977",
    "customfield_10975",
    "customfield_10971",
    "customfield_10976",
  }, ",")
  api_jira.search_all(jql, {
    page_cap = 50,
    max_results = 100,
    fields = search_fields,
  }, function(issues, _)
    for _, i in ipairs(issues) do
      table.insert(list_cache.issues, i)
    end
    list_cache.at = os.time()
    cache_notify(issues, false, nil)
  end, function(err, meta)
    list_cache.state = "done"
    list_cache.truncated = meta and meta.truncated or false
    cache_notify({}, true, err)
  end)
end

local function start_fetch(force)
  global_fetch_session = global_fetch_session + 1
  local session = global_fetch_session
  S.fetch_session = session
  S.fetch_done = false
  S.all_issues = {}

  if force then
    list_cache.issues = nil
    list_cache.state = "idle"
    list_cache.subscribers = {}
  end

  if list_cache.issues and #list_cache.issues > 0 then
    for _, i in ipairs(list_cache.issues) do
      table.insert(S.all_issues, i)
    end
  end

  local is_done = list_cache.state == "done" and list_cache_fresh()
  on_prompt_changed()
  update_title(#S.all_issues, is_done, list_cache.truncated)
  if is_done then
    S.fetch_done = true
    return
  end

  if list_cache.state ~= "loading" then
    start_prefetch()
  end

  table.insert(list_cache.subscribers, function(new_issues, done, err)
    if session ~= global_fetch_session or S.closed then
      return
    end
    if err then
      vim.notify(err, vim.log.levels.WARN)
      return
    end
    for _, i in ipairs(new_issues) do
      table.insert(S.all_issues, i)
    end
    on_prompt_changed()
    update_title(#S.all_issues, done, list_cache.truncated)
    if done then
      S.fetch_done = true
    end
  end)
end

function M.open()
  if S.prompt_win and vim.api.nvim_win_is_valid(S.prompt_win) then
    vim.api.nvim_set_current_win(S.prompt_win)
    return
  end

  reset_state()
  S.ns = vim.api.nvim_create_namespace("xray_picker")

  create_windows()
  pcall(vim.api.nvim_win_set_cursor, S.prompt_win, { 1, 2 })
  vim.cmd("startinsert!")

  start_fetch(false)
end

function M.prefetch_list()
  start_prefetch()
end

function M.refresh()
  list_cache.issues = nil
  list_cache.at = 0
  list_cache.state = "idle"
  list_cache.subscribers = {}
  if S.prompt_win and vim.api.nvim_win_is_valid(S.prompt_win) then
    start_fetch(true)
  end
end

function M.close()
  close_all()
end

return M
