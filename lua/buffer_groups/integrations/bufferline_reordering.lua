-- Optional Bufferline 4.9.1 boundary. Group membership/order belongs to core;
-- native command routing and custom_sort reconciliation belong to this adapter.
local M = {}
local api = vim.api
local GROUP = "BufferGroupsBufferlineReordering"
local connection
local hooks = {}
local syncing = false

local function valid(buf)
  return type(buf) == "number" and api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted
end

local function active()
  local c = connection
  local options = c and c.config.options
  return c ~= nil and c.managed_order and type(options) == "table" and options.mode ~= "tabs"
end

local function enabled()
  return active() and connection.core.is_reordering_enabled()
end

local function owned_current()
  return enabled() and connection.core.get_owner(api.nvim_get_current_buf()) ~= nil
end

-- Bufferline bypasses options.sort_by whenever custom_sort exists. Replace only
-- this tab's owned slots; foreign buffers retain their relative manual order.
function M.sync()
  if syncing or not enabled() then
    return
  end
  local c = connection
  local previous = c.state.custom_sort
  if type(previous) ~= "table" then
    return
  end
  syncing = true
  local ok, err = pcall(function()
    local snapshot = c.core.get_state()
    local ordered, owned, present = {}, {}, {}
    for _, group in ipairs(snapshot.groups) do
      for _, buf in ipairs(group.buffers) do
        if valid(buf) then
          ordered[#ordered + 1], owned[buf] = buf, true
        end
      end
    end
    local merged, seen_input, cursor = {}, {}, 1
    for _, buf in ipairs(previous) do
      if valid(buf) and not seen_input[buf] then
        seen_input[buf] = true
        if owned[buf] then
          local replacement = ordered[cursor]
          if replacement then
            merged[#merged + 1], present[replacement] = replacement, true
            cursor = cursor + 1
          end
        else
          merged[#merged + 1], present[buf] = buf, true
        end
      end
    end
    for i = cursor, #ordered do
      local buf = ordered[i]
      if not present[buf] then
        merged[#merged + 1], present[buf] = buf, true
      end
    end
    if not vim.deep_equal(previous, merged) then
      -- Native move/sort writes a raw field on the exported state module.
      -- state.set() only updates its backing table and cannot replace that field.
      c.state.custom_sort = merged
    end
  end)
  syncing = false
  if not ok then
    M.detach()
    vim.notify("buffer_groups: Bufferline reordering unavailable: " .. tostring(err), vim.log.levels.WARN)
  end
end

local function hook(module, name, operation)
  local original = module[name]
  local owner = connection
  local wrapper = function(...)
    if connection == owner and owned_current() then
      local ok, result = operation(...)
      if not ok then
        vim.notify("buffer_groups: " .. tostring(result), vim.log.levels.WARN)
      end
      return ok, result
    end
    return original(...)
  end
  module[name] = wrapper
  hooks[#hooks + 1] = { module = module, name = name, original = original, wrapper = wrapper }
end

function M.detach()
  local previous = connection
  connection = nil
  api.nvim_create_augroup(GROUP, { clear = true })
  for i = #hooks, 1, -1 do
    local h = hooks[i]
    if h.module[h.name] == h.wrapper then
      h.module[h.name] = h.original
    end
  end
  hooks = {}
  if previous then
    previous.core._set_reorder_adapter(nil)
  end
end

function M.attach(core, managed_order)
  M.detach()
  if not managed_order then
    if core.get_reordering_options().enabled then
      return false, "reordering requires managed_order=true"
    end
    return true
  end
  local ok, modules = pcall(function()
    local m = {
      bufferline = require("bufferline"),
      commands = require("bufferline.commands"),
      config = require("bufferline.config"),
      state = require("bufferline.state"),
      ui = require("bufferline.ui"),
    }
    assert(type(m.config.options) == "table" and m.config.options.mode ~= "tabs", "requires mode='buffers'")
    assert(type(m.state.set) == "function", "missing Bufferline state setter")
    assert(type(m.ui.refresh) == "function", "missing native refresh API")
    for _, module in ipairs({ m.bufferline, m.commands }) do
      assert(type(module.move) == "function" and type(module.move_to) == "function", "missing native movement API")
    end
    return m
  end)
  if not ok then
    return false, "unsupported Bufferline reordering: " .. tostring(modules)
  end
  connection = { core = core, config = modules.config, state = modules.state, managed_order = true }
  for _, module in ipairs({ modules.bufferline, modules.commands }) do
    hook(module, "move", function(delta)
      return core.reorder(delta)
    end)
    hook(module, "move_to", function(index, from_index)
      return core.reorder_to(index, { from_index = from_index })
    end)
  end
  local group = api.nvim_create_augroup(GROUP, { clear = true })
  api.nvim_create_autocmd("User", { group = group, pattern = "BufferGroupsChanged", callback = M.sync })
  -- Native movement of an unmanaged buffer can also update custom_sort.
  -- Reconcile before the next scheduled draw without imposing a new sort mode.
  local ui = modules.ui
  local original_refresh = ui.refresh
  local owner = connection
  local wrapper = function(...)
    if connection == owner then
      M.sync()
    end
    return original_refresh(...)
  end
  ui.refresh = wrapper
  hooks[#hooks + 1] = { module = ui, name = "refresh", original = original_refresh, wrapper = wrapper }
  core._set_reorder_adapter({ is_active = active })
  M.sync()
  return true
end

return M
