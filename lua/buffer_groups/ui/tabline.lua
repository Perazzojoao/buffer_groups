-- Visibility ownership for the optional Bufferline tabline. Evaluate the real
-- renderer so custom areas and native tabpage indicators are preserved.
-- Sidebar offsets affect layout, but cannot keep an otherwise empty line visible.
local M = {}
local api = vim.api
local GROUP = "BufferGroupsTabline"
local EXPRESSION = "%!v:lua.nvim_bufferline()"
local predicate, renderer, wrapper, bufferline_config, saved
local queue, poller
local REFRESH_INTERVAL = 200
local queued = false
local generation = 0

local function controlled()
  return predicate ~= nil and _G.nvim_bufferline == wrapper and vim.o.tabline == EXPRESSION and predicate()
end

local function stop_polling()
  if poller then
    local timer = poller
    poller = nil
    timer:stop()
    timer:close()
  end
end

local function start_polling()
  if poller then
    return
  end
  local token = generation
  poller = assert(vim.uv.new_timer(), "could not create tabline refresh timer")
  poller:start(REFRESH_INTERVAL, REFRESH_INTERVAL, function()
    -- Timer callbacks run in a fast event. Only enqueue work on the main loop.
    if token == generation then
      queue()
    end
  end)
end

local function restore_options()
  local options = saved and saved.options
  if options and options.auto_toggle_bufferline == false then
    options.auto_toggle_bufferline = saved.auto_toggle
  end
end

local function live_options()
  -- Bufferline replaces this table when updating colorscheme highlights.
  return bufferline_config.options
end

local function claim_options(options)
  if saved.options ~= options then
    restore_options()
    saved.options, saved.auto_toggle = options, options.auto_toggle_bufferline
  elseif options.auto_toggle_bufferline ~= false then
    saved.auto_toggle = options.auto_toggle_bufferline
  end
  options.auto_toggle_bufferline = false
end

local function restore()
  stop_polling()
  if not saved then
    return
  end
  -- Restore only values still owned by this module. External edits take priority.
  if vim.o.showtabline == saved.applied then
    vim.o.showtabline = saved.showtabline
  end
  restore_options()
  saved = nil
end

local function render_content()
  local offset = require("bufferline.offset")
  local original_get = offset.get
  local captured
  local depth = 0
  local function capture(...)
    depth = depth + 1
    local ok, result = pcall(original_get, ...)
    depth = depth - 1
    if not ok then
      error(result, 0)
    end
    if depth == 0 and not captured and type(result) == "table" then
      -- Capture the outer render's exact fragments. Reusing the result avoids
      -- executing dynamic offset text callbacks a second time.
      captured = { left = result.left, right = result.right }
    end
    return result
  end
  offset.get = capture
  local ok, text = pcall(renderer)
  -- Restore before evaluating text or changing visibility, also on failure.
  if offset.get == capture then
    offset.get = original_get
  end
  if ok and type(text) == "string" and captured then
    local left, right = captured.left, captured.right
    if type(left) == "string" and left ~= "" and text:sub(1, #left) == left then
      text = text:sub(#left + 1)
    end
    if type(right) == "string" and right ~= "" and text:sub(-#right) == right then
      text = text:sub(1, #text - #right)
    end
  end
  -- Only the visibility probe loses offsets. Native rendering/state keeps them.
  return ok, text
end

local function refresh()
  if not controlled() then
    restore()
    return
  end
  if not saved then
    saved = { showtabline = vim.o.showtabline }
  elseif saved.applied ~= nil and vim.o.showtabline ~= saved.applied then
    saved.showtabline = vim.o.showtabline
  end
  claim_options(live_options())
  local ok, text = render_content()
  if not ok or type(text) ~= "string" then
    restore()
    return
  end
  local evaluated, result = pcall(api.nvim_eval_statusline, text, {
    use_tabline = true,
    maxwidth = vim.o.columns,
  })
  if not evaluated then
    restore()
    return
  end
  start_polling()
  local value = result.str:find("%S") and 2 or 0
  saved.applied = value
  if vim.o.showtabline ~= value then
    vim.o.showtabline = value
    vim.cmd("redrawtabline")
  end
end

queue = function()
  if queued then
    return
  end
  queued = true
  local token = generation
  vim.schedule(function()
    if token ~= generation then
      return
    end
    -- Keep the guard during rendering: the wrapper and OptionSet callbacks
    -- must not schedule an endless redraw/refresh loop.
    local ok, err = pcall(refresh)
    if not ok then
      restore()
      vim.notify("buffer_groups: tabline visibility unavailable: " .. tostring(err), vim.log.levels.WARN)
    end
    queued = false
  end)
end

function M.detach()
  generation = generation + 1
  queued = false
  api.nvim_create_augroup(GROUP, { clear = true })
  predicate = nil
  restore()
  if wrapper and _G.nvim_bufferline == wrapper then
    _G.nvim_bufferline = renderer
  end
  renderer, wrapper, bufferline_config = nil, nil, nil
end

function M.attach(should_control)
  M.detach()
  local config = require("bufferline.config")
  if type(_G.nvim_bufferline) ~= "function" or type(config.options) ~= "table" then
    return false, "Bufferline setup is incomplete"
  end
  predicate, renderer, bufferline_config = should_control, _G.nvim_bufferline, config
  local original = renderer
  wrapper = function()
    -- Rendering may run before the scheduled ownership update. Suppress the
    -- native count-based toggle for this call, without writing Neovim options in render.
    local managing = controlled()
    local options = live_options()
    if managing and saved then
      claim_options(options)
    end
    local native_toggle = options.auto_toggle_bufferline
    if managing then
      options.auto_toggle_bufferline = false
    end
    local ok, text, segments = pcall(original)
    if managing and options.auto_toggle_bufferline == false then
      options.auto_toggle_bufferline = native_toggle
    end
    if managing or saved then
      queue()
    end
    if not ok then
      error(text)
    end
    return text, segments
  end
  _G.nvim_bufferline = wrapper
  local group = api.nvim_create_augroup(GROUP, { clear = true })
  api.nvim_create_autocmd("User", { group = group, pattern = "BufferGroupsChanged", callback = queue })
  api.nvim_create_autocmd({
    "BufAdd",
    "BufDelete",
    "BufEnter",
    "BufFilePost",
    "BufModifiedSet",
    "WinEnter",
    "WinClosed",
    "TabEnter",
    "TabNew",
    "TabClosed",
    "VimResized",
    "WinResized",
    "DiagnosticChanged",
    "ColorScheme",
    "CursorMoved",
    "CursorMovedI",
  }, { group = group, callback = queue })
  api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "tabline", "showtabline" },
    callback = queue,
  })
  api.nvim_create_autocmd("VimLeavePre", { group = group, callback = stop_polling })
  queue()
  return true
end

return M
