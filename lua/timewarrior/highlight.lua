-- Highlighting for the timewarrior today buffer.
--
-- All highlights are applied as extmarks so that everything lives in one
-- namespace and a single nvim_buf_clear_namespace() wipes the slate clean on
-- each refresh.
--
-- Responsibilities:
--   * Comment lines (^#)            → Comment highlight group.
--   * Time-range prefix (HH:MM-…)   → Number highlight group.
--   * Known tags                    → Keyword highlight group.
--   * Unknown / misspelled tags     → vim.diagnostic WARN.
--   * Invalid timestamp fields      → vim.diagnostic ERROR.
--
-- Usage:
--   local hl = require("timewarrior.highlight")
--   hl.update(bufnr, known_tags)   -- call on open and on TextChanged

local M = {}

local ns = vim.api.nvim_create_namespace("timewarrior")

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

local function mark(bufnr, lnum, col, end_col, hl_group)
  vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, col, {
    end_col = end_col,
    hl_group = hl_group,
    priority = 110,
  })
end

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
---@param bufnr      integer   Buffer handle.
---@param known_tags string[]  All tags known to timewarrior (from collect_tags()).
function M.update(bufnr, known_tags)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local known_set = {}
  for _, tag in ipairs(known_tags or {}) do
    known_set[tag] = true
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local diags = {}

  for lnum0, line in ipairs(lines) do
    local lnum = lnum0 - 1

    if line:match("^%s*#") then
      -- Comment line → Comment colour for the whole line.
      mark(bufnr, lnum, 0, #line, "Comment")

    elseif not line:match("^%s*$") then
      -- Entry line.
      local parsed = parse_line(line)

      if not parsed then
        err(diags, bufnr, lnum, 0, #line,
          "Invalid format. Expected: HH:MM-HH:MM tags  or  HH:MM- tags")
      else
        -- Time-range prefix → Number colour.
        mark(bufnr, lnum, 0, parsed.time_end_col, "Number")

        local sh_n = tonumber(parsed.sh)
        local sm_n = tonumber(parsed.sm)

        if sh_n > 23 then
          err(diags, bufnr, lnum, 0, 2,
            "Invalid start hour " .. parsed.sh .. " (must be 00-23)")
        end
        if sm_n > 59 then
          err(diags, bufnr, lnum, 3, 5,
            "Invalid start minute " .. parsed.sm .. " (must be 00-59)")
        end

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

        -- Tags after the time range.
        -- Use find-in-loop so that any number of spaces/tabs between tags
        -- maps to the correct byte column rather than assuming one separator.
        local tags_str = parsed.tags_str or ""
        local base_col = parsed.time_end_col
        local pos = 1
        while pos <= #tags_str do
          local tok_s, tok_e = tags_str:find("%S+", pos)
          if not tok_s then break end
          local tag = tags_str:sub(tok_s, tok_e)
          local col     = base_col + tok_s - 1
          local tag_end = base_col + tok_e
          if known_set[tag] then
            mark(bufnr, lnum, col, tag_end, "Keyword")
          else
            warn(diags, bufnr, lnum, col, tag_end,
              "Unknown tag '" .. tag .. "'")
          end
          pos = tok_e + 1
        end
      end
    end
  end

  vim.diagnostic.set(ns, bufnr, diags)
end

return M
