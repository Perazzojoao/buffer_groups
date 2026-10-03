-- Contract tests for the public buffer_groups API.  Each case runs in its own
-- nvim -u NONE process; assertions intentionally observe only public state and
-- Neovim's public window/buffer APIs.

local root = assert(vim.env.BG_TEST_ROOT, "BG_TEST_ROOT is required")
local temp = assert(vim.env.BG_TEST_TMP, "BG_TEST_TMP is required")
vim.opt.runtimepath:prepend(root)

local api = vim.api
local plugin = require("buffer_groups")

local function fail(message)
  error(message, 2)
end

local function eq(actual, expected, message)
  local equal = type(actual) == "table" and type(expected) == "table" and vim.deep_equal(actual, expected)
    or actual == expected
  if not equal then
    fail(
      (message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual:   " .. vim.inspect(actual)
    )
  end
end

local function truthy(value, message)
  if not value then
    fail(message or "expected a truthy value")
  end
end

local function falsy(value, message)
  if value then
    fail(message or "expected a false value")
  end
end

local function make_buffer(label, reuse_current)
  local buf = reuse_current and api.nvim_get_current_buf() or api.nvim_create_buf(true, false)
  local path = temp .. "/" .. label
  if api.nvim_buf_get_name(buf) ~= path then
    api.nvim_buf_set_name(buf, path)
  end
  api.nvim_set_option_value("buflisted", true, { buf = buf })
  api.nvim_set_option_value("buftype", "", { buf = buf })
  api.nvim_set_option_value("modifiable", true, { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, { label })
  api.nvim_set_option_value("modified", false, { buf = buf })
  return buf
end

local function make_file(label, lines)
  local path = temp .. "/" .. label
  vim.fn.writefile(lines or { label }, path)
  return path
end

local function edit(path)
  api.nvim_cmd({ cmd = "edit", args = { path } }, {})
  return api.nvim_get_current_buf()
end

local function new_vertical_window(buf)
  vim.cmd("rightbelow vsplit")
  if buf then
    api.nvim_win_set_buf(0, buf)
  end
  return api.nvim_get_current_win()
end

local function state(tabpage)
  return plugin.get_state(tabpage and { tabpage = tabpage } or nil)
end

local function group_for(st, win)
  for _, group in ipairs(st.groups or {}) do
    if group.win == win then
      return group
    end
  end
end

local function group_side(st, side)
  for _, group in ipairs(st.groups or {}) do
    if group.side == side then
      return group
    end
  end
end

local function owner_id(buf, tabpage)
  local owner = plugin.get_owner(buf, tabpage and { tabpage = tabpage } or nil)
  return owner and owner.id or nil
end

local function listed_buffers()
  local out = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) and api.nvim_get_option_value("buflisted", { buf = buf }) then
      out[#out + 1] = buf
    end
  end
  table.sort(out)
  return out
end

local function current_buffers(wins)
  local out = {}
  for _, win in ipairs(wins or api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_is_valid(win) then
      out[#out + 1] = api.nvim_win_get_buf(win)
    end
  end
  return out
end

local function contains(values, needle)
  for _, value in ipairs(values or {}) do
    if value == needle then
      return true
    end
  end
  return false
end

local function count(values)
  local n = 0
  for _ in pairs(values or {}) do
    n = n + 1
  end
  return n
end

local function wait_for(predicate, message, timeout)
  local ok = vim.wait(timeout or 1800, function()
    local called, result = pcall(predicate)
    return called and result == true
  end, 10)
  if not ok then
    fail((message or "condition did not become true") .. "\nstate: " .. vim.inspect(state()))
  end
end

local function flush()
  -- get_state is specified to synchronize safe pending reconciliation.  Wait
  -- one scheduled turn as well, so the tests do not observe BufAdd transients.
  vim.wait(25, function()
    return false
  end, 5)
  state()
end

local function configured(opts)
  plugin.setup(opts or {})
end

local function must_succeed(ok, value, operation)
  if not ok then
    fail((operation or "operation") .. " failed: " .. tostring(value))
  end
  return value
end

local function state_has_exact_owners(st, expected)
  local seen = {}
  for _, group in ipairs(st.groups or {}) do
    for _, buf in ipairs(group.buffers or {}) do
      if seen[buf] then
        fail("buffer " .. buf .. " appears in more than one group")
      end
      seen[buf] = group.id
    end
  end
  for buf, id in pairs(expected) do
    eq(seen[buf], id, "wrong owner for buffer " .. buf)
  end
  for buf in pairs(seen) do
    if expected[buf] == nil then
      fail("unexpected owned buffer " .. buf)
    end
  end
  eq(count(seen), count(expected), "unexpected owner count")
end

local cases = {}

cases.singlebuffer_refusal = function()
  configured()
  local only = make_buffer("only.txt", true)
  api.nvim_win_set_buf(0, only)
  flush()
  local win = api.nvim_get_current_win()
  local before = current_buffers({ win })
  local result, err = plugin.move("right")
  falsy(result, "initial move must refuse a single eligible buffer by default")
  truthy(err, "refusal should return an error")
  eq(#api.nvim_tabpage_list_wins(0), 1, "refusal changed the window layout")
  eq(current_buffers({ win }), before, "refusal changed the displayed buffer")
  falsy(state().active, "refusal activated a partition")
end

cases.singlebuffer_new_buffer = function()
  configured({ behavior = { single_buffer_split = "new_buffer" } })
  local only = make_buffer("only.txt", true)
  api.nvim_win_set_buf(0, only)
  flush()
  must_succeed(plugin.move("right"))
  wait_for(function()
    return state().active
  end, "new_buffer policy did not create a partition")
  local st = state()
  eq(#st.groups, 2, "new_buffer policy should create two groups")
  truthy(contains(listed_buffers(), only), "original buffer was lost")
  truthy(st.owners[only], "original buffer has no owner")
  local all = {}
  for _, group in ipairs(st.groups) do
    for _, buf in ipairs(group.buffers) do
      all[#all + 1] = buf
    end
  end
  eq(#all, 2, "new_buffer policy should add exactly one listed buffer")
  truthy(contains(all, only), "original buffer is absent from new partition")
end

cases.directional_initialization = function()
  configured()
  local a = make_buffer("a.txt", true)
  local b = make_buffer("b.txt")
  api.nvim_win_set_buf(0, a)
  flush()
  must_succeed(plugin.move("left"))
  wait_for(function()
    return state().active
  end, "directional initialization did not activate")
  local st = state()
  local left, right = group_side(st, "left"), group_side(st, "right")
  truthy(left and right, "partition did not create left and right groups")
  eq(owner_id(a), left.id, "initiating buffer did not move to requested left side")
  eq(owner_id(b), right.id, "other buffer did not remain on opposite side")
  eq(api.nvim_win_get_buf(left.win), a, "left group did not show moved buffer")
end

cases.adopt_stacked_windows = function()
  configured()
  vim.o.columns, vim.o.lines = 140, 40
  local a = make_buffer("stacked-a.txt", true)
  local b = make_buffer("stacked-b.txt")
  make_buffer("stacked-hidden.txt")
  local main = api.nvim_get_current_win()
  vim.cmd("leftabove 22vnew")
  local sidebar = api.nvim_get_current_win()
  vim.bo.buftype, vim.bo.buflisted = "nofile", false
  local width = api.nvim_win_get_width(sidebar)
  api.nvim_set_current_win(main)
  vim.cmd("belowright split")
  local second = api.nvim_get_current_win()
  api.nvim_win_set_buf(second, b)
  api.nvim_set_current_win(main)
  api.nvim_win_set_buf(main, a)
  flush()
  must_succeed(plugin.move("right"))
  local st = state()
  local left, right = group_side(st, "left"), group_side(st, "right")
  truthy(left and right, "stacked windows were not adopted")
  truthy(api.nvim_win_get_position(left.win)[2] < api.nvim_win_get_position(right.win)[2], "editors remain stacked")
  eq(api.nvim_win_get_position(left.win)[1], api.nvim_win_get_position(right.win)[1], "editors are not side by side")
  truthy(api.nvim_win_is_valid(main) and api.nvim_win_is_valid(second), "adoption replaced native windows")
  eq(owner_id(a), right.id, "initiating buffer did not move right")
  eq(api.nvim_win_get_width(sidebar), width, "normalization resized the sidebar")
end

cases.adopt_two_distinct_windows = function()
  configured()
  local a = make_buffer("a.txt", true)
  local b = make_buffer("b.txt")
  local c = make_buffer("c.txt")
  api.nvim_win_set_buf(0, a)
  local first = api.nvim_get_current_win()
  new_vertical_window(b)
  api.nvim_set_current_win(first)
  flush()
  must_succeed(plugin.move("right"))
  wait_for(function()
    return state().active
  end, "two-window adoption did not activate")
  local st = state()
  local left, right = group_side(st, "left"), group_side(st, "right")
  truthy(left and right, "adopted groups lost a side")
  eq(owner_id(a), right.id, "requested initiating buffer did not move right")
  eq(owner_id(b), right.id, "target's existing buffer was not retained")
  truthy(contains(left.buffers, c), "hidden pool was not retained with the initiating group")
  truthy(contains(right.buffers, b), "target's original buffer was lost")
  eq(#api.nvim_tabpage_list_wins(0), 2, "adoption unexpectedly changed two-window layout")
end

cases.adopt_duplicate_currents = function()
  configured()
  local a = make_buffer("a.txt", true)
  local b = make_buffer("b.txt")
  api.nvim_win_set_buf(0, a)
  local first = api.nvim_get_current_win()
  local second = new_vertical_window(a)
  api.nvim_set_current_win(first)
  flush()
  must_succeed(plugin.move("right"))
  wait_for(function()
    return state().active
  end, "duplicate-window adoption did not activate")
  eq(#api.nvim_tabpage_list_wins(0), 2, "duplicate-window adoption changed the layout")
  local displayed = current_buffers({ first, second })
  eq(displayed[1] == displayed[2], false, "adoption left the same current buffer in both owners")
  local st = state()
  truthy(owner_id(a), "original buffer has no owner after adoption")
  truthy(owner_id(b), "alternate buffer was not used to resolve duplicate windows")
  state_has_exact_owners(st, { [a] = owner_id(a), [b] = owner_id(b) })
end

cases.refuse_more_than_two_windows = function()
  configured()
  local a = make_buffer("a.txt", true)
  local b, c = make_buffer("b.txt"), make_buffer("c.txt")
  api.nvim_win_set_buf(0, a)
  local w1 = api.nvim_get_current_win()
  local w2 = new_vertical_window(b)
  local w3 = new_vertical_window(c)
  local before_wins = api.nvim_tabpage_list_wins(0)
  local before = current_buffers(before_wins)
  api.nvim_set_current_win(w1)
  flush()
  local ok = plugin.move("right")
  falsy(ok, "initialization with more than two editor windows must refuse")
  eq(api.nvim_tabpage_list_wins(0), before_wins, "refusal changed editor windows")
  eq(current_buffers(before_wins), before, "refusal changed displayed buffers")
  falsy(state().active, "refusal activated a partition")
  truthy(api.nvim_win_is_valid(w2) and api.nvim_win_is_valid(w3), "refusal closed a window")
end

cases.membership_transfer_and_local_cycle = function()
  configured()
  local a = make_buffer("a.txt", true)
  local b, c = make_buffer("b.txt"), make_buffer("c.txt")
  api.nvim_win_set_buf(0, a)
  flush()
  must_succeed(plugin.move("right"))
  local st = state()
  local left, right = group_side(st, "left"), group_side(st, "right")
  truthy(left and right, "partition did not activate")
  truthy(contains(left.buffers, b) and contains(left.buffers, c), "initial hidden pool is not on opposite side")
  api.nvim_set_current_win(left.win)
  local first = api.nvim_win_get_buf(left.win)
  must_succeed(plugin.cycle(1))
  local second = api.nvim_win_get_buf(left.win)
  truthy(
    first ~= second and contains(left.buffers, first) and contains(left.buffers, second),
    "cycle did not rotate locally"
  )
  must_succeed(plugin.cycle(-1))
  eq(api.nvim_win_get_buf(left.win), first, "reverse cycle did not wrap back locally")
  must_succeed(plugin.move("right", { buf = first }))
  st = state()
  left, right = group_side(st, "left"), group_side(st, "right")
  eq(owner_id(first), right.id, "move swapped or failed to transfer ownership")
  truthy(contains(right.buffers, a), "the target's original member was displaced")
  truthy(contains(left.buffers, second), "source's other member was lost")
  eq(owner_id(second), left.id, "source member changed owner")
  local saved = { [a] = right.id, [first] = right.id, [second] = left.id }
  state_has_exact_owners(st, saved)
  api.nvim_set_current_win(right.win)
  local current = api.nvim_win_get_buf(right.win)
  must_succeed(plugin.cycle(1))
  local cycled = api.nvim_win_get_buf(right.win)
  truthy(current ~= cycled, "right group did not cycle its local membership")
  truthy(contains(right.buffers, cycled), "right cycle borrowed a buffer from another owner")
end

cases.new_file_and_foreign_buffer = function()
  configured()
  local a = make_buffer("a.txt", true)
  local b, c = make_buffer("b.txt"), make_buffer("c.txt")
  api.nvim_win_set_buf(0, a)
  flush()
  must_succeed(plugin.move("right"))
  local st = state()
  local left, right = group_side(st, "left"), group_side(st, "right")
  api.nvim_set_current_win(left.win)
  local file = make_file("new-in-left.txt", { "created in left" })
  local newbuf = edit(file)
  wait_for(function()
    return owner_id(newbuf) ~= nil
  end, "new file was not assigned to its destination owner")
  st = state()
  left, right = group_side(st, "left"), group_side(st, "right")
  eq(owner_id(newbuf), left.id, "new file was assigned to the wrong owner")
  eq(api.nvim_win_get_buf(left.win), newbuf, "new file was not left in its destination window")
  truthy(
    contains(right.buffers, a) or contains(right.buffers, b) or contains(right.buffers, c),
    "other owner lost its buffers"
  )

  -- Try entering an already-owned buffer through a native window-buffer API.
  -- The guard must restore the original window and focus its owner.
  api.nvim_set_current_win(right.win)
  local right_before = api.nvim_win_get_buf(right.win)
  api.nvim_win_set_buf(right.win, newbuf)
  wait_for(function()
    return api.nvim_win_get_buf(right.win) == right_before and api.nvim_get_current_win() == left.win
  end, "foreign buffer entry was not redirected to the existing owner")
  eq(owner_id(newbuf), left.id, "foreign buffer entry transferred ownership")
end

cases.existing_buffer_transfer_policy = function()
  configured({ behavior = { existing_buffer = "transfer" } })
  local a = make_buffer("a.txt", true)
  local b, c = make_buffer("b.txt"), make_buffer("c.txt")
  api.nvim_win_set_buf(0, a)
  flush()
  must_succeed(plugin.move("right"))
  local st = state()
  local left, right = group_side(st, "left"), group_side(st, "right")
  api.nvim_set_current_win(left.win)
  must_succeed(plugin.open(a, { win = right.win }))
  st = state()
  left, right = group_side(st, "left"), group_side(st, "right")
  eq(owner_id(a), right.id, "existing_buffer=transfer did not transfer membership")
  eq(api.nvim_win_get_buf(right.win), a, "transferred buffer was not opened in destination")
  truthy(contains(left.buffers, b) and contains(left.buffers, c), "source group lost unrelated buffers")
end

cases.modified_and_unloaded_buffers = function()
  configured()
  vim.o.hidden = false
  local a = make_buffer("a.txt", true)
  local b, c, d = make_buffer("b.txt"), make_buffer("c.txt"), make_buffer("d.txt")
  api.nvim_win_set_buf(0, a)
  flush()
  must_succeed(plugin.move("right"))
  local st = state()
  local left, right = group_side(st, "left"), group_side(st, "right")
  must_succeed(plugin.move("right", { buf = d }))
  st = state()
  left, right = group_side(st, "left"), group_side(st, "right")
  truthy(contains(right.buffers, d), "failed to keep a second member in the source group")
  api.nvim_buf_set_lines(a, 0, -1, false, { "unsaved marker" })
  truthy(api.nvim_get_option_value("modified", { buf = a }), "buffer did not become modified")
  must_succeed(plugin.move("left", { buf = a }))
  eq(api.nvim_buf_get_lines(a, 0, -1, false), { "unsaved marker" }, "move discarded modified text")
  st = state()
  left = group_side(st, "left")
  local ok, err = plugin.close(a)
  falsy(ok, "close should refuse a modified buffer by default")
  truthy(err, "modified close refusal should explain the error")
  truthy(api.nvim_buf_is_valid(a), "modified buffer was deleted after refusal")
  eq(api.nvim_buf_get_lines(a, 0, -1, false), { "unsaved marker" }, "modified close refusal lost text")
  eq(owner_id(a), left.id, "modified close refusal changed ownership")

  -- Unloaded, but still listed buffers retain their owner and ordered slot.
  api.nvim_set_current_win(left.win)
  api.nvim_cmd({ cmd = "bunload", args = { tostring(b) } }, {})
  wait_for(function()
    return not api.nvim_buf_is_loaded(b)
  end, "bunload did not unload the hidden buffer")
  st = state()
  left = group_side(st, "left")
  truthy(contains(left.buffers, b), "unload removed a still-listed buffer from its owner")
  eq(owner_id(b), left.id, "unload changed owner")
  truthy(api.nvim_get_option_value("buflisted", { buf = b }), "unload unlisted the buffer")
end

cases.follow_buffer_disabled = function()
  configured({ behavior = { follow_buffer = false } })
  local a = make_buffer("a.txt", true)
  local b, c = make_buffer("b.txt"), make_buffer("c.txt")
  api.nvim_win_set_buf(0, a)
  flush()
  must_succeed(plugin.move("right"))
  local st = state()
  local left, right = group_side(st, "left"), group_side(st, "right")
  must_succeed(plugin.move("right", { buf = c }))
  st = state()
  right = group_side(st, "right")
  local focused = right.win
  api.nvim_set_current_win(focused)
  must_succeed(plugin.move("left", { buf = a }))
  st = state()
  left, right = group_side(st, "left"), group_side(st, "right")
  truthy(left and right, "follow_buffer=false unexpectedly collapsed a group")
  eq(api.nvim_get_current_win(), focused, "follow_buffer=false moved focus to the target")
  eq(api.nvim_win_get_buf(focused), c, "origin did not show its local replacement")
  eq(owner_id(a), left.id, "buffer did not transfer when follow_buffer was disabled")
  eq(owner_id(b), left.id, "unrelated source member changed owner")
  eq(owner_id(c), right.id, "origin replacement changed owner")
end

cases.float_preview_preserves_owner = function()
  configured()
  local a = make_buffer("a.txt", true)
  local b, c = make_buffer("b.txt"), make_buffer("c.txt")
  api.nvim_win_set_buf(0, a)
  flush()
  must_succeed(plugin.move("right"))
  local before = state()
  local left, right = group_side(before, "left"), group_side(before, "right")
  truthy(contains(left.buffers, b), "preview fixture buffer is not owned by the left group")
  local preview =
    api.nvim_open_win(b, false, { relative = "editor", row = 1, col = 1, width = 16, height = 2, style = "minimal" })
  local fresh = make_buffer("fresh-float.txt")
  local fresh_float = api.nvim_open_win(
    fresh,
    false,
    { relative = "editor", row = 4, col = 1, width = 16, height = 2, style = "minimal" }
  )
  flush()
  local after = state()
  left = group_side(after, "left")
  right = group_side(after, "right")
  eq(owner_id(b), left.id, "showing an owned preview in a float dropped its owner")
  truthy(contains(left.buffers, b), "owned preview left its ordered group list")
  falsy(owner_id(fresh), "a fresh float-only buffer acquired an owner")
  falsy(group_for(after, preview), "owned preview float became a managed group")
  falsy(group_for(after, fresh_float), "fresh floating window became a managed group")
  eq(owner_id(a), right.id, "floating preview changed the other group")
  truthy(contains(left.buffers, c), "floating preview removed a neighboring hidden member")
end

cases.rename_and_deferred_delete = function()
  configured()
  local a = make_buffer("a.txt", true)
  local b, c = make_buffer("b.txt"), make_buffer("c.txt")
  api.nvim_win_set_buf(0, a)
  flush()
  must_succeed(plugin.move("right"))
  local before = owner_id(a)
  api.nvim_buf_set_name(a, temp .. "/renamed-a.txt")
  vim.wait(30, function()
    return false
  end, 5)
  eq(owner_id(a), before, "rename changed buffer owner")
  truthy(api.nvim_buf_is_valid(a), "rename invalidated the buffer")
  local victim_owner = owner_id(b)
  api.nvim_buf_delete(b, { force = true })
  wait_for(function()
    return owner_id(b) == nil
  end, "deferred BufDelete cleanup did not remove ownership")
  st = state()
  for _, group in ipairs(st.groups) do
    truthy(not contains(group.buffers, b), "deleted buffer remains in an owner list")
  end
  truthy(owner_id(c) ~= nil, "remaining buffer lost ownership")
  truthy(victim_owner ~= nil, "deleted buffer had no owner before deletion")
  truthy(api.nvim_buf_is_valid(a), "deleting another buffer affected renamed buffer")
end

cases.manual_window_close_merges = function()
  configured()
  local a = make_buffer("a.txt", true)
  local b, c = make_buffer("b.txt"), make_buffer("c.txt")
  api.nvim_win_set_buf(0, a)
  flush()
  must_succeed(plugin.move("right"))
  local st = state()
  local right = group_side(st, "right")
  truthy(right, "right group missing before manual close")
  local to_close = right.win
  api.nvim_win_close(to_close, true)
  wait_for(function()
    return not state().active
  end, "manual close did not collapse the partition")
  st = state()
  eq(#api.nvim_tabpage_list_wins(0), 1, "manual close did not leave one editor window")
  eq(#st.groups, 1, "manual close did not merge to one normal group")
  eq(st.groups[1].side, "single", "collapsed group has an active side")
  for _, buf in ipairs({ a, b, c }) do
    truthy(contains(st.groups[1].buffers, buf), "manual close discarded surviving buffer " .. buf)
    eq(owner_id(buf), st.groups[1].id, "manual close did not transfer owner of buffer " .. buf)
  end
end

cases.close_hidden_member_preserves_display = function()
  configured()
  local a = make_buffer("a.txt", true)
  local b, c = make_buffer("b.txt"), make_buffer("c.txt")
  api.nvim_win_set_buf(0, a)
  flush()
  must_succeed(plugin.move("right"))
  local st = state()
  local left = group_side(st, "left")
  truthy(left and contains(left.buffers, b) and contains(left.buffers, c), "left group fixture is incomplete")
  must_succeed(plugin.open(c, { win = left.win }))
  eq(api.nvim_win_get_buf(left.win), c, "failed to display the local current buffer")
  must_succeed(plugin.close(b))
  st = state()
  left = group_side(st, "left")
  eq(api.nvim_win_get_buf(left.win), c, "closing a hidden member changed the displayed buffer")
  truthy(not api.nvim_buf_is_valid(b), "closed hidden member remains valid")
  truthy(contains(left.buffers, c), "closing a hidden member removed the current buffer")
  truthy(not contains(left.buffers, b), "closed hidden member remains in the owner list")
end

cases.exclusions = function()
  configured()
  local main = make_buffer("main.txt", true)
  local other = make_buffer("other.txt")
  api.nvim_win_set_buf(0, main)
  local main_win = api.nvim_get_current_win()
  local sidebar = make_buffer("sidebar.txt")
  api.nvim_set_option_value("filetype", "snacks_picker_list", { buf = sidebar })
  local sidebar_win = new_vertical_window(sidebar)
  local layout_box = make_buffer("layout-box.txt")
  api.nvim_set_option_value("filetype", "snacks_layout_box", { buf = layout_box })
  local layout_box_win = new_vertical_window(layout_box)
  local special = {}
  for _, kind in ipairs({ "nofile", "help", "terminal", "quickfix", "prompt" }) do
    local buf = make_buffer(kind .. ".txt")
    local win = new_vertical_window(buf)
    if kind == "terminal" then
      api.nvim_set_current_win(win)
      local job = vim.fn.termopen({ "sh", "-c", "exit 0" })
      truthy(job > 0, "failed to start terminal fixture")
      vim.wait(600, function()
        return vim.fn.jobwait({ job }, 0)[1] ~= -1
      end, 10)
      eq(
        api.nvim_get_option_value("buftype", { buf = buf }),
        "terminal",
        "terminal fixture did not become a terminal buffer"
      )
    else
      api.nvim_set_option_value("buftype", kind, { buf = buf })
    end
    special[buf] = win
  end
  api.nvim_set_current_win(main_win)
  local float_buf = make_buffer("float.txt")
  local float = api.nvim_open_win(
    float_buf,
    false,
    { relative = "editor", row = 1, col = 1, width = 16, height = 2, style = "minimal" }
  )
  flush()
  local st = state()
  falsy(st.owners[sidebar], "default sidebar filetype was included as an owner")
  falsy(st.owners[layout_box], "default layout-box filetype was included as an owner")
  falsy(st.owners[float_buf], "floating buffer was included as an owner")
  local win_ids =
    { main = main_win, sidebar = sidebar_win, layout_box = layout_box_win, float = float, specials = special }
  falsy(
    group_for(st, sidebar_win),
    "excluded sidebar window became a group: " .. vim.inspect({ groups = st.groups, wins = win_ids })
  )
  falsy(group_for(st, layout_box_win), "excluded layout-box window became a group: " .. vim.inspect(st.groups))
  falsy(group_for(st, float), "floating window became a group: " .. vim.inspect(st.groups))
  for buf, win in pairs(special) do
    falsy(
      st.owners[buf],
      "special buftype was included as an owner: " .. api.nvim_get_option_value("buftype", { buf = buf })
    )
    falsy(group_for(st, win), "special buffer window became a group")
  end
  local result = plugin.move("right")
  truthy(result, "main editor window should be movable alongside excluded windows")
  wait_for(function()
    return state().active
  end, "eligible editor did not activate with excluded windows present")
  truthy(api.nvim_win_is_valid(sidebar_win), "excluded sidebar window was closed")
  truthy(api.nvim_win_is_valid(float), "excluded floating window was closed")
  eq(api.nvim_win_get_buf(sidebar_win), sidebar, "excluded sidebar buffer was replaced")
  eq(api.nvim_win_get_buf(layout_box_win), layout_box, "excluded layout-box buffer was replaced")
  eq(api.nvim_win_get_buf(float), float_buf, "excluded floating buffer was replaced")
  for buf, win in pairs(special) do
    truthy(api.nvim_win_is_valid(win), "special buffer window was closed")
    eq(api.nvim_win_get_buf(win), buf, "special buffer window was replaced")
  end
  falsy(owner_id(sidebar), "sidebar acquired ownership during partition")
  truthy(contains(listed_buffers(), other), "eligible hidden buffer was lost")
end

cases.exclusion_predicates = function()
  local main = make_buffer("main.txt", true)
  local other = make_buffer("other.txt")
  local buffer_excluded = make_buffer("buffer-predicate.txt")
  local window_excluded = make_buffer("window-predicate.txt")
  local excluded_win = new_vertical_window(window_excluded)
  local tab = api.nvim_get_current_tabpage()
  local seen_buffer = false
  local seen_window = false
  configured({
    exclude = {
      buffer = function(context)
        if context.buf == buffer_excluded and context.tabpage == tab then
          seen_buffer = true
        end
        return context.buf == buffer_excluded
      end,
      window = function(context)
        if context.win == excluded_win and context.buf == window_excluded and context.tabpage == tab then
          seen_window = true
        end
        return context.win == excluded_win
      end,
    },
  })
  api.nvim_set_current_win(api.nvim_tabpage_list_wins(tab)[1])
  -- The first window may be the predicate-excluded one; move from the one
  -- known to display the eligible main buffer instead.
  local main_win
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if api.nvim_win_get_buf(win) == main then
      main_win = win
    end
  end
  truthy(main_win, "main editor window disappeared")
  api.nvim_set_current_win(main_win)
  flush()
  local st = state()
  falsy(st.owners[buffer_excluded], "buffer predicate was ignored")
  falsy(group_for(st, excluded_win), "window predicate was ignored")
  must_succeed(plugin.move("right"))
  st = state()
  truthy(st.active, "eligible editor did not initialize alongside predicate exclusions")
  truthy(seen_buffer and seen_window, "exclude callbacks did not receive {buf, win, tabpage}")
  truthy(contains(listed_buffers(), other), "predicate exclusions discarded an eligible hidden buffer")
  truthy(api.nvim_win_is_valid(excluded_win), "predicate-excluded window was closed")
  eq(api.nvim_win_get_buf(excluded_win), window_excluded, "predicate-excluded window was replaced")
end

cases.quit_counts_excluded_listed_files = function()
  local keep = make_buffer("excluded-but-listed.txt", true)
  local close_me = make_buffer("close-me.txt")
  configured({
    closing = { last_buffer = "quit" },
    exclude = {
      buffer = function(context)
        return context.buf == keep
      end,
    },
  })
  api.nvim_win_set_buf(0, close_me)
  flush()
  local st = state()
  falsy(st.owners[keep], "custom-excluded file unexpectedly acquired an owner")
  truthy(st.owners[close_me], "closable file has no owner")
  must_succeed(plugin.close(close_me))
  truthy(api.nvim_buf_is_valid(keep), "close quit despite another listed ordinary file")
  truthy(api.nvim_get_option_value("buflisted", { buf = keep }), "excluded file was unlisted by closing another buffer")
  eq(api.nvim_buf_get_lines(keep, 0, -1, false), { "excluded-but-listed.txt" }, "excluded file content was lost")
end

cases.tabs_are_independent = function()
  configured()
  local tab1 = api.nvim_get_current_tabpage()
  local a = make_buffer("tab-a.txt", true)
  local b = make_buffer("tab-b.txt")
  api.nvim_win_set_buf(0, a)
  flush()
  must_succeed(plugin.move("right"))
  truthy(state(tab1).active, "first tab did not activate")
  api.nvim_cmd({ cmd = "tabnew" }, {})
  local tab2 = api.nvim_get_current_tabpage()
  local c = make_buffer("tab-c.txt", true)
  local d = make_buffer("tab-d.txt")
  api.nvim_win_set_buf(0, c)
  flush()
  must_succeed(plugin.move("left"))
  truthy(state(tab2).active, "second tab did not activate")
  truthy(state(tab1).active, "activity in second tab changed first tab")
  local first_owner = owner_id(a, tab1)
  local second_owner = owner_id(c, tab2)
  truthy(first_owner and second_owner, "tab-local owner lookup failed")
  falsy(owner_id(a, tab2), "buffer owner leaked to another tab")
  falsy(owner_id(c, tab1), "buffer owner leaked to another tab")
  truthy(owner_id(b, tab1), "first tab hidden buffer lost its owner")
  truthy(owner_id(d, tab2), "second tab hidden buffer lost its owner")
  local copy = plugin.get_owner(a, { tabpage = tab1 })
  copy.buffers[1] = -999
  truthy(
    not contains(plugin.get_owner(a, { tabpage = tab1 }).buffers, -999),
    "get_owner returned mutable internal state"
  )
end

cases.disable_reenable_and_setup_idempotence = function()
  local map_old_x = function() end
  local map_old_y = function() end
  vim.keymap.set("n", "x", map_old_x, { desc = "user-old-x" })
  vim.keymap.set("n", "y", map_old_y, { desc = "user-old-y" })
  configured({ keymaps = { move_left = "x", move_right = "y" } })
  local map_after_setup = vim.fn.maparg("x", "n", false, true)
  truthy(map_after_setup and map_after_setup.desc ~= "user-old-x", "configured keymap was not installed")
  plugin.setup({ keymaps = { move_left = "x", move_right = "y" } })
  eq(vim.fn.maparg("x", "n", false, true).desc, map_after_setup.desc, "setup was not idempotent for keymaps")
  vim.keymap.set("n", "x", function() end, { desc = "user-replaced-x" })

  local a = make_buffer("a.txt", true)
  local b, c = make_buffer("b.txt"), make_buffer("c.txt")
  api.nvim_win_set_buf(0, a)
  flush()
  must_succeed(plugin.move("right"))
  local st = state()
  local right = group_side(st, "right")
  must_succeed(plugin.move("right", { buf = c }))
  st = state()
  right = group_side(st, "right")
  must_succeed(plugin.open(a, { win = right.win }))
  local wins_before = api.nvim_tabpage_list_wins(0)
  local buffers_before = current_buffers(wins_before)
  truthy(plugin.is_enabled(), "plugin should be enabled after setup")
  plugin.disable()
  falsy(plugin.is_enabled(), "disable did not turn off the plugin")
  eq(api.nvim_tabpage_list_wins(0), wins_before, "disable changed editor windows")
  eq(current_buffers(wins_before), buffers_before, "disable changed displayed buffers")
  eq(vim.fn.maparg("x", "n", false, true).desc, "user-replaced-x", "disable overwrote a later user keymap")
  eq(vim.fn.maparg("y", "n", false, true).desc, "user-old-y", "disable did not restore the previous keymap")
  api.nvim_cmd({ cmd = "BufferGroupsEnable" }, {})
  truthy(plugin.is_enabled(), "enable command was unavailable after disable")
  local reenabled_move = plugin.move("left")
  truthy(reenabled_move, "re-enabled plugin did not lazily adopt existing windows")
  truthy(state().active, "re-enable did not adopt current layout on first move")
end

cases.buffer_local_map_shadow_and_restore = function()
  local current = api.nvim_get_current_buf()
  vim.keymap.set("n", "x", function() end, { buffer = current, desc = "buffer-local-x" })
  vim.keymap.set("n", "y", function() end, { desc = "global-old-y" })
  configured({ keymaps = { move_left = "x", move_right = "y" } })
  eq(vim.fn.maparg("x", "n", false, true).desc, "buffer-local-x", "setup replaced a buffer-local shadow")
  local global_x
  for _, mapping in ipairs(api.nvim_get_keymap("n")) do
    if mapping.lhs == "x" then
      global_x = mapping
    end
  end
  truthy(global_x, "plugin did not install its global mapping below the buffer-local shadow")
  plugin.disable()
  eq(vim.fn.maparg("x", "n", false, true).desc, "buffer-local-x", "disable removed a buffer-local mapping")
  local restored_y = vim.fn.maparg("y", "n", false, true)
  eq(restored_y.desc, "global-old-y", "disable did not restore the previous global mapping")
  local global_x_after
  for _, mapping in ipairs(api.nvim_get_keymap("n")) do
    if mapping.lhs == "x" then
      global_x_after = mapping
    end
  end
  falsy(global_x_after, "disable left the plugin global mapping installed")
end

local case_name = assert(vim.env.BG_TEST_CASE, "BG_TEST_CASE is required")
local case = assert(cases[case_name], "unknown test case: " .. case_name)
local ok, err = xpcall(case, debug.traceback)
local status_path = assert(vim.env.BG_TEST_STATUS, "BG_TEST_STATUS is required")
vim.fn.writefile({ ok and "ok" or tostring(err) }, status_path)
if ok then
  print("PASS core " .. case_name)
  vim.cmd("qa!")
else
  io.stderr:write("FAIL core " .. case_name .. "\n" .. tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
