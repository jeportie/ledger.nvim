local M = {}

local api = vim.api
local color = require("volt.color")

local function to_hex(n)
  if type(n) == "string" then
    return n
  end
  if type(n) ~= "number" then
    return nil
  end
  return string.format("#%06x", n)
end

local function get(name)
  local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  if not ok then
    return {}
  end
  return hl or {}
end

local function hex_or(name, key, fallback)
  local h = get(name)
  return to_hex(h[key]) or fallback
end

-- Safe mix: volt.color.mix returns the first color if hex parse fails. Guard both.
local function mix(a, b, s)
  if not a or not b then
    return a or b or "#808080"
  end
  return color.mix(a, b, s)
end

local function lighten(hex, pct)
  if not hex then
    return nil
  end
  return color.change_hex_lightness(hex, pct)
end

function M.define(ns)
  local normal_bg = hex_or("Normal", "bg", "#1e1e2e")
  local normal_fg = hex_or("Normal", "fg", "#cdd6f4")
  local com_fg = hex_or("Comment", "fg", "#7f849c")
  local err_fg = hex_or("DiagnosticError", "fg", "#f38ba8")
  local warn_fg = hex_or("DiagnosticWarn", "fg", "#f9e2af")
  local info_fg = hex_or("DiagnosticInfo", "fg", "#89b4fa")
  local ok_fg = hex_or("DiagnosticOk", "fg", "#a6e3a1")
  local spec_fg = hex_or("Special", "fg", info_fg)
  local type_fg = hex_or("Type", "fg", info_fg)

  local dark = vim.o.background == "dark"
  local dir = dark and 1 or -1

  local board_bg = lighten(normal_bg, 2 * dir) or normal_bg
  local col_bg = lighten(normal_bg, 1 * dir) or normal_bg
  local card_bg = lighten(board_bg, 6 * dir) or board_bg
  local card_sel_bg = lighten(card_bg, 5 * dir) or card_bg
  local card_rule = lighten(board_bg, 8 * dir) or com_fg

  api.nvim_set_hl(ns, "JiraBoardNormal", { bg = board_bg, fg = normal_fg })
  api.nvim_set_hl(ns, "JiraBoardBorder", { bg = board_bg, fg = mix(spec_fg, board_bg, 40) })
  api.nvim_set_hl(ns, "JiraBoardTitle", { bg = board_bg, fg = spec_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardMuted", { bg = board_bg, fg = com_fg })

  api.nvim_set_hl(ns, "JiraBoardColHdr", { bg = col_bg, fg = spec_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardColCount", { bg = col_bg, fg = com_fg })
  api.nvim_set_hl(ns, "JiraBoardColRule", { bg = board_bg, fg = card_rule })
  api.nvim_set_hl(ns, "JiraBoardColGap", { bg = board_bg })

  -- Epic band (subtle delimiter)
  local epic_bg = lighten(board_bg, 3 * dir) or board_bg
  api.nvim_set_hl(ns, "JiraBoardEpicHdr", { bg = epic_bg, fg = normal_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardEpicSum", { bg = epic_bg, fg = com_fg })

  api.nvim_set_hl(ns, "JiraBoardCard", { bg = card_bg, fg = normal_fg })
  api.nvim_set_hl(ns, "JiraBoardCardKey", { bg = card_bg, fg = spec_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardCardSum", { bg = card_bg, fg = normal_fg })
  api.nvim_set_hl(ns, "JiraBoardCardMuted", { bg = card_bg, fg = com_fg })
  api.nvim_set_hl(ns, "JiraBoardCardInit", { bg = card_bg, fg = info_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardCardSel", { bg = card_sel_bg, fg = normal_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardCardSelKey", { bg = card_sel_bg, fg = spec_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardCardSelMuted", { bg = card_sel_bg, fg = com_fg })

  -- Priority chips
  api.nvim_set_hl(ns, "JiraBoardPriHigh", { bg = mix(err_fg, card_bg, 38), fg = err_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardPriMed", { bg = mix(warn_fg, card_bg, 32), fg = warn_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardPriLow", { bg = mix(info_fg, card_bg, 32), fg = info_fg, bold = true })

  -- Status chips
  api.nvim_set_hl(ns, "JiraBoardStTodo", { bg = mix(com_fg, card_bg, 36), fg = normal_fg })
  api.nvim_set_hl(ns, "JiraBoardStProg", { bg = mix(warn_fg, card_bg, 50), fg = warn_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardStReview", { bg = mix(info_fg, card_bg, 50), fg = info_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardStDone", { bg = mix(ok_fg, card_bg, 50), fg = ok_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardStBlock", { bg = mix(err_fg, card_bg, 45), fg = err_fg, bold = true })

  -- Footer / keymap chips
  api.nvim_set_hl(ns, "JiraBoardFooter", { bg = board_bg, fg = com_fg })
  api.nvim_set_hl(ns, "JiraBoardKeyChip", { bg = board_bg, fg = normal_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardKeyDesc", { bg = board_bg, fg = com_fg })
  api.nvim_set_hl(ns, "JiraBoardFilterOn", { bg = mix(warn_fg, board_bg, 40), fg = warn_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardFilterOff", { bg = mix(com_fg, board_bg, 30), fg = com_fg })

  -- Close cross (clickable in header)
  api.nvim_set_hl(ns, "JiraBoardClose", { bg = mix(err_fg, board_bg, 25), fg = err_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardCloseHov", { bg = err_fg, fg = normal_bg, bold = true })

  -- Tabs (for future: Summary/Kanban/Backlog)
  api.nvim_set_hl(ns, "JiraBoardTabActive", { bg = mix(spec_fg, board_bg, 30), fg = spec_fg, bold = true })
  api.nvim_set_hl(ns, "JiraBoardTabInactive", { bg = board_bg, fg = com_fg })

  -- Preview focus highlight (row currently focused by Tab/j/k navigation).
  local focus_bg = mix(spec_fg, board_bg, 22)
  api.nvim_set_hl(ns, "JiraBoardFocus", { bg = focus_bg, bold = true })

  -- Also register the core groups globally so floating pickers (status,
  -- assignee, comment, filter) can reuse the same background through their
  -- `winhighlight` without needing our per-window namespace.
  api.nvim_set_hl(0, "JiraBoardNormal", { bg = board_bg, fg = normal_fg })
  api.nvim_set_hl(0, "JiraBoardBorder", { bg = board_bg, fg = mix(spec_fg, board_bg, 40) })
  api.nvim_set_hl(0, "JiraBoardTitle", { bg = board_bg, fg = spec_fg, bold = true })
  api.nvim_set_hl(0, "JiraBoardMuted", { bg = board_bg, fg = com_fg })
  api.nvim_set_hl(0, "JiraBoardFilterOn", { bg = mix(warn_fg, board_bg, 40), fg = warn_fg, bold = true })
  api.nvim_set_hl(0, "JiraBoardFilterOff", { bg = mix(com_fg, board_bg, 30), fg = com_fg })
  api.nvim_set_hl(0, "JiraBoardClose", { bg = mix(err_fg, board_bg, 25), fg = err_fg, bold = true })
  api.nvim_set_hl(0, "JiraBoardFooter", { bg = board_bg, fg = com_fg })
  api.nvim_set_hl(0, "JiraBoardSel", { bg = card_sel_bg, fg = normal_fg, bold = true })
  -- Winbar defaults to StatusLine; force it to the board background so our
  -- winbar-based sticky header reads as part of the board, not the theme.
  api.nvim_set_hl(0, "JiraBoardWinBar", { bg = board_bg, fg = normal_fg })
  -- Bend the shared Xray picker theme to the board's palette so every popup
  -- (status, assignee, filter, comment) renders on the kanban background.
  api.nvim_set_hl(0, "XrayNormal", { link = "JiraBoardNormal" })
  api.nvim_set_hl(0, "XrayBorder", { link = "JiraBoardBorder" })
  api.nvim_set_hl(0, "XrayTitleFloat", { link = "JiraBoardTitle" })
  api.nvim_set_hl(0, "XrayFooter", { link = "JiraBoardFooter" })
  api.nvim_set_hl(0, "XraySelected", { link = "JiraBoardSel" })

  return { board_bg = board_bg, card_bg = card_bg, col_bg = col_bg }
end

-- Status name → highlight group resolver.
function M.status_hl(name)
  if not name then
    return "JiraBoardStTodo"
  end
  local n = name:lower()
  if n:find("progress") or n:find("doing") then
    return "JiraBoardStProg"
  end
  if n:find("review") or n:find("code review") then
    return "JiraBoardStReview"
  end
  if n:find("done") or n:find("closed") or n:find("resolved") then
    return "JiraBoardStDone"
  end
  if n:find("block") then
    return "JiraBoardStBlock"
  end
  return "JiraBoardStTodo"
end

function M.priority_hl(name)
  if not name then
    return "JiraBoardCardMuted"
  end
  if name == "Highest" or name == "High" then
    return "JiraBoardPriHigh"
  end
  if name == "Medium" then
    return "JiraBoardPriMed"
  end
  if name == "Low" or name == "Lowest" then
    return "JiraBoardPriLow"
  end
  return "JiraBoardCardMuted"
end

return M
