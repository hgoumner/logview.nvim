local M = {}
local api = vim.api
local parser = require("logview.parser")
local filter = require("logview.filter")
local namespace = api.nvim_create_namespace("logview")
local enabled = {}
local initialized = false
local defaults = {
  auto = true,
  patterns = { "*.log" },
  error_background = 0.16,
}
local options = vim.deepcopy(defaults)

local function redraw()
  vim.cmd.redraw()
end

local function blend(foreground, background, opacity)
  local result = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local scale = 2 ^ shift
    local fg = math.floor(foreground / scale) % 256
    local bg = math.floor(background / scale) % 256
    result = result + math.floor(fg * opacity + bg * (1 - opacity) + 0.5) * scale
  end
  return result
end

local function highlights()
  local links = {
    Timestamp = "Special",
    TRACE = "Comment",
    DEBUG = "DiagnosticHint",
    INFO = "DiagnosticInfo",
    WARN = "DiagnosticWarn",
    ERROR = "DiagnosticError",
    FATAL = "DiagnosticError",
  }
  for name, target in pairs(links) do
    api.nvim_set_hl(0, "LogView" .. name, { default = true, link = target })
  end
  local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  local diagnostic = api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
  local background = normal.bg or (vim.o.background == "light" and 0xffffff or 0x1a1b26)
  api.nvim_set_hl(0, "LogViewErrorLine", {
    bg = blend(diagnostic.fg or 0xff5555, background, options.error_background),
  })
end

local function buffer_number(buffer)
  buffer = buffer or 0
  if buffer == 0 then
    buffer = api.nvim_get_current_buf()
  end
  if not api.nvim_buf_is_valid(buffer) or not api.nvim_buf_is_loaded(buffer) then
    error("LogView: expected a valid, loaded buffer")
  end
  return buffer
end

function M.is_enabled(buffer)
  return enabled[buffer_number(buffer)] == true
end

function M.enable(buffer)
  if not initialized then
    M.setup()
  end
  enabled[buffer_number(buffer)] = true
  redraw()
end

function M.disable(buffer)
  buffer = buffer_number(buffer)
  filter.clear(buffer)
  enabled[buffer] = false
  redraw()
end

function M.toggle(buffer)
  if M.is_enabled(buffer) then
    M.disable(buffer)
  else
    M.enable(buffer)
  end
end

---Show entries at or above a minimum level, or ALL to clear the filter.
---@param level string
---@param buffer? integer
function M.filter(level, buffer)
  buffer = buffer_number(buffer)
  if type(level) ~= "string" then
    error("LogView: filter level must be a string")
  end
  if level:upper() == "ALL" then
    filter.clear(buffer)
    return
  end
  local minimum = parser.normalize_level(level)
  if not minimum then
    error("LogView: expected TRACE, DEBUG, INFO, WARN, ERROR, FATAL or ALL")
  end
  local visible, total = filter.set(buffer, minimum)
  M.enable(buffer)
  return visible, total
end

local function auto_enable(buffer)
  if not options.auto or enabled[buffer] ~= nil or vim.bo[buffer].buftype ~= "" then
    return
  end
  local name = api.nvim_buf_get_name(buffer)
  for _, pattern in ipairs(options.patterns) do
    if vim.fn.match(name, vim.fn.glob2regpat(pattern)) >= 0 then
      enabled[buffer] = true
      return
    end
  end
end

local function decorate(_, _, buffer, top, bottom)
  if not enabled[buffer] then
    return false
  end
  -- on_win's bottom row is inclusive, unlike nvim_buf_get_lines.
  local lines = api.nvim_buf_get_lines(buffer, top, bottom + 1, false)
  for index, line in ipairs(lines) do
    local row = top + index - 1
    local spans, level = parser.parse(line)
    if options.error_background > 0 and (level == "ERROR" or level == "FATAL") then
      api.nvim_buf_set_extmark(buffer, namespace, row, 0, {
        hl_group = "LogViewErrorLine",
        end_row = row + 1,
        end_col = 0,
        hl_eol = true,
        priority = 90,
        ephemeral = true,
      })
    end
    for _, span in ipairs(spans) do
      api.nvim_buf_set_extmark(buffer, namespace, row, span.start_col, {
        end_col = span.end_col,
        hl_group = span.group,
        priority = 200,
        ephemeral = true,
      })
    end
  end
  return false
end

---Configure the plugin. Safe to call again; explicit per-buffer choices survive.
---@param opts? {auto?: boolean, patterns?: string[], error_background?: number}
function M.setup(opts)
  local config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  vim.validate({
    auto = { config.auto, "boolean" },
    patterns = { config.patterns, "table" },
    error_background = { config.error_background, "number" },
  })
  if config.error_background < 0 or config.error_background > 1 then
    error("LogView: error_background must be between 0 and 1")
  end
  if not vim.islist(config.patterns) then
    error("LogView: patterns must be a list of filename globs")
  end
  for _, pattern in ipairs(config.patterns) do
    if type(pattern) ~= "string" or pattern == "" then
      error("LogView: patterns must contain non-empty filename globs")
    end
  end
  options = config
  initialized = true
  vim.g.loaded_logview = true
  highlights()
  api.nvim_set_decoration_provider(namespace, { on_win = decorate })
  local group = api.nvim_create_augroup("LogView", { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufFilePost" }, {
    group = group,
    callback = function(event)
      auto_enable(event.buf)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      enabled[event.buf] = nil
    end,
  })
  api.nvim_create_user_command("LogView", function(command)
    local action = command.args == "" and "on" or command.args
    if action == "on" then
      M.enable()
    elseif action == "off" then
      M.disable()
    elseif action == "toggle" then
      M.toggle()
    else
      api.nvim_err_writeln("LogView: use :LogView [on|off|toggle]")
    end
  end, {
    nargs = "?",
    complete = function(prefix)
      return vim.tbl_filter(function(action)
        return action:sub(1, #prefix) == prefix
      end, { "on", "off", "toggle" })
    end,
    desc = "Highlight log timestamps and levels in the current buffer",
  })
  api.nvim_create_user_command("LogFilter", function(command)
    local visible, total = M.filter(command.args)
    if visible then
      vim.notify(
        string.format("LogView: %s+ (%d of %d lines)", parser.normalize_level(command.args), visible, total),
        visible == 0 and vim.log.levels.WARN or vim.log.levels.INFO
      )
    end
  end, {
    nargs = 1,
    complete = function(prefix)
      return vim.tbl_filter(function(level)
        return level:sub(1, #prefix) == prefix:upper()
      end, { "TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL", "ALL" })
    end,
    desc = "Filter log entries by minimum severity; ALL restores every line",
  })
  api.nvim_create_user_command("LogStream", function(command)
    require("logview.stream").open(command.args)
  end, {
    nargs = "+",
    complete = "shellcmd",
    desc = "Stream command stdout into a highlighted log buffer",
  })
  api.nvim_create_user_command("LogStreamStop", function()
    require("logview.stream").stop()
  end, {
    desc = "Stop the current log stream, keeping its captured output",
  })
  -- Let plugin managers apply their opts before activating existing buffers.
  vim.schedule(function()
    for _, buffer in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(buffer) then
        auto_enable(buffer)
      end
    end
    redraw()
  end)
end

return M
