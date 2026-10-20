local M = {}
local api = vim.api
local filter = require("logview.filter")
local streams = {}
local serial = 0
local initialized = false

local function stop(buffer)
  local state = streams[buffer]
  if state and state.job and not state.exited and not state.stopping then
    state.stopping = true
    vim.fn.jobstop(state.job)
  end
end

local function append(buffer, state, data)
  if data == "" then
    return
  end
  local following = {}
  local last = filter.last_visible(buffer)
  for _, window in ipairs(vim.fn.win_findbuf(buffer)) do
    if last == 0 or api.nvim_win_get_cursor(window)[1] >= last then
      local bottom = api.nvim_win_call(window, function()
        return vim.fn.line("w$")
      end)
      if bottom >= last then
        following[#following + 1] = window
      end
    end
  end
  local lines = vim.split(state.partial .. data, "\n", { plain = true })
  state.partial = lines[#lines]
  local complete = #lines - 1
  if state.partial == "" then
    table.remove(lines)
  end
  for index, line in ipairs(lines) do
    lines[index] = line:gsub("\r$", "")
  end
  vim.bo[buffer].readonly = false
  vim.bo[buffer].modifiable = true
  local ok, err = pcall(api.nvim_buf_set_lines, buffer, state.completed, -1, false, lines)
  vim.bo[buffer].modified = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].readonly = true
  if not ok then
    stop(buffer)
    error("LogStream: could not append stdout: " .. tostring(err))
  end
  state.completed = state.completed + complete
  -- Buffer listeners schedule filtering first, so follow its updated view.
  vim.schedule(function()
    if not api.nvim_buf_is_loaded(buffer) then
      return
    end
    local target = filter.last_visible(buffer)
    for _, window in ipairs(following) do
      if target > 0 and api.nvim_win_is_valid(window) and api.nvim_win_get_buf(window) == buffer then
        api.nvim_win_set_cursor(window, { target, 0 })
        api.nvim_win_call(window, function()
          vim.cmd("normal! zb")
        end)
      end
    end
  end)
end

local function schedule_flush(buffer, state)
  if state.pending then
    return
  end
  state.pending = true
  vim.schedule(function()
    state.pending = false
    if streams[buffer] ~= state or not api.nvim_buf_is_loaded(buffer) then
      return
    end
    local output = table.concat(state.stdout)
    state.stdout = {}
    append(buffer, state, output)
    local errors = state.stderr_partial .. table.concat(state.stderr)
    state.stderr = {}
    local boundary = errors:match(".*()\n")
    local message
    if state.exited then
      message, state.stderr_partial = errors, ""
    elseif boundary then
      message, state.stderr_partial = errors:sub(1, boundary), errors:sub(boundary + 1)
    else
      state.stderr_partial = errors
    end
    if message and vim.trim(message) ~= "" then
      vim.notify("LogStream stderr: " .. vim.trim(message), vim.log.levels.WARN)
    end
    if state.exited then
      vim.b[buffer].logview_stream_running = false
      vim.b[buffer].logview_stream_exit_code = state.exit_code
      if not state.reported then
        state.reported = true
        if state.exit_code ~= 0 and not state.stopping then
          vim.notify("LogStream: command exited with code " .. state.exit_code, vim.log.levels.ERROR)
        end
      end
    end
  end)
end

local function setup()
  if initialized then
    return
  end
  initialized = true
  local group = api.nvim_create_augroup("LogViewStream", { clear = true })
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    callback = function(event)
      stop(event.buf)
      streams[event.buf] = nil
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for buffer in pairs(streams) do
        stop(buffer)
      end
    end,
  })
end

---Run a shell command (or argv list) in a dedicated, non-terminal log buffer.
function M.open(command)
  if type(command) == "string" then
    if vim.trim(command) == "" then
      error("LogStream: expected a command")
    end
  elseif type(command) == "table" and vim.islist(command) and #command > 0 then
    for _, argument in ipairs(command) do
      if type(argument) ~= "string" then
        error("LogStream: command arguments must be strings")
      end
    end
  else
    error("LogStream: expected a shell command or non-empty argv list")
  end
  setup()
  serial = serial + 1
  local buffer = api.nvim_create_buf(true, true)
  api.nvim_buf_set_name(buffer, "logview://stream/" .. serial)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].undolevels = -1
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].readonly = true
  local state = {
    stdout = {},
    stderr = {},
    stderr_partial = "",
    partial = "",
    completed = 0,
  }
  streams[buffer] = state
  local ok, job = pcall(vim.fn.jobstart, command, {
    stdin = "null",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      state.stdout[#state.stdout + 1] = table.concat(data, "\n")
      schedule_flush(buffer, state)
    end,
    on_stderr = function(_, data)
      state.stderr[#state.stderr + 1] = table.concat(data, "\n")
      schedule_flush(buffer, state)
    end,
    on_exit = function(_, code)
      state.exited = true
      state.exit_code = code
      schedule_flush(buffer, state)
    end,
  })
  if not ok or job <= 0 then
    streams[buffer] = nil
    api.nvim_buf_delete(buffer, { force = true })
    error("LogStream: could not start command: " .. tostring(job))
  end
  state.job = job
  vim.b[buffer].logview_stream_job = job
  vim.b[buffer].logview_stream_running = true
  vim.b[buffer].logview_stream_command = command
  local previous = api.nvim_get_current_buf()
  local previous_bufhidden = vim.bo[previous].bufhidden
  if vim.bo[previous].buftype == "" then
    vim.bo[previous].bufhidden = "hide"
  end
  local displayed, display_error = pcall(api.nvim_win_set_buf, 0, buffer)
  if api.nvim_buf_is_valid(previous) then
    vim.bo[previous].bufhidden = previous_bufhidden
  end
  if not displayed then
    stop(buffer)
    streams[buffer] = nil
    api.nvim_buf_delete(buffer, { force = true })
    error("LogStream: could not display stream: " .. tostring(display_error))
  end
  require("logview").enable(buffer)
  return buffer, job
end

function M.stop(buffer)
  if buffer == nil or buffer == 0 then
    buffer = api.nvim_get_current_buf()
  end
  local state = streams[buffer]
  if not state or state.exited or state.stopping then
    error("LogStream: no running stream in this buffer")
  end
  stop(buffer)
end

return M
