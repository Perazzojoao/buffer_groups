-- Optional integration exercise against locally installed Snacks and Bufferline.
-- The core/adapter unit suites do not need either plugin or any downloads.

local root = assert(vim.env.BG_TEST_ROOT, "BG_TEST_ROOT is required")
local temp = assert(vim.env.BG_TEST_TMP, "BG_TEST_TMP is required")
vim.opt.runtimepath:prepend(root)
local api = vim.api

local snacks_ok, Snacks = pcall(require, "snacks")
local bufferline_ok, Bufferline = pcall(require, "bufferline")
if not snacks_ok or not bufferline_ok then
  print("SKIP integration: install Snacks and Bufferline locally or set BG_TEST_DEPS to their plugin roots")
  vim.cmd("qa!")
  return
end

local plugin = require("buffer_groups")
local adapter = require("buffer_groups.integrations.bufferline")

local function assert_true(value, message)
  if not value then
    error(message or "expected true", 2)
  end
end

local function assert_equal(actual, expected, message)
  local equal = type(actual) == "table" and type(expected) == "table" and vim.deep_equal(actual, expected)
    or actual == expected
  if not equal then
    error(
      (message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual:   " .. vim.inspect(actual),
      2
    )
  end
end

local function make_buffer(name)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(buf, temp .. "/" .. name)
  api.nvim_buf_set_lines(buf, 0, -1, false, { name })
  api.nvim_set_option_value("modified", false, { buf = buf })
  return buf
end

local function side_group(st, side)
  for _, group in ipairs(st.groups) do
    if group.side == side then
      return group
    end
  end
end

local function owner_id(buf)
  local owner = plugin.get_owner(buf)
  return owner and owner.id
end

local first = api.nvim_get_current_buf()
api.nvim_buf_set_name(first, temp .. "/integration-a.txt")
api.nvim_buf_set_lines(first, 0, -1, false, { "integration-a" })
api.nvim_set_option_value("buflisted", true, { buf = first })
api.nvim_set_option_value("modified", false, { buf = first })
local second = make_buffer("integration-b.txt")
api.nvim_win_set_buf(0, first)

plugin.setup()
local ok, err = plugin.move("right")
assert_true(ok, "core initialization failed: " .. tostring(err))
local before = plugin.get_state()
assert_true(before.active, "core did not enter an active partition")
local left, right = side_group(before, "left"), side_group(before, "right")
assert_true(left and right, "active partition does not have both sides")
local first_owner, second_owner = owner_id(first), owner_id(second)
assert_true(first_owner and second_owner and first_owner ~= second_owner, "core did not assign unique owners")

-- Set up the actual Snacks plugin and create its real buffers/windows. The
-- list/input are floating; the layout box is an editor-style auxiliary window.
Snacks.setup({ picker = { enabled = true } })
local picker = Snacks.picker.buffers({})
assert_true(picker and type(picker.close) == "function", "Snacks did not create a real buffer picker")
local saw_picker_list = vim.wait(1800, function()
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_get_option_value("filetype", { buf = buf }) == "snacks_picker_list" then
      return true
    end
  end
  return false
end, 10)
assert_true(saw_picker_list, "Snacks picker list window did not appear")

local auxiliary = {}
for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
  local buf = api.nvim_win_get_buf(win)
  local filetype = api.nvim_get_option_value("filetype", { buf = buf })
  local relative = api.nvim_win_get_config(win).relative
  if
    filetype == "snacks_picker_list"
    or filetype == "snacks_picker_input"
    or filetype == "snacks_picker_preview"
    or filetype == "snacks_layout_box"
    or relative ~= ""
  then
    auxiliary[win] = buf
    assert_equal(plugin.get_owner(buf), nil, "Snacks auxiliary buffer acquired an owner")
    for _, group in ipairs(plugin.get_state().groups) do
      assert_true(group.win ~= win, "Snacks auxiliary window became a managed owner")
    end
  end
end
assert_true(next(auxiliary) ~= nil, "no Snacks auxiliary surfaces were detected")
picker:close()
local closed = vim.wait(1500, function()
  return #api.nvim_tabpage_list_wins(0) == #before.groups
end, 10)
assert_true(closed, "Snacks picker did not close cleanly")
local after_picker = plugin.get_state()
assert_true(after_picker.active, "opening Snacks collapsed the managed partition")
assert_equal(owner_id(first), first_owner, "Snacks changed the first buffer owner")
assert_equal(owner_id(second), second_owner, "Snacks changed the second buffer owner")

-- Extend and load the actual Bufferline plugin. Rendering exercises its public
-- config path; the adapter callback then routes a buffer through core.open.
local config = adapter.extend({ options = { mode = "buffers", always_show_bufferline = true } })
assert_true(config ~= nil, "adapter did not return a Bufferline config")
Bufferline.setup(config)
vim.cmd("redrawtabline")
local click = config.options.left_mouse_command
assert_true(type(click) == "function", "adapter did not configure Bufferline's buffer callback")
click(first)
local first_owner_snapshot = plugin.get_owner(first)
assert_true(
  first_owner_snapshot and api.nvim_get_current_win() == first_owner_snapshot.win,
  "Bufferline click did not focus the owner's window"
)
assert_equal(api.nvim_win_get_buf(first_owner_snapshot.win), first, "Bufferline click did not open the owned buffer")

print("integration: Snacks picker and Bufferline adapter OK")
vim.cmd("qa!")
