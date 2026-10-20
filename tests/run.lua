vim.opt.runtimepath:prepend(vim.fn.getcwd())

local count = 0
local function equal(expected, actual)
  if not vim.deep_equal(expected, actual) then
    error("Expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual), 2)
  end
end

local function test(name, callback)
  local ok, err = pcall(callback)
  if not ok then
    io.stderr:write("FAIL " .. name .. "\n" .. tostring(err) .. "\n")
    vim.cmd("cquit 1")
  end
  count = count + 1
end

local parser = require("logview.parser")
local function tokens(line)
  local spans, level = parser.parse(line)
  local result = {}
  for _, span in ipairs(spans) do
    result[#result + 1] = { line:sub(span.start_col + 1, span.end_col), span.group }
  end
  return result, level
end

test("mixed timestamp formats and suffixes", function()
  for _, timestamp in ipairs({
    "2026-10-20T11:28:04.646Z",
    "2026-10-20t11:28:04z",
    "2026-10-20 11:28:04,646",
    "2026-10-20, 11:28:04.646 UTC",
    "2026-10-20T11:28:04+02:00",
    "2026/10/20 11:28:04",
    "26/10/20 11:28:04",
    "20/Oct/2026:11:28:04 +0000",
    "Oct  2 11:28:04",
    "11:28:04.123456789",
  }) do
    local actual, level = tokens("[" .. timestamp .. "] ERROR failed")
    equal({ { timestamp, "LogViewTimestamp" }, { "ERROR", "LogViewERROR" } }, actual)
    equal("ERROR", level)
  end
end)

test("JSON, lowercase contexts, aliases and strongest severity", function()
  for _, case in ipairs({
    { '{"level":"error"}', "error", "ERROR" },
    { "severity=critical failed", "critical", "FATAL" },
    { "Warning: retry", "Warning", "WARN" },
    { "[debug] details", "debug", "DEBUG" },
    { "2026-10-20 11:28:04 info ready", "info", "INFO" },
    { "NOTICE started", "NOTICE", "INFO" },
    { "ERR: failed", "ERR", "ERROR" },
    { "EMERGENCY failed", "EMERGENCY", "FATAL" },
  }) do
    local actual, level = tokens(case[1])
    equal({ case[2], "LogView" .. case[3] }, actual[#actual])
    equal(case[3], level)
  end
  local _, level = tokens("INFO outer logger: ERROR inner failure")
  equal("ERROR", level)
end)

test("non-level prose, identifiers, invalid clocks and byte offsets", function()
  for _, line in ipairs({
    "An error occurred while reading the info file",
    "DEBUGGER ERROR_CODE /ERROR/path error.log some.INFO",
    "99:99:99 no valid clock",
    "normal stack trace",
    "",
  }) do
    equal({}, tokens(line))
  end
  local line = "\195\169 [ERROR] failed"
  local spans = parser.parse(line)
  equal({ { start_col = 4, end_col = 9, group = "LogViewERROR" } }, spans)
end)

-- Capture the provider for deterministic range checks without a UI dependency.
local provider
local original_provider = vim.api.nvim_set_decoration_provider
vim.api.nvim_set_decoration_provider = function(ns, callbacks)
  provider = callbacks
  return original_provider(ns, callbacks)
end
local already_open = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(already_open, vim.fn.getcwd() .. "/already-open.log")
vim.cmd("runtime plugin/logview.lua")
vim.api.nvim_set_decoration_provider = original_provider
local logview = require("logview")

test("filter API and command are available immediately after loading", function()
  equal("function", type(logview.filter))
  equal(2, vim.fn.exists(":LogFilter"))
end)

test("plugin-manager configuration precedes automatic activation", function()
  logview.setup({ auto = false })
  vim.wait(10, function()
    return false
  end)
  equal(false, logview.is_enabled(already_open))
  logview.setup()
  vim.wait(10, function()
    return logview.is_enabled(already_open)
  end)
  equal(true, logview.is_enabled(already_open))
end)

test("commands, automatic activation and per-buffer isolation", function()
  local log = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(log, vim.fn.getcwd() .. "/test-example.log")
  vim.api.nvim_set_current_buf(log)
  vim.api.nvim_exec_autocmds("BufReadPost", { buffer = log })
  equal(true, logview.is_enabled())
  vim.cmd("LogView off")
  equal(false, logview.is_enabled())
  vim.api.nvim_exec_autocmds("BufReadPost", { buffer = log })
  equal(false, logview.is_enabled())
  vim.cmd("LogView toggle")
  equal(true, logview.is_enabled())
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(other)
  equal(false, logview.is_enabled())
  vim.cmd("LogView")
  equal(true, logview.is_enabled())
  vim.cmd("LogView off")
  equal(true, logview.is_enabled(log))
  equal(false, logview.is_enabled(other))
end)

test("real redraw highlights the last visible line and clears on disable", function()
  local buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "INFO ready", "ERROR failed" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  logview.enable()
  vim.cmd("redraw!")
  equal("E", vim.fn.screenstring(2, 1))
  local error_attribute = vim.fn.screenattr(2, 1)
  local background_attribute = vim.fn.screenattr(2, 8)
  equal(true, error_attribute ~= 0)
  equal(true, background_attribute ~= 0)
  equal({}, vim.api.nvim_buf_get_extmarks(buffer, vim.api.nvim_create_namespace("logview"), 0, -1, {}))
  logview.disable()
  vim.cmd("redraw!")
  equal(true, error_attribute ~= vim.fn.screenattr(2, 1))
  equal(true, background_attribute ~= vim.fn.screenattr(2, 8))
end)

test("real redraw follows appends, edits and scrolling", function()
  local buffer = vim.api.nvim_get_current_buf()
  local lines = {}
  for i = 1, 100 do
    lines[i] = "ordinary line " .. i
  end
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  logview.enable()
  vim.api.nvim_buf_set_lines(buffer, -1, -1, false, { "FATAL appended" })
  vim.cmd("normal! Gzb")
  vim.cmd("redraw!")
  local position = vim.fn.screenpos(0, 101, 1)
  equal(true, position.row > 0)
  equal("F", vim.fn.screenstring(position.row, position.col))
  local fatal_attribute = vim.fn.screenattr(position.row, position.col)
  equal(true, fatal_attribute ~= 0)
  vim.api.nvim_buf_set_lines(buffer, 100, 101, false, { "ordinary recovery" })
  vim.cmd("redraw!")
  equal(true, fatal_attribute ~= vim.fn.screenattr(position.row, position.col))
  vim.api.nvim_buf_set_lines(buffer, 0, 1, false, { "ERROR at top" })
  vim.cmd("normal! ggzt")
  vim.cmd("redraw!")
  position = vim.fn.screenpos(0, 1, 1)
  equal("E", vim.fn.screenstring(position.row, position.col))
  equal(true, vim.fn.screenattr(position.row, position.col) ~= 0)
end)

test("visible range, live edits, error backgrounds and unchanged buffer", function()
  local buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "INFO outside viewport",
    "2026-10-20T11:28:04Z ERROR failed",
    "WARN outside viewport",
  })
  logview.enable()
  local before = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local modified, filetype = vim.bo[buffer].modified, vim.bo[buffer].filetype
  local cursor = vim.api.nvim_win_get_cursor(0)
  local marks = {}
  local original_extmark = vim.api.nvim_buf_set_extmark
  vim.api.nvim_buf_set_extmark = function(buf, ns, row, col, opts)
    marks[#marks + 1] = { buffer = buf, row = row, col = col, opts = opts }
    return 1
  end
  local ok, err = pcall(function()
    provider.on_win(nil, 0, buffer, 1, 1)
    equal(3, #marks)
    equal("LogViewErrorLine", marks[1].opts.hl_group)
    equal("LogViewTimestamp", marks[2].opts.hl_group)
    equal("LogViewERROR", marks[3].opts.hl_group)
    for _, mark in ipairs(marks) do
      equal(1, mark.row)
      equal(true, mark.opts.ephemeral)
    end
    equal(before, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    equal(modified, vim.bo[buffer].modified)
    equal(filetype, vim.bo[buffer].filetype)
    equal(cursor, vim.api.nvim_win_get_cursor(0))
    vim.api.nvim_buf_set_lines(buffer, 1, 2, false, { "DEBUG recovered" })
    marks = {}
    provider.on_win(nil, 0, buffer, 1, 1)
    equal(1, #marks)
    equal("LogViewDEBUG", marks[1].opts.hl_group)
    logview.disable()
    marks = {}
    equal(false, provider.on_win(nil, 0, buffer, 0, 2))
    equal(0, #marks)
  end)
  vim.api.nvim_buf_set_extmark = original_extmark
  if not ok then
    error(err)
  end
end)

test("configuration validation and repeated setup", function()
  equal(false, pcall(logview.setup, { error_background = 2 }))
  equal(false, pcall(logview.setup, { patterns = { false } }))
  logview.setup({ auto = false, error_background = 0 })
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buffer, vim.fn.getcwd() .. "/disabled.log")
  vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buffer })
  equal(false, logview.is_enabled(buffer))
  logview.enable(buffer)
  logview.setup({ auto = false })
  equal(true, logview.is_enabled(buffer))
end)

test("colorscheme changes update the error tint", function()
  vim.api.nvim_set_hl(0, "Normal", { bg = 0x000000 })
  vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0xff0000 })
  logview.setup({ error_background = 0.2 })
  equal(0x330000, vim.api.nvim_get_hl(0, { name = "LogViewErrorLine" }).bg)
  vim.api.nvim_set_hl(0, "Normal", { bg = 0xffffff })
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "test" })
  equal(0xffcccc, vim.api.nvim_get_hl(0, { name = "LogViewErrorLine" }).bg)
end)

local function filter_buffer(lines)
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! zt")
  return buffer
end

local function screen_line(row)
  local text = ""
  for column = 1, 60 do
    text = text .. vim.fn.screenstring(row, column)
  end
  return vim.trim(text)
end

test("minimum filter hides entries and preserves matching continuations", function()
  local lines = {
    "unclassified header",
    "DEBUG details",
    "debug continuation",
    "WARN retrying",
    "warning continuation",
    "ERROR failed",
    "  traceback frame",
    "FATAL stopped",
    "fatal continuation",
    "INFO recovered",
    "info continuation",
  }
  local buffer = filter_buffer(lines)
  vim.bo[buffer].modified = false
  local tick = vim.api.nvim_buf_get_changedtick(buffer)
  local visible, total = logview.filter("warning")
  equal(6, visible)
  equal(#lines, total)
  vim.cmd("normal! ggzt")
  vim.cmd("redraw!")
  for row, expected in ipairs({
    "WARN retrying", "warning continuation", "ERROR failed",
    "traceback frame", "FATAL stopped", "fatal continuation",
  }) do
    equal(expected, screen_line(row))
  end
  equal(lines, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  equal(tick, vim.api.nvim_buf_get_changedtick(buffer))
  equal(false, vim.bo[buffer].modified)
  logview.filter("ALL")
  vim.cmd("normal! ggzt")
  vim.cmd("redraw!")
  equal("unclassified header", screen_line(1))
end)

test("empty filter results and invalid levels leave text intact", function()
  local buffer = filter_buffer({ "header", "INFO ready", "continuation" })
  local visible = logview.filter("ERROR")
  equal(0, visible)
  vim.cmd("redraw!")
  equal("~", screen_line(1))
  equal(false, pcall(logview.filter, "INVALID"))
  equal(3, vim.api.nvim_buf_line_count(buffer))
  logview.filter("ALL")
  equal(false, pcall(logview.filter, false))
  equal(3, vim.api.nvim_buf_line_count(buffer))
end)

test("filters update after appends and edits", function()
  local buffer = filter_buffer({ "INFO ready", "ERROR failed", "traceback" })
  logview.filter("ERROR")
  vim.api.nvim_buf_set_lines(buffer, -1, -1, false, { "WARN retry", "hidden detail", "FATAL stopped" })
  vim.wait(20, function()
    return false
  end)
  vim.cmd("normal! ggzt")
  vim.cmd("redraw!")
  equal("ERROR failed", screen_line(1))
  equal("traceback", screen_line(2))
  equal("FATAL stopped", screen_line(3))
  vim.api.nvim_buf_set_lines(buffer, 1, 2, false, { "DEBUG recovered" })
  vim.wait(20, function()
    return false
  end)
  vim.cmd("normal! ggzt")
  vim.cmd("redraw!")
  equal("FATAL stopped", screen_line(1))
  logview.filter("ALL")
end)

test("deleting a level header reclassifies its continuations", function()
  local buffer = filter_buffer({ "ERROR failed", "  stack frame", "INFO ready", "  later frame", "" })
  logview.filter("ERROR")
  vim.api.nvim_buf_set_lines(buffer, 2, 3, false, {})
  vim.wait(20, function()
    return false
  end)
  vim.cmd("normal! ggzt")
  vim.cmd("redraw!")
  equal("ERROR failed", screen_line(1))
  equal("stack frame", screen_line(2))
  equal("later frame", screen_line(3))
  equal(4, logview.filter("ERROR"))
  vim.api.nvim_buf_set_lines(buffer, 0, 1, false, { "DEBUG recovered" })
  vim.wait(20, function()
    return false
  end)
  equal(0, logview.filter("ERROR"))
  logview.filter("ALL")
end)

test("window options restore across splits, buffer switches and disabling", function()
  local buffer = filter_buffer({ "INFO hidden", "ERROR visible" })
  vim.wo.conceallevel = 1
  vim.wo.concealcursor = "nc"
  local original_window = vim.api.nvim_get_current_win()
  logview.filter("ERROR")
  equal(3, vim.wo.conceallevel)
  equal("nvic", vim.wo.concealcursor)
  vim.cmd("split")
  local split = vim.api.nvim_get_current_win()
  equal(3, vim.wo.conceallevel)
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(other)
  equal(1, vim.wo.conceallevel)
  equal("nc", vim.wo.concealcursor)
  vim.api.nvim_set_current_win(original_window)
  equal(buffer, vim.api.nvim_get_current_buf())
  equal(3, vim.wo.conceallevel)
  logview.disable()
  equal(1, vim.wo.conceallevel)
  equal("nc", vim.wo.concealcursor)
  equal(0, #vim.api.nvim_buf_get_extmarks(buffer, vim.api.nvim_create_namespace("logview-filter"), 0, -1, {}))
  vim.api.nvim_win_close(split, true)
end)

test("command completion, aliases, repeated setup and buffer isolation", function()
  local buffer = filter_buffer({ "TRACE details", "WARN retry", "ERROR failed", "FATAL stopped" })
  vim.cmd("LogFilter err")
  equal({ "ERROR" }, vim.fn.getcompletion("LogFilter er", "cmdline"))
  logview.setup()
  vim.cmd("normal! ggzt")
  vim.cmd("redraw!")
  equal("ERROR failed", screen_line(1))
  local other = filter_buffer({ "INFO other buffer" })
  equal(0, #vim.api.nvim_buf_get_extmarks(other, vim.api.nvim_create_namespace("logview-filter"), 0, -1, {}))
  vim.api.nvim_set_current_buf(buffer)
  equal(3, vim.wo.conceallevel)
  equal(4, logview.filter("TRACE"))
  vim.cmd("LogFilter ALL")
  equal(0, #vim.api.nvim_buf_get_extmarks(buffer, vim.api.nvim_create_namespace("logview-filter"), 0, -1, {}))
end)

test("wiping a filtered buffer restores window options", function()
  local other = filter_buffer({ "ordinary buffer" })
  vim.wo.conceallevel = 2
  vim.wo.concealcursor = "v"
  local buffer = filter_buffer({ "INFO hidden", "ERROR visible" })
  logview.filter("ERROR")
  vim.api.nvim_buf_delete(buffer, { force = true })
  vim.wait(20, function()
    return false
  end)
  equal(other, vim.api.nvim_get_current_buf())
  equal(2, vim.wo.conceallevel)
  equal("v", vim.wo.concealcursor)
end)

local stream = require("logview.stream")
local function close_stream_window(window)
  if #vim.api.nvim_list_wins() == 1 then
    vim.api.nvim_buf_delete(vim.api.nvim_win_get_buf(window), { force = true })
  else
    vim.api.nvim_win_close(window, true)
  end
end

local function wait_for(predicate)
  equal(true, vim.wait(3000, predicate, 5))
end

local function fake_stream(callback)
  local original_start, original_stop = vim.fn.jobstart, vim.fn.jobstop
  local callbacks, stopped
  vim.fn.jobstart = function(_, opts)
    callbacks = opts
    return 12345
  end
  vim.fn.jobstop = function(job)
    equal(12345, job)
    stopped = true
    return 1
  end
  local buffer, window
  local ok, err = pcall(function()
    buffer = stream.open({ "fake-command" })
    window = vim.api.nvim_get_current_win()
    callback(buffer, callbacks, function()
      return stopped
    end)
  end)
  if window and vim.api.nvim_win_is_valid(window) then
    close_stream_window(window)
  end
  vim.fn.jobstart, vim.fn.jobstop = original_start, original_stop
  if not ok then
    error(err)
  end
end

test("stream uses the current window and preserves an unsaved file", function()
  local previous = filter_buffer({ "unsaved work" })
  local window = vim.api.nvim_get_current_win()
  local windows = vim.api.nvim_list_wins()
  local hidden = vim.o.hidden
  vim.o.hidden = false
  local ok, err = pcall(function()
    fake_stream(function(buffer)
      equal(window, vim.api.nvim_get_current_win())
      equal(windows, vim.api.nvim_list_wins())
      equal(buffer, vim.api.nvim_win_get_buf(window))
      equal(true, vim.api.nvim_buf_is_loaded(previous))
      equal(true, vim.bo[previous].modified)
      equal({ "unsaved work" }, vim.api.nvim_buf_get_lines(previous, 0, -1, false))
    end)
  end)
  vim.o.hidden = hidden
  if not ok then
    error(err)
  end
end)

test("stream chunks reconstruct partial lines, CRLF and blank lines", function()
  fake_stream(function(buffer, callbacks)
    equal(true, logview.is_enabled(buffer))
    equal(false, vim.bo[buffer].modifiable)
    callbacks.on_stdout(12345, { "2026-10-20T11:28:04Z ER" })
    wait_for(function()
      return vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1]:match("ER$") ~= nil
    end)
    callbacks.on_stdout(12345, { "ROR failed\r", "detail", "", "par" })
    callbacks.on_stdout(12345, { "tial" })
    callbacks.on_stdout(12345, { "" })
    wait_for(function()
      return vim.api.nvim_buf_line_count(buffer) == 4
    end)
    equal({
      "2026-10-20T11:28:04Z ERROR failed", "detail", "", "partial",
    }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    callbacks.on_stdout(12345, { "", "INFO done", "" })
    wait_for(function()
      return vim.api.nvim_buf_line_count(buffer) == 5
    end)
    equal("INFO done", vim.api.nvim_buf_get_lines(buffer, 4, 5, false)[1])
    equal(false, vim.bo[buffer].modified)
    equal(false, vim.bo[buffer].modifiable)
  end)
end)

test("stream follows output, pauses above the end and resumes at G", function()
  fake_stream(function(buffer, callbacks)
    callbacks.on_stdout(12345, { "INFO first", "ERROR second", "WARN third", "" })
    wait_for(function()
      return vim.api.nvim_win_get_cursor(0)[1] == 3
    end)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    callbacks.on_stdout(12345, { "INFO fourth", "" })
    wait_for(function()
      return vim.api.nvim_buf_line_count(buffer) == 4
    end)
    equal(1, vim.api.nvim_win_get_cursor(0)[1])
    vim.cmd("normal! G")
    callbacks.on_stdout(12345, { "ERROR fifth", "" })
    wait_for(function()
      return vim.api.nvim_win_get_cursor(0)[1] == 5
    end)
  end)
end)

test("each stream window follows independently", function()
  fake_stream(function(buffer, callbacks)
    callbacks.on_stdout(12345, { "INFO first", "INFO second", "ERROR third", "" })
    wait_for(function()
      return vim.api.nvim_win_get_cursor(0)[1] == 3
    end)
    local following_window = vim.api.nvim_get_current_win()
    vim.cmd("split")
    local paused_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(paused_window, { 1, 0 })
    callbacks.on_stdout(12345, { "FATAL fourth", "" })
    wait_for(function()
      return vim.api.nvim_win_get_cursor(following_window)[1] == 4
    end)
    equal(1, vim.api.nvim_win_get_cursor(paused_window)[1])
    equal(buffer, vim.api.nvim_win_get_buf(paused_window))
    vim.api.nvim_win_close(paused_window, true)
  end)
end)

test("stream filtering keeps following the last matching entry", function()
  fake_stream(function(buffer, callbacks)
    logview.filter("ERROR")
    callbacks.on_stdout(12345, { "INFO hidden", "ERROR first", "traceback", "WARN hidden", "" })
    wait_for(function()
      return vim.api.nvim_win_get_cursor(0)[1] == 3
    end)
    callbacks.on_stdout(12345, { "hidden continuation", "FATAL second", "fatal frame", "INFO hidden", "" })
    wait_for(function()
      return vim.api.nvim_win_get_cursor(0)[1] == 7
    end)
    equal(4, logview.filter("ERROR"))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    callbacks.on_stdout(12345, { "ERROR third", "" })
    wait_for(function()
      return vim.api.nvim_buf_line_count(buffer) == 9
    end)
    equal(2, vim.api.nvim_win_get_cursor(0)[1])
    vim.cmd("normal! G")
    callbacks.on_stdout(12345, { "INFO hidden at end", "" })
    wait_for(function()
      return vim.api.nvim_buf_line_count(buffer) == 10
    end)
    vim.wait(20, function()
      return false
    end)
    equal(9, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)

test("incremental filtering avoids reparsing preceding visible entries", function()
  local lines = {}
  for index = 1, 200 do
    lines[index] = "ERROR entry " .. index
  end
  local buffer = filter_buffer(lines)
  logview.filter("ERROR")
  local original_parse = parser.parse
  local parsed = 0
  parser.parse = function(line)
    parsed = parsed + 1
    return original_parse(line)
  end
  local ok, err = pcall(function()
    -- Disable rendering so only the filter contributes parser calls.
    vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace("logview"), {})
    vim.api.nvim_buf_set_lines(buffer, -1, -1, false, { "INFO hidden", "continuation" })
    vim.wait(20, function()
      return false
    end)
    equal(2, parsed)
    equal(200, require("logview.filter").last_visible(buffer))
  end)
  parser.parse = original_parse
  logview.setup()
  logview.filter("ALL")
  if not ok then
    error(err)
  end
end)

test("real producer reports stderr and nonzero exit without losing stdout", function()
  local original_notify = vim.notify
  local notifications = {}
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message, level }
  end
  local window
  local ok, err = pcall(function()
    local buffer = stream.open({ "sh", "-c", "printf 'INFO ready\\nERROR final'; printf 'broken' >&2; exit 7" })
    window = vim.api.nvim_get_current_win()
    wait_for(function()
      return vim.b[buffer].logview_stream_exit_code == 7
    end)
    equal({ "INFO ready", "ERROR final" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    equal(false, vim.b[buffer].logview_stream_running)
    equal({
      { "LogStream stderr: broken", vim.log.levels.WARN },
      { "LogStream: command exited with code 7", vim.log.levels.ERROR },
    }, notifications)
  end)
  if window then
    close_stream_window(window)
  end
  vim.notify = original_notify
  if not ok then
    error(err)
  end
end)

test("successful finite commands retain their final partial line", function()
  local buffer = stream.open({ "sh", "-c", "printf 'INFO complete\\nERROR unterminated'" })
  local window = vim.api.nvim_get_current_win()
  wait_for(function()
    return vim.b[buffer].logview_stream_exit_code == 0
  end)
  equal(false, vim.b[buffer].logview_stream_running)
  equal({ "INFO complete", "ERROR unterminated" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  equal(false, pcall(stream.stop, buffer))
  close_stream_window(window)
end)

test("stop command and closing a buffer terminate real producers", function()
  for _, action in ipairs({ "stop", "close" }) do
    local buffer, job = stream.open({ "sh", "-c", "printf 'INFO ready\\n'; exec sleep 30" })
    local window = vim.api.nvim_get_current_win()
    wait_for(function()
      return vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1] == "INFO ready"
    end)
    if action == "stop" then
      vim.cmd("LogStreamStop")
      wait_for(function()
        return vim.b[buffer].logview_stream_running == false
      end)
      equal({ "INFO ready" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
      close_stream_window(window)
    else
      close_stream_window(window)
    end
    equal(true, vim.fn.jobwait({ job }, 2000)[1] ~= -1)
    equal(false, vim.api.nvim_buf_is_valid(buffer))
  end
end)

test("LogStream shell command tails a real growing file", function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "INFO initial" }, path)
  local window
  local ok, err = pcall(function()
    vim.cmd("LogStream tail -n 1 -f -s 0.05 " .. vim.fn.shellescape(path))
    local buffer = vim.api.nvim_get_current_buf()
    window = vim.api.nvim_get_current_win()
    wait_for(function()
      return vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1] == "INFO initial"
    end)
    logview.filter("ERROR")
    vim.fn.writefile({ "WARN hidden", "ERROR appended", "stack frame" }, path, "a")
    wait_for(function()
      return vim.api.nvim_buf_line_count(buffer) == 4
    end)
    wait_for(function()
      return require("logview.filter").last_visible(buffer) == 4
    end)
    equal(2, logview.filter("ERROR"))
    equal(false, vim.bo[buffer].modified)
    equal(false, vim.bo[buffer].modifiable)
    equal(true, vim.bo[buffer].readonly)
    vim.cmd("LogStreamStop")
    wait_for(function()
      return vim.b[buffer].logview_stream_running == false
    end)
  end)
  if window and vim.api.nvim_win_is_valid(window) then
    close_stream_window(window)
  end
  vim.fn.delete(path)
  if not ok then
    error(err)
  end
end)

test("stream startup errors do not open a split or discard current text", function()
  local buffer = vim.api.nvim_get_current_buf()
  local windows = #vim.api.nvim_list_wins()
  equal(false, pcall(stream.open, { "/definitely-missing-logview-command" }))
  equal(false, pcall(stream.open, " "))
  equal(false, pcall(stream.open, {}))
  equal(false, pcall(stream.stop))
  equal(buffer, vim.api.nvim_get_current_buf())
  equal(windows, #vim.api.nvim_list_wins())
end)

io.stdout:write(string.format("Passed %d tests\n", count))
vim.cmd("qa!")
