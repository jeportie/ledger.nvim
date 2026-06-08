local M = {}

local function nf(cp)
  return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local STATUS_CP = {
  ["Automated"] = 0xF058,
  ["Automation Required"] = 0xF252,
  ["Manual Test"] = 0xF0C3,
  ["Done"] = 0xF058,
  ["In Progress"] = 0xF252,
  ["To Do"] = 0xF10C,
  ["Closed"] = 0xF00C,
  ["Open"] = 0xF10C,
  ["Blocked"] = 0xF057,
  ["Ready"] = 0xF10C,
  ["Reviewing"] = 0xF06E,
}

local PRIORITY_CP = {
  Highest = 0xF176,
  High = 0xF077,
  Medium = 0xF068,
  Low = 0xF078,
  Lowest = 0xF175,
}

local PLATFORM_CP = {
  Win = 0xF17A,
  Windows = 0xF17A,
  Mac = 0xF179,
  MacOS = 0xF179,
  Linux = 0xF17C,
  Droid = 0xF17B,
  Android = 0xF17B,
  iOS = 0xF179,
}

M.STATUS = {}
M.PRIORITY = {}
M.PLATFORM = {}

for k, v in pairs(STATUS_CP) do
  M.STATUS[k] = nf(v)
end
for k, v in pairs(PRIORITY_CP) do
  M.PRIORITY[k] = nf(v)
end
for k, v in pairs(PLATFORM_CP) do
  M.PLATFORM[k] = nf(v)
end

M.FALLBACK_STATUS = nf(0xF059)

M.LABEL = {
  ticket = nf(0xF02B),
  status = nf(0xF024),
  automation = nf(0xF013),
  platforms = nf(0xF109),
  automated_on = nf(0xF058),
  team = nf(0xF0C0),
  priority = nf(0xF071),
  assignee = nf(0xF007),
  reporter = nf(0xF075),
  type = nf(0xF02D),
  labels = nf(0xF02C),
  updated = nf(0xF017),
  summary = nf(0xF040),
}

M.COVERAGE = {
  desktop = nf(0xF109),
  mobile = nf(0xF10B),
  other = nf(0xF07B),
  both = nf(0xF058),
  none = nf(0xF057),
}

M.VERDICT = {
  ["Both (desktop + mobile)"] = nf(0xF058),
  ["Desktop-only"] = nf(0xF109),
  ["Mobile-only"] = nf(0xF10B),
  ["Other only"] = nf(0xF07B),
  ["No references"] = nf(0xF057),
}

M.ACTION = {
  browser = nf(0xF08E),
  yank = nf(0xF0C5),
  close = nf(0xF057),
  insert = nf(0xF044),
  jump = nf(0xF061),
  preview = nf(0xF06E),
  search = nf(0xF002),
}

M.CHIP = nf(0xF02B)
M.SECTION = nf(0xF141)

function M.status(name)
  return M.STATUS[name] or M.FALLBACK_STATUS
end

function M.priority(name)
  return M.PRIORITY[name] or ""
end

function M.platform(name)
  return M.PLATFORM[name] or ""
end

function M.devicon(path)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return ""
  end
  local name = vim.fn.fnamemodify(path, ":t")
  local ext = vim.fn.fnamemodify(path, ":e")
  local icon = devicons.get_icon(name, ext, { default = true })
  return icon or ""
end

return M
