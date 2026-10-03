local root = vim.env.BG_TEST_ROOT or vim.env.BUFFER_GROUPS_ROOT or "/tmp/buffer-groups-work.x66mah"
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local api = vim.api
local adapter = require("buffer_groups.integrations.bufferline")

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
  end
end

local function truthy(value, message)
  if not value then
    error(message or "expected a truthy value")
  end
end

eq(package.loaded.bufferline, nil, "loading the adapter does not load Bufferline")

-- Two tabs let the filter prove that owner buffers stay with their tab.
vim.cmd("tabnew")
local tabs = api.nvim_list_tabpages()
local current_tab = api.nvim_get_current_tabpage()
local other_tab = tabs[1] == current_tab and tabs[2] or tabs[1]

local enabled = true
local other_tab_owner_queries = 0
local owners = {
  [101] = { id = 1, side = "left", buffers = { 101, 102 } },
  [102] = { id = 1, side = "left", buffers = { 101, 102 } },
  [103] = { id = 2, side = "right", buffers = { 103 } },
  [104] = { id = 3, side = "left", buffers = { 104 } },
}
local state = {
  enabled = true,
  active = true,
  tabpage = current_tab,
  groups = {
    { id = 1, win = 11, side = "left", buffers = { 102, 101 } },
    { id = 2, win = 12, side = "right", buffers = { 103 } },
  },
  owners = { [101] = 1, [102] = 1, [103] = 2 },
}
local calls = { open = {}, close = {}, clicks = {}, commands = {}, host_filters = 0, host_sorts = 0 }
local core = {
  is_enabled = function()
    return enabled
  end,
  get_state = function()
    return vim.deepcopy(state)
  end,
  get_owner = function(bufnr, opts)
    opts = opts or {}
    if opts.tabpage == other_tab then
      other_tab_owner_queries = other_tab_owner_queries + 1
      if bufnr == 104 then
        return vim.deepcopy(owners[104])
      end
      return nil
    end
    if bufnr == 104 then
      return nil
    end
    return owners[bufnr] and vim.deepcopy(owners[bufnr]) or nil
  end,
  open = function(bufnr)
    calls.open[#calls.open + 1] = bufnr
    return true, { focused = true }
  end,
  close = function(bufnr)
    calls.close[#calls.close + 1] = bufnr
    return true
  end,
}

local base_config = {
  highlights = { fill = { bg = "#000000" } },
  options = {
    custom_filter = function(bufnr)
      calls.host_filters = calls.host_filters + 1
      return bufnr ~= 999
    end,
    sort_by = function(a, b)
      calls.host_sorts = calls.host_sorts + 1
      return a.id > b.id
    end,
    groups = {
      options = { toggle_hidden_on_enter = false },
      items = {
        {
          name = "Files",
          matcher = function()
            return true
          end,
        },
      },
    },
    left_mouse_command = function(bufnr)
      calls.clicks[#calls.clicks + 1] = bufnr
    end,
    close_command = function(bufnr)
      calls.host_close = bufnr
    end,
    mode = "buffers",
    show_buffer_icons = false,
  },
}
local original_filter = base_config.options.custom_filter
local original_sort = base_config.options.sort_by
local original_group_matcher = base_config.options.groups.items[1].matcher
local original_click = base_config.options.left_mouse_command
local original_close = base_config.options.close_command

local extended = adapter.extend(base_config, { core = core })
truthy(extended ~= base_config, "extend returns a new config")
truthy(extended.options ~= base_config.options, "options are copied")
eq(#base_config.options.groups.items, 1, "source groups are untouched")
eq(extended.options.mode, "buffers", "other options survive")
eq(extended.options.show_buffer_icons, false, "false options survive")
eq(extended.highlights.fill.bg, "#000000", "highlights survive")
eq(extended.options.groups.options.toggle_hidden_on_enter, false, "group options survive")
eq(#extended.options.groups.items, 3, "owner groups are composed before host groups")
eq(base_config.options.custom_filter, original_filter, "source filter is unchanged")
eq(base_config.options.sort_by, original_sort, "source sorter is unchanged")
eq(base_config.options.groups.items[1].matcher, original_group_matcher, "source group matcher is unchanged")
eq(base_config.options.left_mouse_command, original_click, "source click callback is unchanged")
eq(base_config.options.close_command, original_close, "source close callback is unchanged")

local left_group, right_group, host_group = unpack(extended.options.groups.items)
truthy(left_group.name:match("BufferGroups Left"), "left owner group is first")
truthy(right_group.name:match("BufferGroups Right"), "right owner group is second")
eq(left_group.matcher({ id = 101 }), true, "left owner matcher")
eq(right_group.matcher({ id = 103 }), true, "right owner matcher")
eq(left_group.matcher({ id = 101 }), true, "owner groups stay active on repeat matching")
eq(host_group.matcher({ id = 101 }), false, "owner matchers take precedence over host groups")
eq(host_group.matcher({ id = 200 }), true, "host group matcher still handles unmanaged buffers")

local filter = extended.options.custom_filter
eq(filter(101, { 101, 102, 103, 104 }), true, "current-tab owner is visible")
eq(filter(104, { 101, 102, 103, 104 }), true, "other-tab buffers keep Bufferline's global visibility")
eq(other_tab_owner_queries, 0, "the adapter does not initialize or query other tabs")
eq(filter(999, { 101, 102, 103, 104, 999 }), false, "host filter still excludes buffers")
truthy(calls.host_filters >= 3, "host filter is called for each candidate")

local throwing_filter = adapter.extend({
  options = {
    custom_filter = function()
      error("host filter failure")
    end,
  },
}, { core = core }).options.custom_filter
local filter_ok, filter_error = pcall(throwing_filter, 101, { 101 })
eq(filter_ok, false, "host filter exceptions are not swallowed")
truthy(tostring(filter_error):match("host filter failure"), "host filter error is preserved")

local comparator = extended.options.sort_by
eq(comparator({ id = 102 }, { id = 101 }), true, "owned buffers follow core group order")
eq(comparator({ id = 101 }, { id = 102 }), false, "owned order is stable")
eq(comparator({ id = 201 }, { id = 202 }), false, "host sorter handles unmanaged buffers")
truthy(calls.host_sorts > 0, "host sorter is composed")

-- Returning to one owner keeps its cycle order even though Left/Right labels
-- disappear. Externals must not make the combined comparator non-transitive.
local partitioned_state = vim.deepcopy(state)
state.active = false
state.groups = { { id = 1, win = 11, side = "single", buffers = { 101, 103, 102 } } }
eq(left_group.matcher({ id = 101 }), false, "single owner does not retain a Left label")
eq(right_group.matcher({ id = 103 }), false, "single owner does not retain a Right label")
eq(comparator({ id = 101 }, { id = 103 }), true, "single owner keeps core order instead of host sorting")
eq(comparator({ id = 103 }, { id = 101 }), false, "single owner reverse comparison keeps core order")
eq(comparator({ id = 102 }, { id = 104 }), true, "owned buffers precede other-tab buffers")
eq(comparator({ id = 104 }, { id = 102 }), false, "other-tab buffers follow owned buffers")

local elements = { { id = 100 }, { id = 101 }, { id = 102 }, { id = 103 }, { id = 104 } }
for _, a in ipairs(elements) do
  eq(comparator(a, a), false, "comparator is irreflexive")
  for _, b in ipairs(elements) do
    if comparator(a, b) then
      eq(comparator(b, a), false, "comparator is asymmetric")
      for _, c in ipairs(elements) do
        if comparator(b, c) then
          eq(comparator(a, c), true, "owned and host ordering compose transitively")
        end
      end
    end
  end
end
for offset = 1, #elements do
  local reordered = {}
  for index = 1, #elements do
    reordered[index] = elements[(index + offset - 2) % #elements + 1]
  end
  table.sort(reordered, comparator)
  eq(
    table.concat(
      vim.tbl_map(function(element)
        return element.id
      end, reordered),
      ","
    ),
    "101,103,102,104,100",
    "input order cannot change the result; host descending order survives between externals"
  )
end

enabled = false
eq(comparator({ id = 101 }, { id = 103 }), false, "disabled core restores host sorting")
enabled = true
state.enabled = false
eq(comparator({ id = 101 }, { id = 103 }), false, "disabled snapshot restores host sorting")
state = partitioned_state

local extension_sort = adapter.extend({ options = { sort_by = "extension" } }, { core = core }).options.sort_by
eq(
  extension_sort({ id = 501, name = "a.z" }, { id = 502, name = "z.a" }),
  false,
  "extension sort follows Bufferline's extension comparison"
)
local unsupported_sort_ok, unsupported_sort_error = pcall(function()
  adapter.extend({ options = { sort_by = "insert_after_current" } }, { core = core })
end)
eq(unsupported_sort_ok, false, "context-dependent host sort is rejected by default")
truthy(tostring(unsupported_sort_error):match("managed_order=false"), "unsupported sort error gives an opt-out")
local preserved_insert = adapter.extend({
  options = { sort_by = "insert_after_current" },
}, { core = core, managed_order = false })
eq(preserved_insert.options.sort_by, "insert_after_current", "managed_order=false keeps Bufferline sorting")
local tabline_config = adapter.extend(
  { options = { mode = "tabs", sort_by = "insert_after_current" } },
  { core = core }
)
eq(tabline_config.options.mode, "tabs", "tabline mode is preserved")
eq(tabline_config.options.custom_filter, nil, "tabline mode is not treated as buffer ownership")

extended.options.left_mouse_command(101)
eq(calls.open[1], 101, "owner click opens through the core")
eq(calls.clicks[1], 101, "owner click then invokes host callback")
extended.options.left_mouse_command(200)
eq(calls.clicks[2], 200, "unmanaged click invokes host callback")
extended.options.close_command(101)
eq(calls.host_close, 101, "host close callback is preserved")
eq(#calls.close, 0, "host close callback bypasses core close")

local config_without_close = adapter.extend({ options = {} }, { core = core })
config_without_close.options.close_command(102)
eq(calls.close[1], 102, "default close routes through the core")

local original_cmd_for_open, original_schedule_for_open = vim.cmd, vim.schedule
vim.cmd = function(command)
  calls.commands[#calls.commands + 1] = command
end
vim.schedule = function(callback)
  callback()
end
local config_without_click = adapter.extend({ options = {} }, { core = core })
local command_count = #calls.commands
config_without_click.options.left_mouse_command(101)
eq(calls.open[#calls.open], 101, "default owner click opens through the core")
eq(#calls.commands, command_count, "successful core open does not schedule a duplicate native open")
vim.cmd, vim.schedule = original_cmd_for_open, original_schedule_for_open

local refusing_core = vim.tbl_extend("force", {}, core, {
  close = function()
    return false, "refused"
  end,
})
local refused_close = adapter.extend({ options = {} }, { core = refusing_core })
local original_cmd_for_close, original_schedule_for_close = vim.cmd, vim.schedule
vim.cmd = function(command)
  calls.commands[#calls.commands + 1] = command
end
vim.schedule = function(callback)
  callback()
end
command_count = #calls.commands
refused_close.options.close_command(102)
eq(#calls.commands, command_count, "core close refusal does not fall through to Bufferline deletion")
vim.cmd, vim.schedule = original_cmd_for_close, original_schedule_for_close

-- Explicit false values mean Bufferline's corresponding action is disabled.
local disabled_actions = adapter.extend({
  options = { left_mouse_command = false, close_command = false },
}, { core = core })
eq(disabled_actions.options.left_mouse_command, false, "disabled left click is preserved")
eq(disabled_actions.options.close_command, false, "disabled close is preserved")

-- Disabled core wrappers preserve host callbacks and otherwise use
-- Bufferline's native defaults.
enabled = false
local open_count, close_count = #calls.open, #calls.close
extended.options.left_mouse_command(101)
eq(#calls.open, open_count, "disabled click does not call core.open")
eq(calls.clicks[#calls.clicks], 101, "disabled click invokes its original callback")
extended.options.close_command(103)
eq(#calls.close, close_count, "disabled close does not call core.close")
eq(calls.host_close, 103, "disabled close invokes its original callback")

local original_cmd, original_schedule = vim.cmd, vim.schedule
vim.cmd = function(command)
  calls.commands[#calls.commands + 1] = command
end
vim.schedule = function(callback)
  callback()
end
local disabled_config = adapter.extend({ options = {} }, { core = core })
disabled_config.options.left_mouse_command(321)
disabled_config.options.close_command(322)
truthy(vim.tbl_contains(calls.commands, "buffer 321"), "disabled click uses native buffer open")
truthy(vim.tbl_contains(calls.commands, "bdelete! 322"), "disabled close uses Bufferline's native default")
vim.cmd, vim.schedule = original_cmd, original_schedule

-- Each extend call replaces the adapter augroup instead of accumulating
-- listeners; core events redraw the tabline.
local autocmds = api.nvim_get_autocmds({ group = "BufferGroupsBufferlineAdapter", event = "User" })
eq(#autocmds, 1, "one refresh listener is installed")

enabled = true
local original_cmd_again = vim.cmd
vim.cmd = function(command)
  calls.commands[#calls.commands + 1] = command
end
api.nvim_exec_autocmds("User", { pattern = "BufferGroupsChanged" })
eq(calls.commands[#calls.commands], "redrawtabline", "core events refresh Bufferline")
vim.cmd = original_cmd_again

print("buffer_groups Bufferline adapter: OK")
vim.cmd("qa!")
