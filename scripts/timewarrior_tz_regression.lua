local timewarrior = dofile("lua/timewarrior/init.lua")
local test = timewarrior._test

if not test then
  error("timewarrior._test hooks are missing")
end

local function fail(msg)
  error(msg, 0)
end

local function assert_true(cond, msg)
  if not cond then
    fail(msg)
  end
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail(string.format("%s (expected=%s actual=%s)", msg, tostring(expected), tostring(actual)))
  end
end

local function check_roundtrip_utc(ts)
  local epoch = test.parse_tw_timestamp(ts)
  assert_true(epoch ~= nil, "parse_tw_timestamp returned nil for " .. ts)
  local rt = test.tw_timestamp(epoch)
  assert_eq(rt, ts, "UTC roundtrip mismatch for " .. ts)
end

local function check_roundtrip_local(year, month, day, hour, min)
  local local_epoch = os.time({
    year = year,
    month = month,
    day = day,
    hour = hour,
    min = min,
    sec = 0,
    isdst = nil,
  })
  assert_true(local_epoch ~= nil, string.format("invalid local time %04d-%02d-%02d %02d:%02d", year, month, day, hour, min))

  local utc_ts = test.tw_timestamp(local_epoch)
  local back = test.parse_tw_timestamp(utc_ts)
  assert_true(back ~= nil, "failed to parse generated UTC timestamp " .. utc_ts)

  local expected_local = os.date("%Y-%m-%d %H:%M", local_epoch)
  local actual_local = os.date("%Y-%m-%d %H:%M", back)
  assert_eq(actual_local, expected_local, "Local roundtrip mismatch")
end

local function check_local_day_membership(year, month, day, hour, min)
  local local_epoch = os.time({
    year = year,
    month = month,
    day = day,
    hour = hour,
    min = min,
    sec = 0,
    isdst = nil,
  })
  local day_window = test.local_day_window(local_epoch)
  local utc_ts = test.tw_timestamp(local_epoch)

  assert_true(test.ts_is_in_local_day(utc_ts, day_window), "timestamp should be in local day window")

  local prev_day = test.local_day_window(day_window.start_epoch - 1)
  assert_true(not test.ts_is_in_local_day(utc_ts, prev_day), "timestamp incorrectly matched previous local day")
end

local utc_samples = {
  "20260228T000000Z",
  "20260228T235959Z",
  "20260329T005900Z",
  "20260329T010100Z",
  "20261101T055900Z",
  "20261101T060100Z",
}

for _, ts in ipairs(utc_samples) do
  check_roundtrip_utc(ts)
end

check_roundtrip_local(2026, 2, 28, 0, 30)
check_roundtrip_local(2026, 2, 28, 23, 30)
check_roundtrip_local(2026, 3, 1, 0, 30)
check_roundtrip_local(2026, 3, 29, 1, 30)
check_roundtrip_local(2026, 11, 1, 1, 30)

check_local_day_membership(2026, 2, 28, 0, 30)
check_local_day_membership(2026, 2, 28, 23, 30)
check_local_day_membership(2026, 3, 1, 0, 30)

print("timewarrior timezone regression checks passed")
