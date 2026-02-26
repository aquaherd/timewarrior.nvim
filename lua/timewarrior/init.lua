local M = {}

local uv = vim.uv or vim.loop

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
  return string.format("%s/%s.data", data_dir(), os.date("%Y-%m", epoch))
end

local function tw_timestamp(epoch)
  return os.date("!%Y%m%dT%H%M%SZ", epoch)
end

local function parse_tw_timestamp(ts)
  local y, m, d, hh, mm, ss = ts:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z$")
  if not y then
    return nil
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(hh),
    min = tonumber(mm),
    sec = tonumber(ss),
    isdst = false,
  })
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
  local t = os.date("*t")
  return {
    year = t.year,
    month = t.month,
    day = t.day,
    ymd = os.date("%Y%m%d"),
  }
end

function M.open_today_view()
  ensure_data_dir()
  local today = today_info()
  local file = month_file_for_time(os.time())
  local lines = read_file_lines(file)

  local today_entries = {}
  local today_line_indices = {}
  for i, line in ipairs(lines) do
    local item = parse_data_line(line)
    if item and item.start_ts:sub(1, 8) == today.ymd then
      table.insert(today_entries, item)
      table.insert(today_line_indices, i)
    end
  end

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
  for _, item in ipairs(today_entries) do
    local s = parse_tw_timestamp(item.start_ts)
    local e = item.end_ts and parse_tw_timestamp(item.end_ts) or nil
    local left = os.date("%H:%M", s)
    local right = e and os.date("%H:%M", e) or ""
    local range = right ~= "" and (left .. "-" .. right) or (left .. "-")
    local tags = table.concat(item.tags, " ")
    table.insert(body, trim(range .. " " .. tags))
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend(header, body))
  vim.api.nvim_set_current_buf(buf)

  vim.b[buf].timewarrior_today_file = file
  vim.b[buf].timewarrior_source_lines = lines
  vim.b[buf].timewarrior_today_indices = today_line_indices

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local src_lines = vim.b[buf].timewarrior_source_lines
      local indices = vim.b[buf].timewarrior_today_indices
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

      local keep = {}
      local remove = {}
      for _, idx in ipairs(indices) do
        remove[idx] = true
      end

      for i, l in ipairs(src_lines) do
        if not remove[i] then
          table.insert(keep, l)
        end
      end

      for _, item in ipairs(new_items) do
        table.insert(keep, render_data_line(item))
      end

      table.sort(keep, function(a, b)
        local pa, pb = parse_data_line(a), parse_data_line(b)
        if pa and pb then
          return pa.start_ts < pb.start_ts
        end
        return a < b
      end)

      write_file_lines(vim.b[buf].timewarrior_today_file, keep)
      vim.b[buf].timewarrior_source_lines = keep
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

return M
