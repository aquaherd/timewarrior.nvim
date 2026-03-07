-- Dynamic highlighting for the timewarrior today buffer.
--
-- Responsibilities:
--   * Validate timestamps on each entry line and report errors via vim.diagnostic.
--   * Highlight known tags (from timewarrior history) as keywords.
--   * Report unknown / possibly-misspelled tags as diagnostic warnings.
--
-- Usage:
--   local hl = require("timewarrior.highlight")
--   hl.update(bufnr, known_tags)   -- call on open and on TextChanged

local M = {}

-- Single namespace used for both extmark highlights and diagnostics so that
-- a single nvim_buf_clear_namespace() wipes everything on each refresh.
local ns = vim.api.nvim_create_namespace("timewarrior")

-- Returns the namespace id so callers can reference it if needed (e.g. tests).
function M.ns()
  return ns
end

---Parse the time-range prefix of an entry line.
---@param line string
---@return table|nil  { sh, sm, eh, em, tags_str, time_end_col }
local function parse_line(line)
  -- Closed interval: HH:MM-HH:MM<rest>
  local sh, sm, eh, em, rest = line:match("^(%d%d):(%d%d)%-(%d%d):(%d%d)(.*)")
  if sh then
    return { sh = sh, sm = sm, eh = eh, em = em, tags_str = rest, time_end_col = 11 }
  end

  -- Open interval: HH:MM-<rest>
  sh, sm, rest = line:match("^(%d%d):(%d%d)%-(.*)")
  if sh then
    return { sh = sh, sm = sm, eh = nil, em = nil, tags_str = rest, time_end_col = 6 }
  end

  return nil
end

---Add a diagnostic error table to the list.
local function err(diags, bufnr, lnum, col, end_col, msg)
  table.insert(diags, {
    bufnr = bufnr,
    lnum = lnum,
    col = col,
    end_col = end_col,
    severity = vim.diagnostic.severity.ERROR,
    source = "timewarrior",
    message = msg,
  })
end

---Add a diagnostic warning table to the list.
local function warn(diags, bufnr, lnum, col, end_col, msg)
  table.insert(diags, {
    bufnr = bufnr,
    lnum = lnum,
    col = col,
    end_col = end_col,
    severity = vim.diagnostic.severity.WARN,
    source = "timewarrior",
    message = msg,
  })
end

---Update highlights and diagnostics for the given buffer.
---@param bufnr   integer  Buffer handle.
---@param known_tags string[]  All tags known to timewarrior (from collect_tags()).
function M.update(bufnr, known_tags)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Build an O(1) lookup set from the known tags list.
  local known_set = {}
  for _, tag in ipairs(known_tags or {}) do
    known_set[tag] = true
  end

  -- Clear previous extmark highlights and diagnostics in one call.
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local diags = {}

  for lnum0, line in ipairs(lines) do
    local lnum = lnum0 - 1 -- convert to 0-based

    -- Skip blank lines and comment lines; the syntax file handles their colour.
    if line:match("^%s*$") or line:match("^%s*#") then
      -- nothing to do
    else
      local parsed = parse_line(line)

      if not parsed then
        -- The whole line is malformed.
        err(diags, bufnr, lnum, 0, #line,
          "Invalid format. Expected: HH:MM-HH:MM tags  or  HH:MM- tags")
      else
        local sh_n = tonumber(parsed.sh)
        local sm_n = tonumber(parsed.sm)

        -- Validate start hour.
        if sh_n > 23 then
          err(diags, bufnr, lnum, 0, 2,
            "Invalid start hour " .. parsed.sh .. " (must be 00-23)")
        end

        -- Validate start minute.
        if sm_n > 59 then
          err(diags, bufnr, lnum, 3, 5,
            "Invalid start minute " .. parsed.sm .. " (must be 00-59)")
        end

        -- Validate end time when present.
        if parsed.eh then
          local eh_n = tonumber(parsed.eh)
          local em_n = tonumber(parsed.em)

          if eh_n > 23 then
            err(diags, bufnr, lnum, 6, 8,
              "Invalid end hour " .. parsed.eh .. " (must be 00-23)")
          end

          if em_n > 59 then
            err(diags, bufnr, lnum, 9, 11,
              "Invalid end minute " .. parsed.em .. " (must be 00-59)")
          end
        end

        -- Highlight tags that follow the time range.
        local tags_str = parsed.tags_str or ""
        local col = parsed.time_end_col

        -- Consume leading whitespace between the time range and the first tag.
        local ws = tags_str:match("^(%s+)")
        if ws then
          col = col + #ws
          tags_str = tags_str:sub(#ws + 1)
        end

        for tag in tags_str:gmatch("%S+") do
          local tag_end = col + #tag
          if known_set[tag] then
            -- Known tag → keyword highlight via extmark.
            vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, col, {
              end_col = tag_end,
              hl_group = "Keyword",
              priority = 110, -- above default treesitter/syntax priority
            })
          else
            -- Unknown or misspelled tag → diagnostic warning.
            warn(diags, bufnr, lnum, col, tag_end,
              "Unknown tag '" .. tag .. "'")
          end
          col = tag_end + 1 -- +1 for the space separator
        end
      end
    end
  end

  vim.diagnostic.set(ns, bufnr, diags)
end

return M
