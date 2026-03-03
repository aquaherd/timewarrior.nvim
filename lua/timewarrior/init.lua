local M = {}

local function split_words(s)
  local out = {}
  for w in (s or ""):gmatch("%S+") do
    table.insert(out, w)
  end
  return out
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Run timew with args (list). Captures stdout+stderr.
-- Returns { out = string, ok = bool }.
local function timew_run(args)
  local parts = { "timew" }
  for _, a in ipairs(args) do
    table.insert(parts, vim.fn.shellescape(a))
  end
  local out = vim.fn.system(table.concat(parts, " ") .. " 2>&1")
  return { out = trim(out), ok = vim.v.shell_error == 0 }
end

-- Run `timew export [filter_args]`, return list of interval tables.
-- Each interval: { id, start_ts, end_ts?, tags[] }
local function timew_export(filter_args)
  local args = { "export" }
  vim.list_extend(args, filter_args or {})
  local result = timew_run(args)
  if not result.ok then
    return {}
  end
  local ok, data = pcall(vim.json.decode, result.out)
  if not ok or type(data) ~= "table" then
    return {}
  end
  local intervals = {}
  for _, item in ipairs(data) do
    table.insert(intervals, {
      id = item.id,
      start_ts = item.start,
      end_ts = item["end"],
      tags = item.tags or {},
    })
  end
  return intervals
end

local function tw_timestamp(epoch)
  return os.date("!%Y%m%dT%H%M%SZ", epoch)
end

local function parse_tw_timestamp(ts)
  local y, m, d, hh, mm, ss = ts:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z$")
  if not y then
    return nil
  end
  local year = tonumber(y)
  local month = tonumber(m)
  local day = tonumber(d)
  local hour = tonumber(hh)
  local min = tonumber(mm)
  local sec = tonumber(ss)

  local adjusted_year = year
  if month <= 2 then
    adjusted_year = adjusted_year - 1
  end

  local era = math.floor(adjusted_year / 400)
  local year_of_era = adjusted_year - era * 400
  local month_prime = month + (month > 2 and -3 or 9)
  local day_of_year = math.floor((153 * month_prime + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
  local days_since_epoch = era * 146097 + day_of_era - 719468

  return days_since_epoch * 86400 + hour * 3600 + min * 60 + sec
end

local function local_day_window(epoch)
  local t = os.date("*t", epoch or os.time())
  t.hour = 0
  t.min = 0
  t.sec = 0
  t.isdst = nil

  local start_epoch = os.time(t)
  local end_epoch = os.time({
    year = t.year,
    month = t.month,
    day = t.day + 1,
    hour = 0,
    min = 0,
    sec = 0,
    isdst = nil,
  })

  return {
    year = t.year,
    month = t.month,
    day = t.day,
    start_epoch = start_epoch,
    end_epoch = end_epoch,
  }
end

local function ts_is_in_local_day(start_ts, day)
  local start_epoch = parse_tw_timestamp(start_ts)
  return start_epoch and start_epoch >= day.start_epoch and start_epoch < day.end_epoch
end

local function collect_tags()
  local intervals = timew_export({})
  local seen = {}
  local tags = {}
  for _, interval in ipairs(intervals) do
    for _, tag in ipairs(interval.tags) do
      if not seen[tag] then
        seen[tag] = true
        table.insert(tags, tag)
      end
    end
  end
  table.sort(tags)
  return tags
end

local _activity_cache = { value = "", expires = 0 }

function M.start(tags)
  tags = tags or {}
  local args = { "start" }
  vim.list_extend(args, tags)
  local result = timew_run(args)
  if result.ok then
    local label = #tags > 0 and (" " .. table.concat(tags, " ")) or ""
    vim.notify("timewarrior: started" .. label, vim.log.levels.INFO)
  else
    vim.notify("timewarrior: " .. result.out, vim.log.levels.ERROR)
  end
  _activity_cache.expires = 0
end

function M.stop()
  local result = timew_run({ "stop" })
  if result.ok then
    vim.notify("timewarrior: stopped", vim.log.levels.INFO)
  else
    vim.notify("timewarrior: " .. result.out, vim.log.levels.ERROR)
  end
  _activity_cache.expires = 0
end

function M.current_activity()
  local now = os.time()
  if now < _activity_cache.expires then
    return _activity_cache.value
  end

  local intervals = timew_export({ ":active" })
  local result
  if not intervals or #intervals == 0 then
    result = "No activity"
  else
    local interval = intervals[1]
    local start_epoch = interval.start_ts and parse_tw_timestamp(interval.start_ts)
    local start_str = start_epoch and os.date("%H:%M", start_epoch) or "?"
    local tags = interval.tags or {}
    local label = #tags > 0 and table.concat(tags, " ") or "active"
    result = " " .. start_str .. " " .. label
  end

  _activity_cache.value = result
  _activity_cache.expires = now + 30
  return result
end

local function parse_today_buffer_line(line, day)
  local s, e, tags = line:match("^(%d%d:%d%d)%-(%d%d:%d%d)%s*(.*)$")
  if not s then
    local open_s
    open_s, tags = line:match("^(%d%d:%d%d)%-%s*(.*)$")
    if open_s then
      s = open_s
      e = nil
    end
  end
  if not s then
    return nil, "invalid line format: " .. line
  end

  local sh, sm = s:match("^(%d%d):(%d%d)$")
  if not sh then
    return nil, "invalid start time: " .. s
  end

  local function to_ts(hh, mm, day_offset)
    day_offset = day_offset or 0
    return os.time({
      year = day.year,
      month = day.month,
      day = day.day + day_offset,
      hour = tonumber(hh),
      min = tonumber(mm),
      sec = 0,
    })
  end

  local start_epoch = to_ts(sh, sm)
  local end_epoch = nil
  if e then
    local eh, em = e:match("^(%d%d):(%d%d)$")
    if not eh then
      return nil, "invalid end time: " .. e
    end
    end_epoch = to_ts(eh, em)
    -- If end time is before start time, it must be on the next day
    if end_epoch < start_epoch then
      end_epoch = to_ts(eh, em, 1)
    end
  end

  return {
    start_ts = tw_timestamp(start_epoch),
    end_ts = end_epoch and tw_timestamp(end_epoch) or nil,
    tags = split_words(tags or ""),
  }
end

local function today_info()
  return local_day_window(os.time())
end

local function parse_virtual_today_name(name)
  local y, m, d = (name or ""):match("^timewarrior://(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    y, m, d = (name or ""):match("^timewarrior://today/(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  end
  if not y then
    return nil
  end

  local year = tonumber(y)
  local month = tonumber(m)
  local day = tonumber(d)
  if not year or not month or not day then
    return nil
  end

  local start_epoch = os.time({
    year = year,
    month = month,
    day = day,
    hour = 0,
    min = 0,
    sec = 0,
    isdst = nil,
  })
  local end_epoch = os.time({
    year = year,
    month = month,
    day = day + 1,
    hour = 0,
    min = 0,
    sec = 0,
    isdst = nil,
  })

  return {
    year = year,
    month = month,
    day = day,
    start_epoch = start_epoch,
    end_epoch = end_epoch,
  }
end

local function collect_today_entries(today)
  local from = string.format("%04d-%02d-%02d", today.year, today.month, today.day)
  local t_next = os.date("*t", today.end_epoch)
  local to = string.format("%04d-%02d-%02d", t_next.year, t_next.month, t_next.day)
  local intervals = timew_export({ "from", from, "to", to })
  table.sort(intervals, function(a, b)
    return a.start_ts < b.start_ts
  end)
  return intervals
end

local function items_equal(a, b)
  if a.start_ts ~= b.start_ts then return false end
  if (a.end_ts or "") ~= (b.end_ts or "") then return false end
  if #a.tags ~= #b.tags then return false end
  for i, tag in ipairs(a.tags) do
    if b.tags[i] ~= tag then return false end
  end
  return true
end

function M.open_today_view(opts)
  opts = opts or {}
  local today = opts.day or today_info()
  local today_entries = collect_today_entries(today)

  local buf = opts.buf or vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, string.format("timewarrior://%04d-%02d-%02d", today.year, today.month, today.day))
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "timewarrior"
  vim.bo[buf].modifiable = true
  vim.bo[buf].omnifunc = "v:lua.require'timewarrior'.complete_tags"

  local header = {
    "# Timewarrior Today",
    "# Edit lines and :write to persist",
    "# Format: HH:MM-HH:MM tag1 tag2  (or HH:MM- for active)",
    "",
  }

  local body = {}
  for _, entry in ipairs(today_entries) do
    local s = parse_tw_timestamp(entry.start_ts)
    local e = entry.end_ts and parse_tw_timestamp(entry.end_ts) or nil
    local left = os.date("%H:%M", s)
    local right = e and os.date("%H:%M", e) or ""
    local range = right ~= "" and (left .. "-" .. right) or (left .. "-")
    local tags = table.concat(entry.tags, " ")
    table.insert(body, trim(range .. " " .. tags))
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend(header, body))
  if not opts.buf then
    vim.api.nvim_set_current_buf(buf)
  end

  vim.b[buf].timewarrior_entries = today_entries
  vim.b[buf].timewarrior_day = today
  vim.bo[buf].modified = false

  if not vim.b[buf].timewarrior_write_autocmd_set then
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        local day = vim.b[buf].timewarrior_day or today_info()
        local orig_entries = vim.b[buf].timewarrior_entries or {}
        local raw = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

        local rewritten = {}
        for _, l in ipairs(raw) do
          if not l:match("^%s*#") and trim(l) ~= "" then
            table.insert(rewritten, trim(l))
          end
        end

        local new_items = {}
        for _, l in ipairs(rewritten) do
          local item, err = parse_today_buffer_line(trim(l), day)
          if not item then
            vim.notify("timewarrior: " .. err, vim.log.levels.ERROR)
            return
          end
          table.insert(new_items, item)
        end

        -- Reject buffers with more than one open interval
        local open_count = 0
        for _, item in ipairs(new_items) do
          if not item.end_ts then
            open_count = open_count + 1
          end
        end
        if open_count > 1 then
          vim.notify("timewarrior: only one open interval allowed", vim.log.levels.ERROR)
          return
        end

        -- Diff: find entries removed and items added since last save
        local to_delete = {}
        for _, entry in ipairs(orig_entries) do
          local found = false
          for _, item in ipairs(new_items) do
            if items_equal(entry, item) then
              found = true
              break
            end
          end
          if not found then
            table.insert(to_delete, entry)
          end
        end

        local to_add = {}
        for _, item in ipairs(new_items) do
          local found = false
          for _, entry in ipairs(orig_entries) do
            if items_equal(entry, item) then
              found = true
              break
            end
          end
          if not found then
            table.insert(to_add, item)
          end
        end

        -- Delete removed/modified entries first (overlap would block re-add otherwise)
        for _, entry in ipairs(to_delete) do
          local res = timew_run({ "delete", "@" .. entry.id, ":yes" })
          if not res.ok then
            vim.notify("timewarrior: failed to delete @" .. entry.id .. ": " .. res.out, vim.log.levels.ERROR)
            return
          end
        end

        -- Add new/modified entries; open intervals last to avoid conflicts
        table.sort(to_add, function(a, b)
          if not a.end_ts and b.end_ts then return false end
          if a.end_ts and not b.end_ts then return true end
          return (a.start_ts or "") < (b.start_ts or "")
        end)

        for _, item in ipairs(to_add) do
          local args
          if item.end_ts then
            args = { "track", item.start_ts, "-", item.end_ts }
          else
            args = { "start", item.start_ts }
          end
          vim.list_extend(args, item.tags)
          local res = timew_run(args)
          if not res.ok then
            vim.notify("timewarrior: " .. res.out, vim.log.levels.ERROR)
            return
          end
        end

        local refreshed = collect_today_entries(day)
        vim.b[buf].timewarrior_entries = refreshed
        _activity_cache.expires = 0
        vim.notify("timewarrior: saved", vim.log.levels.INFO)
        vim.bo[buf].modified = false
      end,
    })
    vim.b[buf].timewarrior_write_autocmd_set = true
  end
end

function M.complete_tags(findstart, base)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  if findstart == 1 then
    local start = col
    while start > 0 do
      local c = line:sub(start, start)
      if c:match("[%w_-]") then
        start = start - 1
      else
        break
      end
    end
    return start
  end

  local matches = {}
  for _, t in ipairs(collect_tags()) do
    if t:find("^" .. vim.pesc(base)) then
      table.insert(matches, t)
    end
  end
  return matches
end

function M.start_prompt_picker()
  local selected = {}
  local available = collect_tags()

  local function pick_next()
    local opts = { "<done>" }
    for _, tag in ipairs(available) do
      if not vim.tbl_contains(selected, tag) then
        table.insert(opts, tag)
      end
    end

    vim.ui.select(opts, { prompt = "Pick tag (repeat until <done>)" }, function(choice)
      if not choice or choice == "<done>" then
        M.start(selected)
        return
      end
      table.insert(selected, choice)
      pick_next()
    end)
  end

  if #available == 0 then
    vim.ui.input({ prompt = "Tags (space separated): " }, function(input)
      M.start(split_words(input or ""))
    end)
    return
  end

  pick_next()
end

function M.setup()
  if vim.fn.executable("timew") == 0 then
    vim.notify("timewarrior.nvim: 'timew' not found in PATH", vim.log.levels.ERROR)
    return
  end

  vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "timewarrior://*",
    callback = function(args)
      local name = vim.api.nvim_buf_get_name(args.buf)
      local day = parse_virtual_today_name(name) or today_info()
      M.open_today_view({ buf = args.buf, day = day })
    end,
  })

  vim.api.nvim_create_user_command("TimewarriorStart", function(opts)
    M.start(opts.fargs)
  end, { nargs = "*" })

  vim.api.nvim_create_user_command("TimewarriorStartPicker", function()
    M.start_prompt_picker()
  end, {})

  vim.api.nvim_create_user_command("TimewarriorStop", function()
    M.stop()
  end, {})

  vim.api.nvim_create_user_command("TimewarriorToday", function()
    M.open_today_view()
  end, {})
end

M._test = {
  tw_timestamp = tw_timestamp,
  parse_tw_timestamp = parse_tw_timestamp,
  local_day_window = local_day_window,
  ts_is_in_local_day = ts_is_in_local_day,
}

return M
