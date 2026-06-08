local M = {}

local function text_of(node)
  if type(node) ~= "table" then
    return ""
  end
  local t = node.type
  if t == "text" then
    return node.text or ""
  elseif t == "hardBreak" then
    return "\n"
  elseif t == "mention" then
    local attrs = node.attrs or {}
    return attrs.text or ("@" .. (attrs.displayName or attrs.id or "?"))
  elseif t == "emoji" then
    local attrs = node.attrs or {}
    return attrs.text or attrs.shortName or ""
  elseif t == "inlineCard" or t == "blockCard" then
    local attrs = node.attrs or {}
    return attrs.url or ""
  end
  local out = {}
  if type(node.content) == "table" then
    for _, child in ipairs(node.content) do
      table.insert(out, text_of(child))
    end
  end
  return table.concat(out)
end

local function walk(node, lines, depth)
  if type(node) ~= "table" then
    return
  end
  depth = depth or 0
  local t = node.type

  if t == "paragraph" then
    local s = text_of(node)
    if s ~= "" then
      for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
      end
    else
      table.insert(lines, "")
    end
    return
  end

  if t == "heading" then
    local level = (node.attrs and node.attrs.level) or 1
    local prefix = string.rep("#", level) .. " "
    table.insert(lines, prefix .. text_of(node))
    return
  end

  if t == "bulletList" or t == "orderedList" then
    if type(node.content) == "table" then
      for i, item in ipairs(node.content) do
        local marker = t == "orderedList" and (i .. ". ") or "• "
        if type(item.content) == "table" then
          for j, child in ipairs(item.content) do
            if j == 1 then
              local s = text_of(child)
              table.insert(lines, string.rep("  ", depth) .. marker .. s)
            else
              walk(child, lines, depth + 1)
            end
          end
        end
      end
    end
    return
  end

  if t == "codeBlock" then
    table.insert(lines, "```")
    local s = text_of(node)
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
    table.insert(lines, "```")
    return
  end

  if t == "blockquote" then
    local before = #lines
    if type(node.content) == "table" then
      for _, child in ipairs(node.content) do
        walk(child, lines, depth)
      end
    end
    for i = before + 1, #lines do
      lines[i] = "> " .. lines[i]
    end
    return
  end

  if t == "rule" then
    table.insert(lines, "———")
    return
  end

  if t == "table" then
    if type(node.content) == "table" then
      local row_lines = {}
      for _, tr in ipairs(node.content) do
        if tr.type == "tableRow" and type(tr.content) == "table" then
          local cells = {}
          for _, cell in ipairs(tr.content) do
            local txt = text_of(cell):gsub("\r", ""):gsub("\n", " ")
            txt = txt:gsub("^%s+", ""):gsub("%s+$", "")
            table.insert(cells, txt)
          end
          if #cells > 0 then
            table.insert(row_lines, "| " .. table.concat(cells, " | ") .. " |")
          end
        end
      end
      if #row_lines > 0 then
        table.insert(lines, row_lines[1])
        -- Markdown-style separator after the header row.
        local n_cells = 0
        for _ in row_lines[1]:gmatch("|[^|]+") do
          n_cells = n_cells + 1
        end
        local sep = {}
        for _ = 1, n_cells do
          table.insert(sep, "---")
        end
        table.insert(lines, "| " .. table.concat(sep, " | ") .. " |")
        for i = 2, #row_lines do
          table.insert(lines, row_lines[i])
        end
      end
    end
    return
  end

  if t == "media" or t == "mediaGroup" or t == "mediaSingle" then
    table.insert(lines, "[media]")
    return
  end

  if type(node.content) == "table" then
    for _, child in ipairs(node.content) do
      walk(child, lines, depth)
    end
  end
end

function M.to_lines(doc, max_lines)
  if type(doc) ~= "table" or doc.type ~= "doc" then
    return {}
  end
  local lines = {}
  walk(doc, lines, 0)
  -- Collapse consecutive empty lines
  local out = {}
  local last_empty = false
  for _, l in ipairs(lines) do
    local empty = l == ""
    if not (empty and last_empty) then
      table.insert(out, l)
    end
    last_empty = empty
  end
  while #out > 0 and out[#out] == "" do
    table.remove(out)
  end
  if max_lines and #out > max_lines then
    local trimmed = {}
    for i = 1, max_lines do
      trimmed[i] = out[i]
    end
    table.insert(trimmed, "… (" .. (#out - max_lines) .. " more lines)")
    return trimmed
  end
  return out
end

return M
