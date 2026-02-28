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

local function tw_home()
  local home = os.getenv("TIMEWARRIORDB")
  if home and home ~= "" then
    return home
  end
  return (os.getenv("HOME") or "") .. "/.timewarrior"
end

local function data_dir()
  return tw_home() .. "/data"
end

local function ensure_data_dir()
  vim.fn.mkdir(data_dir(), "p")
end

local function month_file_for_time(epoch)
  return string.format("%s/%s.data", data_dir(), os.date("!%Y-%m", epoch))
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

local function read_file_lines(path)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  return vim.fn.readfile(path)
end

local function write_file_lines(path, lines)
  vim.fn.writefile(lines, path)
end

local function list_data_files()
  local files = vim.fn.globpath(data_dir(), "*.data", false, true)
  table.sort(files)
  return files
end

local function parse_data_line(line)
  local start_ts, maybe_end, tail = line:match("^inc%s+(%S+)%s*(%S*)%s*(.*)$")
  if not start_ts then
    return nil
  end

  local tags_text = ""
  local end_ts = nil

  if maybe_end == "#" then
    tags_text = tail or ""
  elseif maybe_end == "" then
    tags_text = ""
  elseif maybe_end:sub(1, 1) == "#" then
    tags_text = (maybe_end:sub(2) .. " " .. (tail or ""))
  else
    end_ts = maybe_end
    local hash_idx = (tail or ""):find("#")
    if hash_idx then
      tags_text = (tail or ""):sub(hash_idx + 1)
    end
  end

  local tags = split_words(trim(tags_text))
  return {
    start_ts = start_ts,
    end_ts = end_ts,
    tags = tags,
  }
end

local function render_data_line(item)
  local parts = { "inc", item.start_ts }
  if item.end_ts and item.end_ts ~= "" then
    table.insert(parts, item.end_ts)
  end
  if item.tags and #item.tags > 0 then
    table.insert(parts, "#")
    vim.list_extend(parts, item.tags)
  end
  return table.concat(parts, " ")
end

local function collect_tags()
  local seen = {}
  local tags = {}
  for _, file in ipairs(list_data_files()) do
    for _, line in ipairs(read_file_lines(file)) do
      local item = parse_data_line(line)
      if item then
        for _, tag in ipairs(item.tags) do
          if not seen[tag] then
            seen[tag] = true
            table.insert(tags, tag)
          end
        end
      end
    end
  end
  table.sort(tags)
  return tags
end

local function find_last_open_interval()
  local files = list_data_files()
  for i = #files, 1, -1 do
    local file = files[i]
    local lines = read_file_lines(file)
    for j = #lines, 1, -1 do
      local item = parse_data_line(lines[j])
      if item and not item.end_ts then
        return {
          file = file,
          line_idx = j,
          line = lines[j],
          item = item,
          lines = lines,
        }
      end
    end
  end
  return nil
end

function M.start(tags)
  ensure_data_dir()
  tags = tags or {}
  local now = os.time()
  local file = month_file_for_time(now)
  local lines = read_file_lines(file)
  table.insert(lines, render_data_line({
    start_ts = tw_timestamp(now),
    tags = tags,
  }))
  write_file_lines(file, lines)
  vim.notify("timewarrior: started interval", vim.log.levels.INFO)
end

function M.stop()
  local open = find_last_open_interval()
  if not open then
    vim.notify("timewarrior: no open interval found", vim.log.levels.WARN)
    return
  end
  open.item.end_ts = tw_timestamp(os.time())
  open.lines[open.line_idx] = render_data_line(open.item)
  write_file_lines(open.file, open.lines)
  vim.notify("timewarrior: stopped interval", vim.log.levels.INFO)
end

function M.current_activity()
  local open = find_last_open_interval()
  if not open then
    return ""
  end

  local tags = open.item.tags or {}
  if #tags == 0 then
    return "active"
  end

  return table.concat(tags, " ")
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

  local function to_ts(hh, mm)
    return os.time({
      year = day.year,
      month = day.month,
      day = day.day,
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

local function sort_rendered_lines(lines)
  table.sort(lines, function(a, b)
    local pa, pb = parse_data_line(a), parse_data_line(b)
    if pa and pb then
      return pa.start_ts < pb.start_ts
    end
    return a < b
  end)
end

local function collect_today_entries(today, source_by_file)
  local entries = {}
  local sources = {}

  if source_by_file then
    for file, lines in pairs(source_by_file) do
      sources[file] = lines
      for i, line in ipairs(lines) do
        local item = parse_data_line(line)
        if item then
          if ts_is_in_local_day(item.start_ts, today) then
            table.insert(entries, {
              file = file,
              line_idx = i,
              item = item,
            })
          end
        end
      end
    end
  else
    for _, file in ipairs(list_data_files()) do
      local lines = read_file_lines(file)
      sources[file] = lines
      for i, line in ipairs(lines) do
        local item = parse_data_line(line)
        if item then
          if ts_is_in_local_day(item.start_ts, today) then
            table.insert(entries, {
              file = file,
              line_idx = i,
              item = item,
            })
          end
        end
      end
    end
  end

  table.sort(entries, function(a, b)
    if a.item.start_ts == b.item.start_ts then
      if a.file == b.file then
        return a.line_idx < b.line_idx
      end
      return a.file < b.file
    end
    return a.item.start_ts < b.item.start_ts
  end)

  return entries, sources
end

function M.open_today_view()
  ensure_data_dir()
  local today = today_info()
  local today_entries, source_by_file = collect_today_entries(today)

  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "timewarrior_today"
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
    local s = parse_tw_timestamp(entry.item.start_ts)
    local e = entry.item.end_ts and parse_tw_timestamp(entry.item.end_ts) or nil
    local left = os.date("%H:%M", s)
    local right = e and os.date("%H:%M", e) or ""
    local range = right ~= "" and (left .. "-" .. right) or (left .. "-")
    local tags = table.concat(entry.item.tags, " ")
    table.insert(body, trim(range .. " " .. tags))
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend(header, body))
  vim.api.nvim_set_current_buf(buf)

  vim.b[buf].timewarrior_today_source_by_file = source_by_file
  vim.b[buf].timewarrior_today_entries = today_entries

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local today_entries = vim.b[buf].timewarrior_today_entries or {}
      local source_by_file = vim.b[buf].timewarrior_today_source_by_file or {}
      local raw = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      local rewritten = {}
      for _, l in ipairs(raw) do
        if not l:match("^%s*#") and trim(l) ~= "" then
          table.insert(rewritten, l)
        end
      end

      local new_items = {}
      for _, l in ipairs(rewritten) do
        local item, err = parse_today_buffer_line(trim(l), today)
        if not item then
          vim.notify("timewarrior: " .. err, vim.log.levels.ERROR)
          return
        end
        table.insert(new_items, item)
      end

      local remove_by_file = {}
      for _, entry in ipairs(today_entries) do
        remove_by_file[entry.file] = remove_by_file[entry.file] or {}
        remove_by_file[entry.file][entry.line_idx] = true
      end

      local updated_by_file = {}
      for file, lines in pairs(source_by_file) do
        local remove = remove_by_file[file] or {}
        local kept = {}
        for i, l in ipairs(lines) do
          if not remove[i] then
            table.insert(kept, l)
          end
        end
        updated_by_file[file] = kept
      end

      for _, item in ipairs(new_items) do
        local start_epoch = parse_tw_timestamp(item.start_ts)
        if not start_epoch then
          vim.notify("timewarrior: invalid start timestamp while saving", vim.log.levels.ERROR)
          return
        end
        local file = month_file_for_time(start_epoch)
        if not updated_by_file[file] then
          updated_by_file[file] = read_file_lines(file)
        end
        table.insert(updated_by_file[file], render_data_line(item))
      end

      for file, lines in pairs(updated_by_file) do
        sort_rendered_lines(lines)
        write_file_lines(file, lines)
      end

      local refreshed_entries, refreshed_sources = collect_today_entries(today, updated_by_file)
      vim.b[buf].timewarrior_today_entries = refreshed_entries
      vim.b[buf].timewarrior_today_source_by_file = refreshed_sources
      vim.notify("timewarrior: wrote today view", vim.log.levels.INFO)
      vim.bo[buf].modified = false
    end,
  })
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
