-- Optional reorder integration exercise against installed Bufferline 4.9.1.
-- The core reorder API itself does not require Bufferline.

local root = assert(vim.env.BG_TEST_ROOT, "BG_TEST_ROOT is required")
local temp = assert(vim.env.BG_TEST_TMP, "BG_TEST_TMP is required")
vim.opt.runtimepath:prepend(root)
local api = vim.api

local bufferline_ok, Bufferline = pcall(require, "bufferline")
if not bufferline_ok then
  print("SKIP reorder integration: Bufferline is not installed in BG_TEST_PLUGIN_PATHS")
  vim.cmd("qa!")
  return
end

local function assert_true(value, message)
  if not value then
    error(message or "expected true", 2)
  end
end

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      (message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual:   " .. vim.inspect(actual),
      2
    )
  end
end

local function make_buffer(label)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(buf, temp .. "/" .. label .. ".txt")
  api.nvim_buf_set_lines(buf, 0, -1, false, { label })
  api.nvim_set_option_value("modified", false, { buf = buf })
  return buf
end

local plugin = require("buffer_groups")
local adapter = require("buffer_groups.integrations.bufferline")
local native_reordering = require("buffer_groups.integrations.bufferline_reordering")
local first = api.nvim_get_current_buf()
api.nvim_buf_set_name(first, temp .. "/reorder-a.txt")
api.nvim_buf_set_lines(first, 0, -1, false, { "a" })
api.nvim_set_option_value("buflisted", true, { buf = first })
api.nvim_set_option_value("modified", false, { buf = first })
local second = make_buffer("reorder-b")
local third = make_buffer("reorder-c")
local fourth = make_buffer("reorder-d")
api.nvim_set_current_buf(second)

plugin.setup({ reordering = { enabled = true } })
local opts = plugin.get_reordering_options()
assert_true(opts.enabled, "configured reordering options omitted enabled=true")
opts.enabled = false
assert_true(plugin.get_reordering_options().enabled, "reordering options are not defensive copies")
assert_true(not plugin.is_reordering_enabled(), "core-only setup activated Bufferline reorder adapter")

local ok, err = plugin.move("right")
assert_true(ok, "could not initialize groups: " .. tostring(err))
local function state()
  return plugin.get_state()
end
local function owner_group(st, buf)
  local owner = plugin.get_owner(buf)
  assert_true(owner, "buffer has no group owner: " .. tostring(buf))
  for _, group in ipairs(st.groups) do
    if group.id == owner.id then
      return group
    end
  end
  error("owner group missing from state")
end
local function expect_order(group, expected, message)
  assert_equal(group.buffers, expected, message)
end

-- Add a second member to the right group, then use group-local indices without
-- changing focus. This proves the API mutates only the owning group's list.
local before_add = state()
local right = owner_group(before_add, second)
assert_true(plugin.move("right", { buf = fourth, win = right.win }), "could not move another member to the right group")
local right_group = owner_group(state(), second)

-- Reordering activates only after the optional Bufferline adapter successfully
-- attaches in managed buffers mode. Seed Bufferline's manual order in reverse
-- so reconciliation proves it follows the core's group order.
local config = adapter.extend({
  options = {
    mode = "buffers",
    always_show_bufferline = true,
    show_buffer_close_icons = false,
    sort_by = function(a, b)
      return a.id > b.id
    end,
  },
}, { managed_order = true })
Bufferline.setup(config)
assert_true(adapter.attach(), "Bufferline adapter failed to attach")
assert_true(plugin.is_reordering_enabled(), "managed adapter did not activate reordering")
vim.cmd("redrawtabline")

local function rendered_ids()
  api.nvim_eval_statusline(vim.o.tabline, { use_tabline = true, maxwidth = vim.o.columns })
  vim.cmd("redrawtabline")
  return vim.tbl_map(function(element)
    return element.id
  end, Bufferline.get_elements().elements)
end
local function managed_order()
  local order = {}
  for _, group in ipairs(state().groups) do
    vim.list_extend(order, group.buffers)
  end
  return order
end
local custom_order = vim.deepcopy(managed_order())
local reversed_custom_order = {}
for index = #custom_order, 1, -1 do
  reversed_custom_order[#reversed_custom_order + 1] = custom_order[index]
end
require("bufferline.state").custom_sort = reversed_custom_order
require("bufferline.ui").refresh()
assert_equal(rendered_ids(), managed_order(), "Bufferline custom_sort overrode managed group order")

local initial_right = vim.deepcopy(right_group.buffers)
assert_equal(#initial_right, 2, "right group fixture should have two members")
local from = initial_right[1]
local moved, result = plugin.reorder(1, { win = right_group.win, from_index = 1 })
assert_true(moved, "group-local adjacent reorder failed: " .. tostring(result))
assert_equal(result.buf, from, "reorder result reported the wrong source buffer")
assert_equal(result.group_id, right_group.id, "reorder result reported the wrong group")
assert_equal(result.from, 1, "reorder result reported the wrong source position")
assert_equal(result.to, 2, "reorder result reported the wrong destination position")
assert_true(result.moved, "successful swap was not marked moved")
expect_order(owner_group(state(), second), { initial_right[2], initial_right[1] }, "adjacent reorder did not swap")

local no_wrap, edge_result = plugin.reorder(1, { win = right_group.win, from_index = #initial_right })
assert_true(no_wrap, "edge reorder should be a successful no-op")
assert_true(not edge_result.moved, "edge reorder unexpectedly moved a buffer")
assert_equal(edge_result.to, edge_result.from + 1, "no-op result did not report the requested position")
local invalid, invalid_err = plugin.reorder_to(0, { win = right_group.win })
assert_true(not invalid and type(invalid_err) == "string", "index zero should be rejected")
invalid, invalid_err = plugin.reorder_to(1.5, { win = right_group.win })
assert_true(not invalid and type(invalid_err) == "string", "fractional index should be rejected")
local zero_delta, zero_result = plugin.reorder(0, { win = right_group.win })
assert_true(zero_delta and not zero_result.moved, "zero delta should be a successful no-op")

-- Reorder the left group and confirm the second group is untouched.
local left_group = owner_group(state(), first)
local left_before = vim.deepcopy(left_group.buffers)
assert_true(#left_before >= 2, "left group fixture should have several members")
local untouched_right = vim.deepcopy(owner_group(state(), second).buffers)
local focused = api.nvim_get_current_buf()
local success, left_result = plugin.reorder_to(1, { win = left_group.win, from_index = #left_before })
assert_true(success, "reorder_to failed: " .. tostring(left_result))
assert_equal(left_result.from, #left_before, "reorder_to source position is wrong")
assert_equal(left_result.to, 1, "reorder_to destination position is wrong")
local expected_left = vim.deepcopy(left_before)
expected_left[1], expected_left[#expected_left] = expected_left[#expected_left], expected_left[1]
expect_order(owner_group(state(), first), expected_left, "reorder_to did not swap positions")
expect_order(owner_group(state(), second), untouched_right, "left reorder changed the other group")
assert_equal(api.nvim_get_current_buf(), focused, "explicit group reorder stole focus")

-- User commands resolve the focused buffer and apply the same adjacent swap.
local command_group = owner_group(state(), third)
assert_true(#command_group.buffers > 1, "command fixture needs at least two left buffers")
local command_source = command_group.buffers[1]
local command_order = vim.deepcopy(command_group.buffers)
api.nvim_set_current_win(command_group.win)
api.nvim_set_current_buf(command_source)
vim.cmd("BufferGroupsReorder right")
expect_order(
  owner_group(state(), command_source),
  { command_order[2], command_order[1], unpack(command_order, 3) },
  "reorder command did not swap adjacent members"
)
vim.cmd("BufferGroupsReorderTo 1")
assert_equal(
  vim.fn.index(owner_group(state(), command_source).buffers, command_source) + 1,
  1,
  "reorder-to command did not move to requested position"
)

-- Disabling the core deactivates reorder commands without discarding its
-- configured option or adapter connection.
local visible_before_disable = {}
for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
  visible_before_disable[win] = api.nvim_win_get_buf(win)
end
local focused_before_disable = api.nvim_get_current_buf()
local modified_before_disable = {}
for _, buf in ipairs({ first, second, third, fourth }) do
  modified_before_disable[buf] = api.nvim_get_option_value("modified", { buf = buf })
end
assert_true(plugin.disable(), "could not disable the core")
assert_true(not plugin.is_reordering_enabled(), "reordering remained enabled")
local disabled, disabled_err = plugin.reorder(1)
assert_true(not disabled and type(disabled_err) == "string", "disabled reorder should be rejected")
assert_equal(api.nvim_get_current_buf(), focused_before_disable, "rejected reorder changed focus")
for win, buf in pairs(visible_before_disable) do
  assert_equal(api.nvim_win_get_buf(win), buf, "rejected reorder changed a displayed buffer")
end
for buf, modified in pairs(modified_before_disable) do
  assert_equal(
    api.nvim_get_option_value("modified", { buf = buf }),
    modified,
    "rejected reorder changed modified state"
  )
end
assert_true(plugin.enable(), "could not re-enable the core")
assert_true(plugin.is_reordering_enabled(), "reordering did not re-enable")

-- The adapter installs order control only when explicitly requested for the
-- Bufferline buffers mode. Verify public rendered order against core order.
-- Bufferline's native command and Lua entry points must use group-local
-- positions for owned buffers. External buffers retain their native sorter.
local move = require("bufferline.commands").move
local move_to = require("bufferline.commands").move_to
assert_true(type(move) == "function" and type(move_to) == "function", "Bufferline command APIs are unavailable")
local order = managed_order()
local target = order[1]
api.nvim_set_current_buf(target)
api.nvim_set_option_value("modified", true, { buf = target })
move(1)
assert_true(
  vim.fn.index(managed_order(), target) == 1,
  "Bufferline move command did not route through group reordering"
)
assert_equal(api.nvim_get_current_buf(), target, "Bufferline move changed focus")
assert_true(api.nvim_get_option_value("modified", { buf = target }), "Bufferline move lost modified state")
assert_equal(rendered_ids(), managed_order(), "Bufferline move broke rendered group order")
local source_group = owner_group(state(), target)
local source_index = vim.fn.index(source_group.buffers, target) + 1
assert_true(source_index > 0, "moved buffer lost its group membership")
move_to(1, source_index)
assert_equal(rendered_ids(), managed_order(), "Bufferline move_to broke rendered group order")
assert_true(vim.fn.exists(":BufferLineMoveNext") == 2, "Bufferline native move command is missing")

local command_source = api.nvim_get_current_buf()
local local_count = #plugin.get_owner(command_source).buffers
Bufferline.move_to(-1)
assert_equal(
  vim.fn.index(plugin.get_owner(command_source).buffers, command_source),
  local_count - 1,
  "public move_to did not use the group's last index"
)
Bufferline.move(-1)
assert_equal(
  vim.fn.index(plugin.get_owner(command_source).buffers, command_source),
  local_count - 2,
  "public move did not use the group order"
)
assert_equal(rendered_ids(), managed_order(), "native/public command routing diverged from cycle order")
Bufferline.move_to(1)

api.nvim_set_current_buf(target)
vim.cmd("BufferLineMoveNext")
assert_equal(
  vim.fn.index(owner_group(state(), target).buffers, target) + 1,
  2,
  "BufferLineMoveNext did not route through core reordering"
)
assert_equal(api.nvim_get_current_buf(), target, "BufferLineMoveNext changed focus")
assert_equal(rendered_ids(), managed_order(), "BufferLineMoveNext broke rendered group order")
vim.cmd("BufferLineMovePrev")
assert_equal(
  vim.fn.index(owner_group(state(), target).buffers, target) + 1,
  1,
  "BufferLineMovePrev did not route through core reordering"
)

-- Disabling the core suspends native movement wrappers while Bufferline's
-- already reconciled manual order remains visible. Reattach repeatedly to
-- catch stacked wrappers and stale callbacks.
assert_true(plugin.disable(), "could not disable reorder integration")
local native_ids = rendered_ids()
assert_equal(native_ids, require("bufferline.state").custom_sort, "core disable changed Bufferline manual order")
assert_true(plugin.enable(), "could not re-enable reorder integration")
for _ = 1, 2 do
  native_reordering.detach()
  assert_true(adapter.attach(), "adapter failed to reattach after detach")
end
assert_equal(rendered_ids(), managed_order(), "reattach stacked wrappers or lost managed sorting")

-- managed_order=false leaves Bufferline's configured custom sorter in charge.
local native_config = adapter.extend({
  options = {
    mode = "buffers",
    always_show_bufferline = true,
    sort_by = function(a, b)
      return a.id > b.id
    end,
  },
}, { managed_order = false })
Bufferline.setup(native_config)
require("bufferline.state").custom_sort = nil
require("bufferline.state").set({ custom_sort = vim.NIL })
local native_attached, native_attach_err = adapter.attach()
assert_true(
  not native_attached and type(native_attach_err) == "string",
  "enabled reordering should reject managed_order=false"
)
local fallback_ids = rendered_ids()
local stable_group_orders = {}
for _, group in ipairs(state().groups) do
  stable_group_orders[group.id] = vim.deepcopy(group.buffers)
end
local fallback_target = fallback_ids[1]
api.nvim_set_current_buf(fallback_target)
require("bufferline.commands").move(1)
for _, group in ipairs(state().groups) do
  assert_equal(group.buffers, stable_group_orders[group.id], "native fallback changed core group order")
end
assert_true(not vim.deep_equal(rendered_ids(), fallback_ids), "native fallback did not move Bufferline order")
local managed_config = adapter.extend({
  options = { mode = "buffers", always_show_bufferline = true },
}, { managed_order = true })
Bufferline.setup(managed_config)
assert_true(adapter.attach(), "adapter failed to restore managed order")
assert_equal(
  require("bufferline.state").custom_sort,
  managed_order(),
  "adapter did not reconcile Bufferline manual order after reattach"
)
assert_equal(rendered_ids(), managed_order(), "managed order did not return after native fallback")

-- A second tab remains outside the current tab's group-local ordering.
local old_tab = api.nvim_get_current_tabpage()
vim.cmd("tabnew")
local outside = api.nvim_get_current_buf()
api.nvim_buf_set_name(outside, temp .. "/outside-tab.txt")
api.nvim_set_current_tabpage(old_tab)
local all_rendered = rendered_ids()
assert_true(vim.tbl_contains(all_rendered, outside), "Bufferline hid the unmanaged other-tab buffer")
local owned_rendered = vim.tbl_filter(function(buf)
  return plugin.get_owner(buf) ~= nil
end, all_rendered)
assert_equal(owned_rendered, managed_order(), "other tab buffer affected managed ordering")

print("reorder integration: core swaps, Bufferline order, wrappers, and lifecycle OK")
vim.cmd("qa!")
