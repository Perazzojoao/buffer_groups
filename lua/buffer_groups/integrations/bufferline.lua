-- Optional integration with akinsho/bufferline.nvim.
--
-- This module is intentionally not required by buffer_groups' core. Call
-- extend() from the user's Bufferline setup to compose the adapter into a
-- Bufferline config.

local M = {}

local api = vim.api
local AUGROUP = "BufferGroupsBufferlineAdapter"

local function deepcopy(value)
  return vim.deepcopy(value)
end

local function safe_call(fn, ...)
  if type(fn) ~= "function" then
    return nil
  end
  local ok, result = pcall(fn, ...)
  if ok then
    return result
  end
  return nil
end

local function get_core(opts)
  if opts and opts.core then
    return opts.core
  end
  return require("buffer_groups")
end

local function get_enabled(core)
  if type(core.is_enabled) == "function" then
    return safe_call(core.is_enabled) == true
  end
  local state = safe_call(core.get_state)
  return type(state) == "table" and state.enabled == true or false
end

local function get_owner(core, bufnr, opts)
  if type(core.get_owner) ~= "function" then
    return nil
  end
  return safe_call(core.get_owner, bufnr, opts)
end

local function buffer_id(element)
  if type(element) == "number" then
    return element
  end
  if type(element) == "table" then
    return element.id or element.bufnr
  end
end

local function clean_group_id(name)
  return tostring(name or ""):gsub("[^%w]+", "_")
end

local function unique_group_names(items)
  local used = {}
  for _, item in ipairs(items) do
    if type(item) == "table" then
      if item.id ~= nil then
        used[tostring(item.id)] = true
      end
      if item.name ~= nil then
        used[clean_group_id(item.name)] = true
      end
    end
  end

  local function choose(base)
    local name = base
    local suffix = 1
    while used[clean_group_id(name)] do
      suffix = suffix + 1
      name = base .. " " .. suffix
    end
    used[clean_group_id(name)] = true
    return name
  end

  return choose("BufferGroups Left"), choose("BufferGroups Right")
end

local function run_bufferline_command(command, bufnr)
  if type(command) == "function" then
    command(bufnr)
  elseif type(command) == "string" then
    -- Bufferline schedules string commands. Keep that behavior, including its
    -- printf-style buffer number substitution.
    vim.schedule(function()
      vim.cmd(string.format(command, bufnr))
      vim.cmd("redrawtabline")
    end)
  end
end

local function native_open(bufnr)
  run_bufferline_command("buffer %d", bufnr)
end

local function native_close(bufnr)
  -- Bufferline's default close command is `bdelete! %d`.
  run_bufferline_command("bdelete! %d", bufnr)
end

local function host_sorter(sort_by, mode)
  if type(sort_by) == "function" then
    return sort_by
  end

  if sort_by == "none" or sort_by == false then
    return function(a, b)
      return (a.ordinal or 0) < (b.ordinal or 0)
    end
  elseif sort_by == "extension" then
    return function(a, b)
      return vim.fn.fnamemodify(a.name or "", ":e") < vim.fn.fnamemodify(b.name or "", ":e")
    end
  elseif sort_by == "directory" then
    return function(a, b)
      return vim.fn.fnamemodify(a.path or "", ":p") < vim.fn.fnamemodify(b.path or "", ":p")
    end
  elseif sort_by == "relative_directory" then
    return function(a, b)
      local path_a, path_b = a.path or "", b.path or ""
      local absolute_a = vim.fn.fnamemodify(path_a, ":p") ~= path_a
      local absolute_b = vim.fn.fnamemodify(path_b, ":p") ~= path_b
      if absolute_a and not absolute_b then
        return false
      end
      if absolute_b and not absolute_a then
        return true
      end
      return path_a < path_b
    end
  elseif sort_by == "tabs" then
    return function(a, b)
      if mode == "tabs" then
        return api.nvim_tabpage_get_number(a.id) < api.nvim_tabpage_get_number(b.id)
      end

      local function tab_rank(bufnr)
        local rank = 1000000000
        if #vim.fn.win_findbuf(bufnr) > 0 then
          rank = 0
        end
        for _, tab in ipairs(vim.fn.gettabinfo()) do
          local buffers = vim.fn.tabpagebuflist(tab.tabnr)
          if buffers ~= 0 then
            for _, visible_bufnr in ipairs(buffers) do
              if visible_bufnr == bufnr then
                rank = tab.tabnr
              end
            end
          end
        end
        return rank
      end
      return tab_rank(a.id) < tab_rank(b.id)
    end
  elseif sort_by == "insert_at_end" or sort_by == "insert_after_current" then
    return nil,
      "Bufferline sort_by='"
        .. sort_by
        .. "' depends on Bufferline's private render history; pass adapter_opts.managed_order=false to preserve it"
  elseif sort_by == nil or sort_by == "id" then
    return function(a, b)
      return a.id < b.id
    end
  end

  -- Bufferline leaves unknown sort modes in their incoming order.
  return function(a, b)
    return (a.ordinal or 0) < (b.ordinal or 0)
  end
end

local function make_snapshot_reader(core)
  local function state()
    return safe_call(core.get_state) or { enabled = false, active = false, groups = {}, owners = {} }
  end

  local function active()
    local snapshot = state()
    return get_enabled(core) and snapshot.enabled == true and snapshot.active == true
  end

  local function compare_owned(a, b)
    local snapshot = state()
    if not get_enabled(core) or snapshot.enabled ~= true or snapshot.active ~= true then
      return nil
    end

    for _, group in ipairs(snapshot.groups or {}) do
      local rank_a, rank_b
      for index, bufnr in ipairs(group.buffers or {}) do
        if bufnr == a then
          rank_a = index
        end
        if bufnr == b then
          rank_b = index
        end
      end
      if rank_a ~= nil and rank_b ~= nil then
        return rank_a < rank_b
      end
    end

    return nil
  end

  return { state = state, active = active, compare_owned = compare_owned }
end

local function add_owner_groups(groups_config, names, core, snapshots)
  local original_items = groups_config.items or {}
  local items = {}
  local owner_groups = {
    {
      name = names.left,
      matcher = function(element)
        local id = buffer_id(element)
        if not id or not snapshots.active() then
          return false
        end
        local owner = get_owner(core, id)
        return owner ~= nil and owner.side == "left"
      end,
    },
    {
      name = names.right,
      matcher = function(element)
        local id = buffer_id(element)
        if not id or not snapshots.active() then
          return false
        end
        local owner = get_owner(core, id)
        return owner ~= nil and owner.side == "right"
      end,
    },
  }

  for _, group in ipairs(owner_groups) do
    -- Keep generated ids stable and separate from user names. The visible
    -- group names remain human-readable and are made unique below.
    group.id = clean_group_id(group.name)
    items[#items + 1] = group
  end

  for _, original_group in ipairs(original_items) do
    local group = deepcopy(original_group)
    if type(group) == "table" and type(group.matcher) == "function" then
      local matcher = group.matcher
      group.matcher = function(element)
        local id = buffer_id(element)
        if id and snapshots.active() and get_owner(core, id) ~= nil then
          return false
        end
        return matcher(element)
      end
    end
    items[#items + 1] = group
  end

  groups_config.items = items
  return groups_config
end

local function compose_filter(original_filter)
  return function(bufnr, buf_numbers)
    if type(original_filter) == "function" and not original_filter(bufnr, buf_numbers) then
      return false
    end

    -- The owner matchers below query only the current tab. Unmanaged buffers
    -- and buffers owned in other tabs retain Bufferline's global visibility.
    return true
  end
end

local function compose_sorter(original_sort_by, snapshots, mode)
  local fallback, err = host_sorter(original_sort_by, mode)
  if not fallback then
    return nil, err
  end

  return function(a, b)
    local order = snapshots.compare_owned(a.id, b.id)
    if order ~= nil then
      return order
    end
    return fallback(a, b)
  end
end

local function compose_open_click(options, core)
  local original = options.left_mouse_command
  if original == false then
    return
  end
  if original ~= nil and type(original) ~= "function" and type(original) ~= "string" then
    return
  end

  options.left_mouse_command = function(bufnr)
    if get_enabled(core) and get_owner(core, bufnr) ~= nil then
      local ok, result = pcall(core.open, bufnr)
      if not ok or result == false then
        return
      end
      -- The core has already focused the existing owner. Bufferline's native
      -- `buffer %d` action would run later and can race a close or another
      -- transition, so only explicit host callbacks run afterward.
      if original == nil then
        return
      end
    end

    if original == nil then
      native_open(bufnr)
    else
      run_bufferline_command(original, bufnr)
    end
  end
end

local function compose_close(options, core)
  local original = options.close_command
  if original == false then
    return
  end
  if original ~= nil and type(original) ~= "function" and type(original) ~= "string" then
    return
  end

  options.close_command = function(bufnr)
    if get_enabled(core) then
      -- An explicit host close callback owns its semantics. With no host
      -- callback, route Bufferline's close affordance through the core.
      if original ~= nil then
        run_bufferline_command(original, bufnr)
      else
        safe_call(core.close, bufnr)
      end
    elseif original ~= nil then
      run_bufferline_command(original, bufnr)
    else
      native_close(bufnr)
    end
  end
end

local function install_refresh()
  local group = api.nvim_create_augroup(AUGROUP, { clear = true })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "BufferGroupsChanged",
    callback = function()
      -- Disable also changes the rendered groups, so refresh regardless of
      -- enabled state. Wrappers themselves check is_enabled before routing.
      vim.cmd("redrawtabline")
    end,
  })
end

---Compose BufferGroups behavior into a Bufferline configuration copy.
---
---Call this before `require("bufferline").setup(config)`. The adapter only
---uses BufferGroups' public API and can be loaded without Bufferline installed.
---Set `adapter_opts.managed_order = false` to keep Bufferline's native sorting
---when using `insert_after_current` or `insert_at_end`, which rely on private
---Bufferline render history.
---@param full_config table Bufferline user config (`{ options = ..., highlights = ... }`).
---@param adapter_opts? table Optional `{ core = api, managed_order = boolean }`.
---@return table config A deep copy of `full_config` with BufferGroups callbacks composed.
function M.extend(full_config, adapter_opts)
  assert(type(full_config) == "table", "bufferline config must be a table")

  local core = get_core(adapter_opts)
  local config = deepcopy(full_config)
  config.options = config.options or {}
  local options = config.options

  local snapshots = make_snapshot_reader(core)
  if options.mode ~= "tabs" then
    local groups_config = type(options.groups) == "table" and options.groups or {}
    groups_config = deepcopy(groups_config)
    groups_config.items = type(groups_config.items) == "table" and groups_config.items or {}
    local left_name, right_name = unique_group_names(groups_config.items)

    add_owner_groups(groups_config, { left = left_name, right = right_name }, core, snapshots)
    options.groups = groups_config

    local original_filter = options.custom_filter
    options.custom_filter = compose_filter(original_filter)

    if not (adapter_opts and adapter_opts.managed_order == false) then
      local sorter, err = compose_sorter(options.sort_by, snapshots, options.mode)
      assert(sorter, err)
      options.sort_by = sorter
    end
    compose_open_click(options, core)
    compose_close(options, core)
  end

  install_refresh()
  return config
end

return M
