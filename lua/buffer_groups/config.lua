local M = {}
M.defaults = {
  keymaps = {},
  exclude = {
    floating = true,
    unlisted = true,
    filetypes = { "snacks_layout_box", "snacks_picker_list" },
    buftypes = { "nofile", "help", "terminal", "quickfix", "prompt" },
    bufname = {},
    window = nil,
    buffer = nil,
  },
  behavior = {
    follow_buffer = true,
    empty_group = "close",
    existing_buffer = "focus_owner",
    single_buffer_split = "require_two",
    manual_window_close = "merge",
  },
  closing = { last_buffer = "empty", save_others = false },
}
local function fail(s)
  error("buffer_groups: " .. s, 3)
end
local function validate(t, schema, path)
  for k, v in pairs(t) do
    if path ~= "keymaps" and schema[k] == nil and not ((path == "exclude") and (k == "window" or k == "buffer")) then
      fail("unknown option " .. path .. "." .. tostring(k))
    end
    if
      type(schema[k]) == "table"
      and path ~= "keymaps"
      and not (path == "exclude" and k ~= "floating" and k ~= "unlisted")
    then
      if type(v) ~= "table" then
        fail(path .. "." .. k .. " must be a table")
      end
      validate(v, schema[k], k)
    end
  end
end
function M.resolve(opts)
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    fail("setup options must be a table")
  end
  validate(opts, M.defaults, "setup")
  local c = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  for _, key in ipairs({ "filetypes", "buftypes", "bufname" }) do
    if opts.exclude and opts.exclude[key] ~= nil then
      c.exclude[key] = vim.deepcopy(opts.exclude[key])
    end
  end
  if c.exclude.floating ~= true then
    fail("exclude.floating must be true; floating owners are unsupported")
  end
  if type(c.exclude.unlisted) ~= "boolean" then
    fail("exclude.unlisted must be boolean")
  end
  for _, k in ipairs({ "filetypes", "buftypes", "bufname" }) do
    if type(c.exclude[k]) ~= "table" or not vim.islist(c.exclude[k]) then
      fail("exclude." .. k .. " must be a list")
    end
    for _, v in ipairs(c.exclude[k]) do
      if type(v) ~= "string" then
        fail("exclude." .. k .. " entries must be strings")
      end
    end
  end
  for _, k in ipairs({ "buffer", "window" }) do
    if c.exclude[k] ~= nil and type(c.exclude[k]) ~= "function" then
      fail("exclude." .. k .. " must be a function")
    end
  end
  local choices = {
    empty_group = { close = true },
    existing_buffer = { focus_owner = true, transfer = true },
    single_buffer_split = { require_two = true, new_buffer = true },
    manual_window_close = { merge = true },
  }
  if type(c.behavior.follow_buffer) ~= "boolean" then
    fail("behavior.follow_buffer must be boolean")
  end
  for k, values in pairs(choices) do
    if not values[c.behavior[k]] then
      fail("invalid behavior." .. k)
    end
  end
  if c.closing.last_buffer ~= "empty" and c.closing.last_buffer ~= "quit" then
    fail("invalid closing.last_buffer")
  end
  if type(c.closing.save_others) ~= "boolean" then
    fail("closing.save_others must be boolean")
  end
  local keys = {
    move_left = true,
    move_right = true,
    previous = true,
    next = true,
    close = true,
    close_group = true,
    close_others = true,
    toggle_fullscreen = true,
  }
  for k, v in pairs(c.keymaps) do
    if not keys[k] then
      fail("unknown keymap " .. k)
    end
    if type(v) ~= "string" then
      fail("keymaps." .. k .. " must be a string")
    end
  end
  return c
end
return M
