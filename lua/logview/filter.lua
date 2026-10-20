local M = {}
local api = vim.api
local parser = require("logview.parser")
local namespace = api.nvim_create_namespace("logview-filter")
local filters = {}
local attached = {}
local windows = {}
local initialized = false

local function restore_window(window)
  local saved = windows[window]
  if saved and api.nvim_win_is_valid(window) then
    vim.wo[window].conceallevel = saved.conceallevel
    vim.wo[window].concealcursor = saved.concealcursor
  end
  windows[window] = nil
end

local function sync_windows()
  for window in pairs(windows) do
    if not api.nvim_win_is_valid(window) or api.nvim_win_get_buf(window) ~= windows[window].buffer then
      restore_window(window)
    end
  end
  for _, window in ipairs(api.nvim_list_wins()) do
    local buffer = api.nvim_win_get_buf(window)
    if filters[buffer] then
      if not windows[window] then
        local conceallevel = vim.wo[window].conceallevel
        local concealcursor = vim.wo[window].concealcursor
        -- A new split inherits the filter's options, not the original ones.
        if conceallevel == 3 and concealcursor == "nvic" then
          for _, saved in pairs(windows) do
            if saved.buffer == buffer then
              conceallevel = saved.conceallevel
              concealcursor = saved.concealcursor
              break
            end
          end
        end
        windows[window] = {
          buffer = buffer,
          conceallevel = conceallevel,
          concealcursor = concealcursor,
        }
      end
      vim.wo[window].conceallevel = 3
      vim.wo[window].concealcursor = "nvic"
    elseif windows[window] then
      restore_window(window)
    end
  end
end

local function refresh(buffer)
  local state = filters[buffer]
  if not state or not api.nvim_buf_is_loaded(buffer) then
    return
  end
  local first = state.dirty or 0
  -- Rebuild an overlapping concealed range from its original start.
  while first > 0 and state.keep[first] == false do
    first = first - 1
  end
  local visible = state.counts[first] or 0
  local first_visible = state.first_visible
  if first_visible and first_visible > first then
    first_visible = nil
  end
  local last_visible = first
  while last_visible > 0 and not state.keep[last_visible] do
    last_visible = last_visible - 1
  end
  local keep = state.keep[first] or false
  local hidden_start
  local lines = api.nvim_buf_get_lines(buffer, first, -1, false)
  api.nvim_buf_clear_namespace(buffer, namespace, first, -1)
  for index = #state.keep, first + 1, -1 do
    state.keep[index] = nil
    state.counts[index] = nil
  end
  local function hide(last)
    if hidden_start then
      api.nvim_buf_set_extmark(buffer, namespace, hidden_start, 0, {
        end_row = last - 1,
        end_col = #lines[last - first],
        conceal_lines = "",
      })
      hidden_start = nil
    end
  end
  for index, line in ipairs(lines) do
    local row = first + index
    local _, level = parser.parse(line)
    if level then
      keep = parser.meets_level(level, state.minimum)
    end
    if keep then
      hide(row - 1)
      visible = visible + 1
      first_visible = first_visible or row
      last_visible = row
    else
      hidden_start = hidden_start or row - 1
    end
    state.keep[row] = keep
    state.counts[row] = visible
  end
  hide(first + #lines)
  state.visible = visible
  state.total = first + #lines
  state.first_visible = first_visible
  state.last_visible = last_visible
  state.dirty = nil
  sync_windows()
  if first_visible then
    for window, saved in pairs(windows) do
      if saved.buffer == buffer then
        -- A cursor left on a concealed line makes navigation confusing.
        local row = api.nvim_win_get_cursor(window)[1]
        local hidden = api.nvim_buf_get_extmarks(buffer, namespace, { row - 1, 0 }, { row - 1, 0 }, {
          overlap = true,
          details = true,
        })
        if #hidden > 0 then
          api.nvim_win_set_cursor(window, { first_visible, 0 })
        end
      end
    end
  end
  vim.cmd.redraw()
end

local function schedule_refresh(buffer, first)
  local state = filters[buffer]
  if not state then
    return
  end
  state.dirty = math.min(state.dirty or first, first)
  if state.pending then
    return
  end
  state.pending = true
  vim.schedule(function()
    if filters[buffer] == state then
      state.pending = false
      refresh(buffer)
    end
  end)
end

function M.last_visible(buffer)
  local state = filters[buffer]
  return state and state.last_visible or api.nvim_buf_line_count(buffer)
end

function M.clear(buffer)
  filters[buffer] = nil
  if api.nvim_buf_is_valid(buffer) then
    api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  end
  sync_windows()
  vim.cmd.redraw()
end

local function setup()
  if initialized then
    return
  end
  initialized = true
  local group = api.nvim_create_augroup("LogViewFilter", { clear = true })
  api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "BufEnter" }, {
    group = group,
    callback = sync_windows,
  })
  api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    callback = function()
      restore_window(api.nvim_get_current_win())
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      windows[tonumber(event.match)] = nil
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      filters[event.buf] = nil
      attached[event.buf] = nil
      sync_windows()
    end,
  })
end

function M.set(buffer, minimum)
  if vim.fn.has("nvim-0.11") == 0 then
    error("LogView: filtering requires Neovim 0.11 or newer")
  end
  setup()
  if not attached[buffer] then
    local ok = api.nvim_buf_attach(buffer, false, {
      on_lines = function(_, changed_buffer, _, first)
        schedule_refresh(changed_buffer, first)
      end,
      on_reload = function(_, changed_buffer)
        schedule_refresh(changed_buffer, 0)
      end,
      on_detach = function(_, detached_buffer)
        attached[detached_buffer] = nil
        local state = filters[detached_buffer]
        vim.schedule(function()
          if filters[detached_buffer] == state then
            M.clear(detached_buffer)
          end
        end)
      end,
    })
    if not ok then
      error("LogView: could not watch the buffer for filter updates")
    end
    attached[buffer] = true
  end
  filters[buffer] = { minimum = minimum, keep = {}, counts = {} }
  refresh(buffer)
  return filters[buffer].visible, filters[buffer].total
end

return M
