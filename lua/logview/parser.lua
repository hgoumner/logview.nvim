local M = {}

local levels = {
  TRACE = "TRACE",
  DEBUG = "DEBUG",
  INFO = "INFO",
  NOTICE = "INFO",
  WARN = "WARN",
  WARNING = "WARN",
  ERR = "ERROR",
  ERROR = "ERROR",
  CRIT = "FATAL",
  CRITICAL = "FATAL",
  FATAL = "FATAL",
  ALERT = "FATAL",
  EMERG = "FATAL",
  EMERGENCY = "FATAL",
}

local severity = { TRACE = 1, DEBUG = 2, INFO = 3, WARN = 4, ERROR = 5, FATAL = 6 }

function M.normalize_level(level)
  return levels[level:upper()]
end

function M.meets_level(level, minimum)
  return severity[level] >= severity[minimum]
end

local months = {}
for month in ("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec"):gmatch("%a+") do
  months[month:lower()] = true
end
local zones = {}
for zone in ("UTC GMT CET CEST EET EEST WET WEST BST EST EDT CST CDT MST MDT PST PDT"):gmatch("%a+") do
  zones[zone] = true
end

local clock = "%d%d:%d%d:%d%d"
local timestamp_patterns = {
  "%d%d%d%d%-%d%d%-%d%d[Tt ,]+" .. clock,
  "%d%d%d%d/%d%d/%d%d%s+" .. clock,
  "%d%d/%d%d/%d%d%s+" .. clock,
  "%d%d?/%a%a%a/%d%d%d%d:" .. clock,
  "%a%a%a%s+%d%d?%s+" .. clock,
  clock,
}

local function valid_timestamp(value)
  local hour, minute, second = value:match("(%d%d):(%d%d):(%d%d)$")
  if tonumber(hour) > 23 or tonumber(minute) > 59 or tonumber(second) > 60 then
    return false
  end
  local month = value:match("/(%a%a%a)/") or value:match("^(%a%a%a)%s")
  if month and not months[month:lower()] then
    return false
  end
  return true
end

local function timestamp_end(line, last)
  local rest = line:sub(last + 1)
  local fraction = rest:match("^[.,]%d+")
  if fraction then
    last = last + #fraction
    rest = line:sub(last + 1)
  end
  local offset = rest:match("^%s*[+-]%d%d:?%d%d")
  local utc = rest:match("^[Zz]")
  local named, zone = rest:match("^(%s+(%a+))")
  local suffix = offset or utc or (zones[zone] and named)
  if suffix and not line:sub(last + #suffix + 1, last + #suffix + 1):match("[%w_]") then
    last = last + #suffix
  end
  return last
end

local function overlaps(spans, first, last)
  for _, span in ipairs(spans) do
    if first <= span.end_col and last > span.start_col then
      return true
    end
  end
  return false
end

local function level_context(line, first, last, timestamps)
  local before, after = line:sub(1, first - 1), line:sub(last + 1)
  if before:match("^%s*$") or (before:match("%[%s*$") and after:match("^%s*%]")) then
    return true
  end
  if before:lower():match("[\"']?level[\"']?%s*[:=]%s*[\"']?$")
    or before:lower():match("[\"']?severity[\"']?%s*[:=]%s*[\"']?$")
  then
    return true
  end
  for _, span in ipairs(timestamps) do
    if span.end_col < first and line:sub(span.end_col + 1, first - 1):match("^[%s%]%[|:%-]*$") then
      return true
    end
  end
  return false
end

---Return byte-based, end-exclusive highlight spans and the strongest level.
---@param line string
---@return table[], string?
function M.parse(line)
  local spans = {}
  for _, pattern in ipairs(timestamp_patterns) do
    local position = 1
    while true do
      local first, last = line:find(pattern, position)
      if not first then
        break
      end
      local valid = valid_timestamp(line:sub(first, last))
      last = timestamp_end(line, last)
      if not line:sub(first - 1, first - 1):match("[%w_]")
        and not line:sub(last + 1, last + 1):match("[%w_]")
        and valid
        and not overlaps(spans, first, last)
      then
        spans[#spans + 1] = { start_col = first - 1, end_col = last, group = "LogViewTimestamp" }
      end
      position = last + 1
    end
  end

  local timestamps = {}
  for i, span in ipairs(spans) do
    timestamps[i] = span
  end
  local strongest
  for first, word, following in line:gmatch("()([%a]+)()") do
    local last = following - 1
    local level = levels[word:upper()]
    if level
      and not line:sub(first - 1, first - 1):match("[%w_./%-]")
      and not line:sub(following, following):match("[%w_./%-]")
      and (word == word:upper() or level_context(line, first, last, timestamps))
      and not overlaps(timestamps, first, last)
    then
      spans[#spans + 1] = { start_col = first - 1, end_col = last, group = "LogView" .. level }
      if not strongest or severity[level] > severity[strongest] then
        strongest = level
      end
    end
  end
  table.sort(spans, function(a, b)
    return a.start_col < b.start_col
  end)
  return spans, strongest
end

return M
