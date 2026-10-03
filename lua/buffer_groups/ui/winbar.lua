-- Window lifecycle and composition. Native tabs are supplied by the optional
-- Bufferline compatibility module after Bufferline has completed setup.
local M = {}
local api = vim.api
local cfg = { enabled = false, position = "prepend", alignment = "left", reveal_on_use = false }
local backend, filter, core
local requested, active, paused, queued = false, false, false, false
local owned, cache, clicks, tokens = {}, {}, {}, {}
local snapshots = {}
-- Window-local options are remembered separately for each displayed buffer.
-- Retain originals after detaching so a later BufEnter can remove a stored wrapper.
local history = {}
local next_token = 0
local warned = {}

local function warn(message)
  if warned[message] then
    return
  end
  warned[message] = true
  vim.schedule(function()
    vim.notify("buffer_groups: " .. message, vim.log.levels.WARN)
  end)
end

local function current_option(win)
  return api.nvim_get_option_value("winbar", { win = win, scope = "local" })
end

local function original_content(win, buf, value)
  local source = history[win]
  if not source or value ~= source.expression then
    local inherited = value:match("^%%{%%v:lua%.__buffer_groups_winbar%.render%((%d+)%)%%}$")
    source = inherited and history[tonumber(inherited)] or nil
  end
  if source and value == source.expression then
    local saved = source.buffers[buf] or source
    return saved.original, saved.content
  end
  return value, value ~= "" and value or api.nvim_get_option_value("winbar", { scope = "global" })
end

local function restore_stored(win)
  if not api.nvim_win_is_valid(win) then
    return
  end
  local value = current_option(win)
  local original = original_content(win, api.nvim_win_get_buf(win), value)
  if original ~= value then
    api.nvim_set_option_value("winbar", original, { win = win, scope = "local" })
  end
end

local function restore(win)
  restore_stored(win)
  owned[win], cache[win] = nil, nil
end

local function restore_all()
  for _, win in ipairs(api.nvim_list_wins()) do
    restore_stored(win)
  end
  owned = {}
  cache, clicks, tokens = {}, {}, {}
end

local function install(win, group_id)
  local previous = owned[win]
  local buf, value = api.nvim_win_get_buf(win), current_option(win)
  if previous and previous.buf == buf and value ~= previous.expression then
    -- A change while displaying the same buffer is an external takeover.
    error("another provider replaced winbar; use position=manual for explicit composition")
  end
  if previous and previous.buf == buf then
    return previous
  end

  -- BufEnter may restore a different local option without emitting OptionSet.
  -- Adopt that buffer's original content before reinstalling our expression.
  local original, content = original_content(win, buf, value)
  previous = previous
    or history[win]
    or {
      expression = "%{%v:lua.__buffer_groups_winbar.render(" .. win .. ")%}",
      buffers = {},
    }
  previous.original, previous.content = original, content
  previous.buf, previous.group_id = buf, group_id
  previous.buffers[buf] = { original = original, content = content }
  owned[win], history[win] = previous, previous
  if value ~= previous.expression then
    api.nvim_set_option_value("winbar", previous.expression, { win = win, scope = "local" })
  end
  return previous
end

local function fragment(original)
  if original:sub(1, 2) == "%!" then
    return "%{%" .. original:sub(3) .. "%}"
  end
  return original
end

local function register_click(snapshot, group, buf, action)
  local key = table.concat({ snapshot.tabpage, group.id, buf, action }, ":")
  local token = tokens[key]
  if not token then
    next_token = next_token + 1
    token, tokens[key] = next_token, next_token
  end
  clicks[token] = { tabpage = snapshot.tabpage, group_id = group.id, buf = buf, action = action }
  return "%" .. token .. "@v:lua.__buffer_groups_winbar.click@"
end

function M.refresh()
  queued = false
  if not active or not core or not core.is_enabled() then
    return
  end
  local ok, err = pcall(function()
    local snapshot = core.get_state()
    snapshots[snapshot.tabpage] = snapshot
    local multiple_groups = #snapshot.groups > 1
    local models = multiple_groups and backend.prepare(snapshot, filter) or {}
    local managed = {}
    for _, group in ipairs(snapshot.groups) do
      local win = group.win
      if
        multiple_groups
        and win
        and api.nvim_win_is_valid(win)
        and group.current ~= nil
        and api.nvim_win_get_buf(win) == group.current
        and not group.hidden
        and group.tabs_visible ~= false
      then
        managed[win] = true
        local previous
        if cfg.position ~= "manual" then
          previous = install(win, group.id)
        end
        if cfg.position == "manual" or previous then
          local original = previous and previous.content or ""
          if cfg.position == "replace" then
            original = ""
          end
          local total = api.nvim_win_get_width(win)
          local external = original ~= ""
              and api.nvim_eval_statusline(original, {
                winid = win,
                use_winbar = true,
                maxwidth = total,
              }).width
            or 0
          local available = math.max(0, total - external)
          local tabs = backend.render(models[group.id] or {}, available, win, function(buf, action)
            return register_click(snapshot, group, buf, action)
          end)
          local actual = api.nvim_eval_statusline(tabs, { winid = win, use_winbar = true, maxwidth = total }).width
          local blank = math.max(0, available - actual)
          local left = cfg.alignment == "right" and blank or cfg.alignment == "center" and math.floor(blank / 2) or 0
          local fill = "%#BufferLineFill#"
          local aligned = fill .. string.rep(" ", left) .. tabs .. "%T" .. fill .. string.rep(" ", blank - left)
          local content = fragment(original)
          cache[win] = {
            tabs = tabs,
            tabpage = snapshot.tabpage,
            full = cfg.position == "append" and content .. aligned or aligned .. content,
          }
        end
      end
    end
    for _, win in ipairs(api.nvim_tabpage_list_wins(snapshot.tabpage)) do
      if cfg.position == "manual" or not managed[win] and not owned[win] then
        restore_stored(win)
      end
    end
    for win in pairs(owned) do
      if not api.nvim_win_is_valid(win) then
        owned[win], cache[win] = nil, nil
      elseif api.nvim_win_get_tabpage(win) == snapshot.tabpage and (not managed[win] or cfg.position == "manual") then
        restore(win)
      end
    end
    for win, item in pairs(cache) do
      if not api.nvim_win_is_valid(win) or item.tabpage == snapshot.tabpage and not managed[win] then
        cache[win] = nil
      end
    end
    for key, token in pairs(tokens) do
      local target = clicks[token]
      if
        target
        and (
          not api.nvim_tabpage_is_valid(target.tabpage)
          or target.tabpage == snapshot.tabpage and snapshot.owners[target.buf] ~= target.group_id
        )
      then
        tokens[key], clicks[token] = nil, nil
      end
    end
    vim.cmd("redrawstatus")
    vim.cmd("redrawtabline")
  end)
  if not ok then
    active = false
    restore_all()
    warn("winbar disabled: " .. tostring(err))
    vim.cmd("redrawtabline")
  end
end

local function queue()
  if not queued and active then
    queued = true
    vim.schedule(M.refresh)
  end
end

local function observe()
  local group = api.nvim_create_augroup("BufferGroupsWinbar", { clear = true })
  api.nvim_create_autocmd("User", { group = group, pattern = "BufferGroupsChanged", callback = queue })
  api.nvim_create_autocmd({
    "WinResized",
    "VimResized",
    "TabEnter",
    "BufModifiedSet",
    "BufFilePost",
    "DiagnosticChanged",
    "ColorScheme",
    "CursorMoved",
    "CursorMovedI",
    "BufEnter",
    "WinEnter",
  }, {
    group = group,
    callback = function(event)
      if active then
        queue()
      elseif event.event == "BufEnter" or event.event == "WinEnter" then
        restore_stored(api.nvim_get_current_win())
      end
    end,
  })
  api.nvim_create_autocmd("OptionSet", { group = group, pattern = "winbar", callback = queue })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      vim.schedule(function()
        if not api.nvim_buf_is_valid(event.buf) then
          for _, source in pairs(history) do
            source.buffers[event.buf] = nil
          end
        end
      end)
    end,
  })
end

function M.configure(options)
  restore_all()
  cfg = vim.tbl_extend("force", cfg, options or {})
  requested = cfg.enabled == true
  M.resume()
end

function M.attach(native, host_filter, supplied_core)
  backend, filter, core = native, host_filter, supplied_core
  paused = false
  observe()
  M.resume()
  return true
end

function M.resume()
  paused = false
  core = core or package.loaded.buffer_groups
  active = requested and backend ~= nil and core ~= nil and core.is_enabled()
  if active then
    queue()
  end
end

function M.suspend()
  paused, active = true, false
  restore_all()
end

function M.set_enabled(value)
  if value and not backend then
    return false, "winbar requires a compatible Bufferline adapter; call adapter.attach() after bufferline.setup()"
  end
  requested, cfg.enabled = value, value
  restore_all()
  active = value and not paused and core ~= nil and core.is_enabled()
  if active then
    queue()
  end
  vim.cmd("redrawstatus")
  vim.cmd("redrawtabline")
  return true, active
end

function M.get_snapshot()
  return snapshots[api.nvim_get_current_tabpage()]
end

function M.is_enabled()
  return active == true
end

function M.original_option(win)
  if not api.nvim_win_is_valid(win) then
    return
  end
  local value = current_option(win)
  local original = original_content(win, api.nvim_win_get_buf(win), value)
  if original ~= value then
    return original
  end
end

function M.after_restore(group)
  -- The core deliberately restored the real local option. Adopt that value,
  -- rather than treating restoration on the surviving window as a takeover.
  if group.win then
    owned[group.win], cache[group.win] = nil, nil
  end
  if active then
    -- Reinstall only after reconciliation determines the current group count.
    queue()
  end
end

-- Public fragment API, intentionally free of state reconciliation and writes.
function M.render(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  local item = cache[win]
  return active and item and item.tabs or ""
end

function M.click(token, _, button, modifiers)
  local target = clicks[token]
  if
    not active
    or not target
    or not api.nvim_buf_is_valid(target.buf)
    or not api.nvim_tabpage_is_valid(target.tabpage)
  then
    return
  end
  local owner = core.get_owner(target.buf, { tabpage = target.tabpage })
  if not owner or owner.id ~= target.group_id or owner.hidden or owner.tabs_visible == false or not owner.win then
    return
  end
  local function execute()
    if not active or not api.nvim_buf_is_valid(target.buf) or not api.nvim_tabpage_is_valid(target.tabpage) then
      return
    end
    local current_owner = core.get_owner(target.buf, { tabpage = target.tabpage })
    if
      not current_owner
      or current_owner.id ~= target.group_id
      or current_owner.hidden
      or current_owner.tabs_visible == false
      or not current_owner.win
      or not api.nvim_win_is_valid(current_owner.win)
    then
      return
    end
    local options = backend.options()
    local command
    if target.action == "close" then
      command = options.close_command
    else
      command = options[({ l = "left_mouse_command", r = "right_mouse_command", m = "middle_mouse_command" })[button]]
    end
    if command == false or command == nil then
      return
    end
    api.nvim_set_current_win(current_owner.win)
    if type(command) == "function" then
      command(target.buf)
    elseif type(command) == "string" then
      vim.cmd(string.format(command, target.buf))
    end
    queue()
  end
  vim.schedule(function()
    local ok, err = pcall(execute)
    if not ok then
      vim.notify("buffer_groups: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

_G.__buffer_groups_winbar = {
  render = function(win)
    local item = cache[win]
    return active and item and item.full or ""
  end,
  click = M.click,
}

return M
