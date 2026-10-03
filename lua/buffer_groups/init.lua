local M = {}
local api = vim.api
local config = require("buffer_groups.config")
local cfg = config.resolve()
local enabled, busy, tabs, next_id, maps = false, false, {}, 0, {}
local pending = {}
local homes = {}
local function tabid(opts)
  local t = opts and opts.tabpage or api.nvim_get_current_tabpage()
  if t == 0 then
    t = api.nvim_get_current_tabpage()
  end
  return t
end
local function eligible(buf, win, tab)
  if not api.nvim_buf_is_valid(buf) then
    return false
  end
  if cfg.exclude.unlisted and not vim.bo[buf].buflisted then
    return false
  end
  if
    vim.tbl_contains(cfg.exclude.buftypes, vim.bo[buf].buftype)
    or vim.tbl_contains(cfg.exclude.filetypes, vim.bo[buf].filetype)
  then
    return false
  end
  for _, pattern in ipairs(cfg.exclude.bufname) do
    if api.nvim_buf_get_name(buf):match(pattern) then
      return false
    end
  end
  if cfg.exclude.buffer and cfg.exclude.buffer({ buf = buf, win = win, tabpage = tab }) then
    return false
  end
  if win then
    if not api.nvim_win_is_valid(win) or api.nvim_win_get_config(win).relative ~= "" then
      return false
    end
    if cfg.exclude.window and cfg.exclude.window({ buf = buf, win = win, tabpage = tab }) then
      return false
    end
  end
  return true
end
local function editor_windows(tab)
  local out = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if eligible(api.nvim_win_get_buf(win), win, tab) then
      out[#out + 1] = win
    end
  end
  table.sort(out, function(a, b)
    local pa, pb = api.nvim_win_get_position(a), api.nvim_win_get_position(b)
    return pa[2] < pb[2] or pa[2] == pb[2] and pa[1] < pb[1]
  end)
  return out
end
local function group(win)
  next_id = next_id + 1
  return { id = next_id, win = win, side = "single", buffers = {}, current = nil, hidden = false }
end
local function owner(s, buf)
  for _, g in ipairs(s.groups) do
    if vim.tbl_contains(g.buffers, buf) then
      return g
    end
  end
end
local function available(buf, tab)
  if not eligible(buf, nil, tab) then
    return false
  end
  local shown, suitable = false, false
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == buf then
      shown = true
      if api.nvim_win_get_tabpage(win) == tab and eligible(buf, win, tab) then
        suitable = true
      end
    end
  end
  if shown then
    return suitable
  end
  return homes[buf] == nil or homes[buf] == tab
end
local function bywin(s, win)
  for _, g in ipairs(s.groups) do
    if g.win == win then
      return g
    end
  end
end
local function remove(g, buf)
  for i = #g.buffers, 1, -1 do
    if g.buffers[i] == buf then
      table.remove(g.buffers, i)
    end
  end
end
local function add(g, buf)
  if not vim.tbl_contains(g.buffers, buf) then
    g.buffers[#g.buffers + 1] = buf
  end
end
local function event(tab, reason)
  api.nvim_exec_autocmds(
    "User",
    { pattern = "BufferGroupsChanged", modeline = false, data = { reason = reason, tabpage = tab } }
  )
  vim.cmd("redrawtabline")
end
local function sides(s)
  if s.fullscreen then
    s.active = #s.groups > 1
    return
  end
  if #s.groups == 1 then
    s.active = false
    s.groups[1].side = "single"
    return
  end
  table.sort(s.groups, function(a, b)
    return api.nvim_win_get_position(a.win)[2] < api.nvim_win_get_position(b.win)[2]
  end)
  s.groups[1].side = "left"
  s.groups[2].side = "right"
  s.active = true
end
local function save_window(g)
  g.saved = {
    buf = api.nvim_win_get_buf(g.win),
    width = api.nvim_win_get_width(g.win),
    height = api.nvim_win_get_height(g.win),
    options = {},
    view = api.nvim_win_call(g.win, function()
      return vim.fn.winsaveview()
    end),
  }
  for name, info in pairs(api.nvim_get_all_options_info()) do
    if info.scope == "win" then
      local ok, value = pcall(api.nvim_get_option_value, name, { win = g.win, scope = "local" })
      if ok then
        g.saved.options[name] = value
      end
    end
  end
end
local function restore_window(g, restore_view)
  if not g.saved then
    return
  end
  for name, value in pairs(g.saved.options) do
    pcall(api.nvim_set_option_value, name, value, { win = g.win, scope = "local" })
  end
  pcall(api.nvim_win_set_width, g.win, g.saved.width)
  pcall(api.nvim_win_set_height, g.win, g.saved.height)
  if restore_view ~= false and api.nvim_win_get_buf(g.win) == g.saved.buf then
    pcall(api.nvim_win_call, g.win, function()
      vim.fn.winrestview(g.saved.view)
    end)
  end
end
local function restore_unmanaged_widths(s)
  for win, width in pairs(s.unmanaged_widths or {}) do
    if api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_set_width, win, width)
    end
  end
end
local function restore_hidden(s)
  local anchor
  for _, g in ipairs(s.groups) do
    if not g.hidden and g.win and api.nvim_win_is_valid(g.win) then
      anchor = g
    end
  end
  if not anchor then
    local wins = editor_windows(s.tabpage)
    if wins[1] then
      anchor = { win = wins[1] }
    end
    if not anchor then
      for _, win in ipairs(api.nvim_tabpage_list_wins(s.tabpage)) do
        if api.nvim_win_get_config(win).relative == "" then
          anchor = { win = win }
          break
        end
      end
    end
  end
  local anchor_view = anchor and api.nvim_win_call(anchor.win, function()
    return vim.fn.winsaveview()
  end)
  for _, g in ipairs(s.groups) do
    if g.hidden then
      if not anchor then
        error("cannot restore hidden group without an editor window")
      end
      local buf = g.current
      if not buf or not api.nvim_buf_is_valid(buf) or not vim.tbl_contains(g.buffers, buf) then
        buf = g.buffers[1]
      end
      if not buf then
        buf = api.nvim_create_buf(true, false)
        add(g, buf)
      end
      local win = api.nvim_win_call(anchor.win, function()
        return api.nvim_open_win(buf, false, { win = anchor.win, split = g.side == "left" and "left" or "right" })
      end)
      g.win, g.hidden, g.current = win, false, buf
      restore_window(g)
    end
  end
  if anchor then
    restore_window(anchor, false)
  end
  restore_unmanaged_widths(s)
  if anchor_view then
    pcall(api.nvim_win_call, anchor.win, function()
      vim.fn.winrestview(anchor_view)
    end)
  end
  s.fullscreen = false
  local all_valid = true
  for _, g in ipairs(s.groups) do
    if not g.win or not api.nvim_win_is_valid(g.win) then
      all_valid = false
    end
  end
  if all_valid then
    sides(s)
  end
end
local function reveal(s, g)
  if g.hidden then
    restore_hidden(s)
  end
end
local function ensure(tab, win)
  if tabs[tab] then
    return tabs[tab]
  end
  local wins = editor_windows(tab)
  win = win or api.nvim_tabpage_get_win(tab)
  if not vim.tbl_contains(wins, win) then
    win = wins[1]
  end
  local s = { tabpage = tab, active = false, fullscreen = false, groups = {}, last = nil }
  tabs[tab] = s
  if win then
    local g = group(win)
    s.groups = { g }
    s.last = g.id
    for _, b in ipairs(api.nvim_list_bufs()) do
      if available(b, tab) then
        homes[b] = homes[b] or tab
        add(g, b)
      end
    end
    g.current = api.nvim_win_get_buf(win)
  end
  return s
end
local function reconcile(tab)
  local s = tabs[tab]
  if not s or not api.nvim_tabpage_is_valid(tab) then
    return
  end
  if not s.active and s.groups[1] then
    local normal = s.groups[1]
    if
      normal.win
      and api.nvim_win_is_valid(normal.win)
      and not eligible(api.nvim_win_get_buf(normal.win), normal.win, tab)
    then
      local editors = editor_windows(tab)
      if editors[1] then
        normal.win = editors[1]
      end
    end
  end
  local gone = {}
  if s.fullscreen then
    for _, g in ipairs(s.groups) do
      if not g.hidden and (not g.win or not api.nvim_win_is_valid(g.win)) then
        -- A manually closed visible owner must reveal the retained hidden owner.
        restore_hidden(s)
        break
      end
    end
  end
  for i = #s.groups, 1, -1 do
    local g = s.groups[i]
    if not g.hidden and (not g.win or not api.nvim_win_is_valid(g.win)) then
      table.remove(s.groups, i)
      table.insert(gone, 1, g)
    else
      for j = #g.buffers, 1, -1 do
        if not eligible(g.buffers[j], nil, tab) then
          table.remove(g.buffers, j)
        end
      end
    end
  end
  if #s.groups == 0 then
    local wins = editor_windows(tab)
    if wins[1] then
      s.groups = { group(wins[1]) }
    end
  end
  if s.groups[1] then
    for _, g in ipairs(gone) do
      for _, b in ipairs(g.buffers) do
        if available(b, tab) then
          homes[b] = homes[b] or tab
          add(s.groups[1], b)
        end
      end
    end
    for _, g in ipairs(s.groups) do
      if not g.hidden then
        local b = api.nvim_win_get_buf(g.win)
        if eligible(b, g.win, tab) and not owner(s, b) then
          add(g, b)
        end
        g.current = vim.tbl_contains(g.buffers, b) and b or nil
      elseif not vim.tbl_contains(g.buffers, g.current) then
        g.current = g.buffers[1]
      end
    end
    if not s.active then
      for _, b in ipairs(api.nvim_list_bufs()) do
        if available(b, tab) then
          homes[b] = homes[b] or tab
          add(s.groups[1], b)
        end
      end
    else
      local remembered = s.groups[1]
      for _, g in ipairs(s.groups) do
        if g.id == s.last then
          remembered = g
        end
      end
      if remembered.hidden then
        for _, g in ipairs(s.groups) do
          if not g.hidden then
            remembered = g
            break
          end
        end
      end
      for _, b in ipairs(api.nvim_list_bufs()) do
        if available(b, tab) and not owner(s, b) then
          local manual = false
          for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
            if not bywin(s, w) and api.nvim_win_get_buf(w) == b then
              manual = true
            end
          end
          if not manual then
            homes[b] = homes[b] or tab
            add(remembered, b)
          end
        end
      end
    end
    local was_busy = busy
    busy = true
    for i = #s.groups, 1, -1 do
      local g = s.groups[i]
      if #g.buffers == 0 and #s.groups > 1 then
        if s.fullscreen and not g.hidden then
          restore_hidden(s)
        end
        local ok = g.hidden or pcall(api.nvim_win_close, g.win, false)
        if ok then
          table.remove(s.groups, i)
        end
        if #s.groups < 2 then
          s.fullscreen = false
        end
      elseif #g.buffers > 0 and not g.hidden then
        local shown = api.nvim_win_get_buf(g.win)
        if not vim.tbl_contains(g.buffers, shown) and eligible(shown, nil, tab) then
          local ok = pcall(api.nvim_win_set_buf, g.win, g.buffers[1])
          if ok then
            g.current = g.buffers[1]
          end
        end
      end
    end
    busy = was_busy
    sides(s)
    local remembered = false
    for _, g in ipairs(s.groups) do
      if g.id == s.last then
        remembered = true
      end
    end
    if not remembered and s.groups[1] then
      s.last = s.groups[1].id
    end
  else
    s.active = false
  end
end
local function run(reason, tab, fn)
  if not enabled then
    return false, "buffer_groups is disabled"
  end
  if busy then
    return false, "buffer_groups is busy"
  end
  if not api.nvim_tabpage_is_valid(tab) then
    return false, "invalid tabpage"
  end
  local reconciled, reconcile_error = pcall(reconcile, tab)
  if not reconciled then
    return false, tostring(reconcile_error)
  end
  local before = vim.deepcopy(tabs)
  local before_pending = vim.deepcopy(pending)
  local before_homes = vim.deepcopy(homes)
  local focused = api.nvim_get_current_win()
  local visible = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    visible[win] = api.nvim_win_get_buf(win)
  end
  local known = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    known[buf] = true
  end
  busy = true
  local ok, a, b = pcall(fn)
  if not ok or a == false then
    -- Restore native owners that were hidden before restoring the state snapshot.
    local snapshot = before[tab]
    if snapshot then
      for _, g in ipairs(snapshot.groups) do
        if not g.hidden and (not g.win or not api.nvim_win_is_valid(g.win)) then
          local original_side = g.side
          for _, live in ipairs((tabs[tab] or {}).groups or {}) do
            if live.id == g.id and live.saved then
              g.saved = vim.deepcopy(live.saved)
            end
          end
          g.win, g.hidden = nil, true
          pcall(restore_hidden, { tabpage = tab, groups = { g } })
          g.side = original_side
        end
        if g.win and api.nvim_win_is_valid(g.win) then
          visible[g.win] = g.current or visible[g.win] or api.nvim_win_get_buf(g.win)
        end
      end
    end
    -- Restore window displays before closing any split created by the operation.
    for win, buf in pairs(visible) do
      if api.nvim_win_is_valid(win) and buf and api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_win_set_buf, win, buf)
      end
    end
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if not visible[win] then
        local buf = api.nvim_win_get_buf(win)
        local bufhidden = vim.bo[buf].bufhidden
        vim.bo[buf].bufhidden = "hide"
        pcall(api.nvim_win_hide, win)
        if api.nvim_buf_is_valid(buf) then
          vim.bo[buf].bufhidden = bufhidden
        end
      end
    end
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if not known[buf] and not vim.bo[buf].modified then
        pcall(api.nvim_buf_delete, buf, { force = false })
      end
    end
    -- A failed reveal can have created windows for previously hidden groups.
    if snapshot and snapshot.fullscreen then
      for _, g in ipairs(snapshot.groups) do
        if g.hidden then
          g.win = nil
        end
      end
    end
    tabs = before
    pending = before_pending
    homes = before_homes
    if api.nvim_win_is_valid(focused) then
      pcall(api.nvim_set_current_win, focused)
    end
    busy = false
    return false, ok and b or tostring(a)
  end
  busy = false
  reconcile(tab)
  event(tab, reason)
  return true, a
end
local function target(opts, remember)
  local tab = tabid(opts)
  local win = opts and opts.win or api.nvim_get_current_win()
  if win == 0 then
    win = api.nvim_get_current_win()
  end
  if not api.nvim_win_is_valid(win) or api.nvim_win_get_tabpage(win) ~= tab then
    return nil, nil, nil, "invalid window for tabpage"
  end
  if not remember and not eligible(api.nvim_win_get_buf(win), win, tab) then
    return nil, nil, nil, "current window or buffer is excluded"
  end
  local s = ensure(tab, win)
  local g = bywin(s, win)
  if not s.active and not g and eligible(api.nvim_win_get_buf(win), win, tab) and s.groups[1] then
    g = s.groups[1]
    g.win = win
    g.current = api.nvim_win_get_buf(win)
  end
  if opts and opts.group then
    g = nil
    for _, v in ipairs(s.groups) do
      if v.id == opts.group then
        g = v
      end
    end
  end
  if not g and remember and not (opts and opts.win) then
    for _, v in ipairs(s.groups) do
      if v.id == s.last then
        g = v
      end
    end
  end
  return s, g, tab
end
local function display(g, buf, focus)
  for _, s in pairs(tabs) do
    for _, candidate in ipairs(s.groups) do
      if candidate == g then
        reveal(s, g)
        break
      end
    end
  end
  api.nvim_win_set_buf(g.win, buf)
  g.current = buf
  if focus then
    api.nvim_set_current_win(g.win)
  end
end
local function empty_buffer(g)
  local b = api.nvim_create_buf(true, false)
  add(g, b)
  display(g, b, false)
  return b
end
local function vacate(s, g, buf)
  local replacement = g.buffers[1]
  if replacement then
    if g.hidden then
      g.current = replacement
    elseif api.nvim_win_get_buf(g.win) == buf then
      display(g, replacement, false)
    end
  elseif #s.groups > 1 then
    if s.fullscreen and not g.hidden then
      restore_hidden(s)
    end
    if not g.hidden then
      api.nvim_win_close(g.win, false)
    end
    for i, v in ipairs(s.groups) do
      if v == g then
        table.remove(s.groups, i)
        break
      end
    end
    s.fullscreen = false
    sides(s)
  else
    empty_buffer(g)
  end
end
local function transfer(s, src, dst, buf, focus)
  if src == dst then
    display(dst, buf, focus)
    return buf
  end
  display(dst, buf, focus)
  if src then
    remove(src, buf)
  end
  add(dst, buf)
  if src then
    vacate(s, src, buf)
  end
  s.last = dst.id
  return buf
end
function M.get_state(opts)
  local tab = tabid(opts)
  if not api.nvim_tabpage_is_valid(tab) then
    return { enabled = enabled, tabpage = tab, active = false, fullscreen = false, groups = {}, owners = {} }
  end
  local s = ensure(tab)
  if not busy then
    reconcile(tab)
  end
  local out = {
    enabled = enabled,
    tabpage = tab,
    active = s.active,
    fullscreen = s.fullscreen == true,
    groups = vim.deepcopy(s.groups),
    owners = {},
  }
  local focused = bywin(s, api.nvim_get_current_win())
  out.focused = focused and focused.id or s.last
  for _, g in ipairs(s.groups) do
    for _, b in ipairs(g.buffers) do
      out.owners[b] = g.id
    end
  end
  return out
end
function M.get_owner(buf, opts)
  local s = M.get_state(opts)
  for _, g in ipairs(s.groups) do
    if vim.tbl_contains(g.buffers, buf) then
      return vim.deepcopy(g)
    end
  end
end
function M.is_enabled()
  return enabled
end
function M.register(buf, opts)
  opts = opts or {}
  buf = buf or opts.buf or api.nvim_get_current_buf()
  local tab = tabid(opts)
  return run("register", tab, function()
    local s, g, _, err = target(opts, true)
    if not g then
      return false, err or "no managed editor window"
    end
    if not eligible(buf, nil, tab) then
      return false, "buffer is excluded or invalid"
    end
    local src = owner(s, buf)
    local newly_added = pending[buf]
    pending[buf] = nil
    if src and src ~= g then
      if not newly_added and cfg.behavior.existing_buffer == "focus_owner" then
        if src.hidden then
          display(src, buf, true)
          s.last = src.id
        end
        return buf
      end
      return transfer(s, src, g, buf, false)
    end
    add(g, buf)
    return buf
  end)
end
function M.open(buf, opts)
  opts = opts or {}
  buf = buf or opts.buf or api.nvim_get_current_buf()
  local tab = tabid(opts)
  return run("open", tab, function()
    local s, g, _, err = target(opts, true)
    if not g then
      return false, err or "no managed editor window"
    end
    if not eligible(buf, nil, tab) then
      return false, "buffer is excluded or invalid"
    end
    local src = owner(s, buf)
    local newly_added = pending[buf]
    pending[buf] = nil
    if not newly_added and src and src ~= g and cfg.behavior.existing_buffer == "focus_owner" then
      g = src
    end
    return transfer(s, src, g, buf, opts.focus ~= false)
  end)
end
function M.cycle(delta)
  if type(delta) ~= "number" or delta % 1 ~= 0 then
    return false, "cycle delta must be an integer"
  end
  local tab = tabid()
  return run("cycle", tab, function()
    local s, g = target()
    if not g or #g.buffers == 0 then
      return false, "no eligible buffers"
    end
    local idx = 1
    for i, b in ipairs(g.buffers) do
      if b == api.nvim_win_get_buf(g.win) then
        idx = i
      end
    end
    local b = g.buffers[(idx - 1 + delta) % #g.buffers + 1]
    display(g, b, true)
    s.last = g.id
    return b
  end)
end
function M.move(direction, opts)
  if direction ~= "left" and direction ~= "right" then
    return false, "direction must be left or right"
  end
  opts = opts or {}
  local tab = tabid(opts)
  return run("move", tab, function()
    local s, g, _, err = target(opts)
    if not g then
      return false, err or "no managed editor window"
    end
    reveal(s, g)
    local buf = opts.buf or api.nvim_win_get_buf(g.win)
    if not eligible(buf, g.win, tab) then
      return false, "buffer is excluded or invalid"
    end
    if not s.active then
      local wins = editor_windows(tab)
      if #wins > 2 then
        return false, "initialization requires at most two editor windows"
      end
      if #g.buffers < 2 then
        if cfg.behavior.single_buffer_split == "require_two" then
          return false, "initialization requires two eligible buffers"
        end
        add(g, api.nvim_create_buf(true, false))
      end
      local oldwin = g.win
      local other
      if #wins == 2 then
        other = wins[1] == oldwin and wins[2] or wins[1]
        if api.nvim_win_get_position(other)[2] == api.nvim_win_get_position(oldwin)[2] then
          -- Adopt stacked editors as the side by side layout without moving sidebars.
          api.nvim_win_set_config(other, { win = oldwin, split = direction })
        end
      else
        api.nvim_win_call(oldwin, function()
          vim.cmd(direction == "left" and "leftabove vsplit" or "rightbelow vsplit")
          other = api.nvim_get_current_win()
        end)
      end
      local second = group(other)
      s.groups[#s.groups + 1] = second
      sides(s)
      if #wins == 2 then
        local shown = api.nvim_win_get_buf(other)
        if shown ~= buf and eligible(shown, other, tab) then
          remove(g, shown)
          add(second, shown)
          second.current = shown
        end
      end
      local dst = s.groups[1].side == direction and s.groups[1] or s.groups[2]
      -- A duplicated display must be replaced before applying exclusive ownership.
      if #second.buffers == 0 and dst == g then
        for _, b in ipairs(g.buffers) do
          if b ~= buf then
            remove(g, b)
            add(second, b)
            display(second, b, false)
            break
          end
        end
      elseif #second.buffers == 0 then
        add(second, buf)
        remove(g, buf)
        display(second, buf, false)
        display(g, g.buffers[1], false)
      end
      for _, owned_group in ipairs(s.groups) do
        for _, owned_buf in ipairs(owned_group.buffers) do
          pending[owned_buf] = nil
        end
      end
      local src = owner(s, buf)
      return transfer(s, src, dst, buf, cfg.behavior.follow_buffer)
    end
    local dst
    for _, v in ipairs(s.groups) do
      if v.side == direction then
        dst = v
      end
    end
    if not dst then
      return false, "requested group is unavailable"
    end
    return transfer(s, owner(s, buf), dst, buf, cfg.behavior.follow_buffer)
  end)
end
function M.close(buf, opts)
  opts = opts or {}
  buf = buf or opts.buf or api.nvim_get_current_buf()
  local tab = tabid(opts)
  return run("close", tab, function()
    local s = ensure(tab)
    local g = owner(s, buf)
    if not g or not eligible(buf, nil, tab) then
      return false, "buffer is not managed"
    end
    if vim.bo[buf].modified and not opts.force then
      return false, "buffer has unsaved changes"
    end
    if cfg.closing.last_buffer == "quit" then
      local remaining = false
      for _, b in ipairs(api.nvim_list_bufs()) do
        -- Closing the editor is global, independent of group exclusions.
        if b ~= buf and vim.bo[b].buflisted and vim.bo[b].buftype == "" then
          remaining = true
        end
      end
      if not remaining then
        vim.cmd(opts.force and "qall!" or "qall")
        return buf
      end
    end
    -- Display a local replacement before deletion so native deletion cannot choose another group.
    local replacement
    for _, b in ipairs(g.buffers) do
      if b ~= buf then
        replacement = b
        break
      end
    end
    if not g.hidden and api.nvim_win_get_buf(g.win) == buf then
      if replacement then
        display(g, replacement, false)
      elseif #s.groups == 1 then
        empty_buffer(g)
      else
        -- Keep a temporary unlisted buffer in the window while deleting the last member.
        api.nvim_win_set_buf(g.win, api.nvim_create_buf(false, true))
      end
    end
    api.nvim_buf_delete(buf, { force = opts.force == true })
    for _, ts in pairs(tabs) do
      for _, v in ipairs(ts.groups) do
        remove(v, buf)
      end
    end
    vacate(s, g, buf)
    return buf
  end)
end
function M.close_others(opts)
  opts = opts or {}
  local tab = tabid(opts)
  return run("close_others", tab, function()
    local s, g, _, err = target(opts)
    if not g then
      return false, err or "no managed editor window"
    end
    local keep = g.current
    if not g.hidden then
      keep = api.nvim_win_get_buf(g.win)
    end
    if not keep or not vim.tbl_contains(g.buffers, keep) or not eligible(keep, nil, tab) then
      return false, "current buffer is not managed by the selected group"
    end
    local buffers = {}
    for _, buf in ipairs(g.buffers) do
      if buf ~= keep then
        buffers[#buffers + 1] = buf
      end
    end
    local save = opts.save
    if save == nil then
      save = cfg.closing.save_others and not opts.force
    end
    -- Finish every save before deleting any member, so write failures leave
    -- the whole group open. The current buffer never participates in saves.
    for _, buf in ipairs(buffers) do
      if api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
        if save then
          api.nvim_buf_call(buf, function()
            vim.cmd.write()
          end)
        elseif not opts.force then
          return false, "buffer has unsaved changes"
        end
      end
    end
    for _, buf in ipairs(buffers) do
      if api.nvim_buf_is_valid(buf) and vim.bo[buf].modified and not opts.force then
        return false, "buffer has unsaved changes"
      end
    end
    if not api.nvim_buf_is_valid(keep) or owner(s, keep) ~= g then
      return false, "current buffer is no longer managed by the selected group"
    end
    for _, buf in ipairs(buffers) do
      if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_delete(buf, { force = opts.force == true })
      end
      pending[buf], homes[buf] = nil, nil
      for _, state in pairs(tabs) do
        for _, owned in ipairs(state.groups) do
          remove(owned, buf)
        end
      end
    end
    g.current = keep
    return buffers
  end)
end
function M.close_group(opts)
  opts = opts or {}
  local tab = tabid(opts)
  return run("close_group", tab, function()
    local s, g, _, err = target(opts)
    if not g then
      return false, err or "no managed editor window"
    end
    local buffers = vim.deepcopy(g.buffers)
    for _, buf in ipairs(buffers) do
      if api.nvim_buf_is_valid(buf) and vim.bo[buf].modified and not opts.force then
        return false, "buffer has unsaved changes"
      end
    end
    if cfg.closing.last_buffer == "quit" then
      local remaining = false
      for _, buf in ipairs(api.nvim_list_bufs()) do
        if not vim.tbl_contains(buffers, buf) and vim.bo[buf].buflisted and vim.bo[buf].buftype == "" then
          remaining = true
          break
        end
      end
      if not remaining then
        vim.cmd(opts.force and "qall!" or "qall")
        return buffers
      end
    end
    if s.fullscreen and not g.hidden then
      restore_hidden(s)
    end
    if not g.hidden then
      -- Native deletion must not install another owner's buffer in this window.
      api.nvim_win_set_buf(g.win, api.nvim_create_buf(false, true))
    end
    for _, buf in ipairs(buffers) do
      if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_delete(buf, { force = opts.force == true })
      end
      pending[buf], homes[buf] = nil, nil
      for _, state in pairs(tabs) do
        for _, owned in ipairs(state.groups) do
          remove(owned, buf)
        end
      end
    end
    if #s.groups == 1 then
      local replacement = group(g.win)
      s.groups, s.last, s.fullscreen = { replacement }, replacement.id, false
      empty_buffer(replacement)
      sides(s)
    else
      vacate(s, g)
    end
    return buffers
  end)
end
function M.toggle_fullscreen(opts)
  opts = opts or {}
  local tab = tabid(opts)
  local ok, result = run("toggle_fullscreen", tab, function()
    local s, g, _, err = target(opts)
    if not g then
      return false, err or "no managed editor window"
    end
    if s.fullscreen then
      restore_hidden(s)
      api.nvim_set_current_win(g.win)
      s.last = g.id
      return { fullscreen = false }
    end
    if #s.groups == 1 then
      return { fullscreen = false }
    end
    if #s.groups ~= 2 then
      return false, "fullscreen requires two initialized groups"
    end
    if #editor_windows(tab) ~= 2 then
      return false, "fullscreen requires exactly two editor windows"
    end
    for _, owned in ipairs(s.groups) do
      if
        owned.hidden
        or not owned.win
        or not api.nvim_win_is_valid(owned.win)
        or not eligible(api.nvim_win_get_buf(owned.win), owned.win, tab)
      then
        return false, "fullscreen requires two managed editor windows"
      end
    end
    s.unmanaged_widths = {}
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if not bywin(s, win) and api.nvim_win_get_config(win).relative == "" then
        s.unmanaged_widths[win] = api.nvim_win_get_width(win)
      end
    end
    for _, owned in ipairs(s.groups) do
      save_window(owned)
    end
    for _, owned in ipairs(s.groups) do
      if owned ~= g then
        local buf = api.nvim_win_get_buf(owned.win)
        local bufhidden = vim.bo[buf].bufhidden
        vim.bo[buf].bufhidden = "hide"
        local ok, failure = pcall(api.nvim_win_hide, owned.win)
        if api.nvim_buf_is_valid(buf) then
          vim.bo[buf].bufhidden = bufhidden
        end
        if not ok then
          error(failure)
        end
        owned.win, owned.hidden = nil, true
      end
    end
    restore_unmanaged_widths(s)
    s.fullscreen, s.last = true, g.id
    api.nvim_set_current_win(g.win)
    return { fullscreen = true }
  end)
  if not ok then
    return false, result
  end
  return true, result.fullscreen
end
local function entered()
  if not enabled or busy then
    return
  end
  local tab = api.nvim_get_current_tabpage()
  local win = api.nvim_get_current_win()
  local buf = api.nvim_get_current_buf()
  -- Tab creation briefly enters the old buffer before installing its new buffer.
  if not tabs[tab] and homes[buf] and homes[buf] ~= tab then
    return
  end
  local s = ensure(tab, win)
  local g = bywin(s, win)
  if not g or not eligible(buf, win, tab) then
    return
  end
  busy = true
  local ok, err = pcall(function()
    local src = owner(s, buf)
    if pending[buf] then
      pending[buf] = nil
      if src and src ~= g then
        remove(src, buf)
        vacate(s, src, buf)
      end
      add(g, buf)
      g.current = buf
    elseif src and src ~= g then
      if cfg.behavior.existing_buffer == "transfer" then
        transfer(s, src, g, buf, cfg.behavior.follow_buffer)
      else
        local restore = g.current
        if not restore or not api.nvim_buf_is_valid(restore) or not vim.tbl_contains(g.buffers, restore) then
          restore = g.buffers[1]
        end
        if restore then
          display(g, restore, false)
        end
        display(src, buf, true)
        g = src
        -- nvim_win_set_buf restores its caller's window after BufEnter callbacks.
        -- Repeat the focus after that native context has unwound.
        local owner_win = src.win
        vim.schedule(function()
          if enabled and api.nvim_win_is_valid(owner_win) and api.nvim_win_get_buf(owner_win) == buf then
            api.nvim_set_current_win(owner_win)
          end
        end)
      end
    else
      add(g, buf)
      g.current = buf
    end
    s.last = g.id
  end)
  busy = false
  if not ok then
    vim.notify("buffer_groups: " .. tostring(err), vim.log.levels.ERROR)
  end
  reconcile(tab)
  event(tab, "enter")
end
local function deferred(reason)
  if busy or not enabled then
    return
  end
  vim.schedule(function()
    if busy or not enabled then
      return
    end
    busy = true
    local ok, err = pcall(function()
      for tab in pairs(tabs) do
        if api.nvim_tabpage_is_valid(tab) then
          reconcile(tab)
        else
          tabs[tab] = nil
        end
      end
    end)
    busy = false
    if not ok then
      vim.notify("buffer_groups: " .. tostring(err), vim.log.levels.ERROR)
    end
    if api.nvim_tabpage_is_valid(api.nvim_get_current_tabpage()) then
      event(api.nvim_get_current_tabpage(), reason)
    end
  end)
end
local function global_map(lhs)
  local raw = api.nvim_replace_termcodes(lhs, true, true, true)
  for _, mapping in ipairs(api.nvim_get_keymap("n")) do
    if api.nvim_replace_termcodes(mapping.lhs, true, true, true) == raw then
      return mapping
    end
  end
  return {}
end
local function restore_maps()
  for _, entry in ipairs(maps) do
    local current = global_map(entry.lhs)
    if current.callback == entry.callback then
      pcall(vim.keymap.del, "n", entry.lhs)
      if entry.previous and next(entry.previous) then
        vim.fn.mapset("n", false, entry.previous)
      end
    end
  end
  maps = {}
end
local function report(fn)
  local ok, err = fn()
  if not ok then
    vim.notify("buffer_groups: " .. tostring(err), vim.log.levels.WARN)
  end
end
local function install_maps()
  local actions = {
    move_left = function()
      return M.move("left")
    end,
    move_right = function()
      return M.move("right")
    end,
    previous = function()
      return M.cycle(-1)
    end,
    next = function()
      return M.cycle(1)
    end,
    close = function()
      return M.close()
    end,
    close_group = function()
      return M.close_group()
    end,
    close_others = function()
      return M.close_others()
    end,
    toggle_fullscreen = function()
      return M.toggle_fullscreen()
    end,
  }
  for name, lhs in pairs(cfg.keymaps) do
    local previous = global_map(lhs)
    local callback = function()
      report(actions[name])
    end
    vim.keymap.set("n", lhs, callback, { silent = true, desc = "BufferGroups " .. name })
    maps[#maps + 1] = { lhs = lhs, callback = callback, previous = previous }
  end
end
function M.enable()
  if enabled then
    return true, M
  end
  enabled = true
  tabs = {}
  pending = {}
  homes = {}
  local augroup = api.nvim_create_augroup("BufferGroups", { clear = true })
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, { group = augroup, callback = entered })
  api.nvim_create_autocmd("BufAdd", {
    group = augroup,
    callback = function(e)
      if not busy then
        local existing = false
        for _, state in pairs(tabs) do
          if owner(state, e.buf) then
            existing = true
            break
          end
        end
        -- Rename emits BufDelete/BufAdd for the same live buffer.
        if not existing then
          homes[e.buf] = api.nvim_get_current_tabpage()
          pending[e.buf] = true
        end
      end
      deferred(e.event)
    end,
  })
  api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "WinClosed", "TabClosed" }, {
    group = augroup,
    callback = function(e)
      deferred(e.event)
    end,
  })
  install_maps()
  event(api.nvim_get_current_tabpage(), "enable")
  return true, M
end
function M.disable()
  if not enabled then
    return true, M
  end
  local was_busy = busy
  busy = true
  local ok, err = pcall(function()
    for tab, state in pairs(tabs) do
      if api.nvim_tabpage_is_valid(tab) and state.fullscreen then
        restore_hidden(state)
      end
    end
  end)
  busy = was_busy
  if not ok then
    return false, tostring(err)
  end
  enabled = false
  api.nvim_create_augroup("BufferGroups", { clear = true })
  restore_maps()
  tabs = {}
  event(api.nvim_get_current_tabpage(), "disable")
  return true, M
end
function M.setup(opts)
  if vim.fn.has("nvim-0.11") ~= 1 then
    error("buffer_groups requires Neovim >= 0.11", 2)
  end
  local resolved = config.resolve(opts)
  local disabled, err = M.disable()
  if not disabled then
    error("buffer_groups: " .. tostring(err), 2)
  end
  cfg = resolved
  api.nvim_create_user_command("BufferGroupsMove", function(o)
    report(function()
      return M.move(o.args)
    end)
  end, {
    nargs = 1,
    force = true,
    complete = function()
      return { "left", "right" }
    end,
  })
  api.nvim_create_user_command("BufferGroupsNext", function()
    report(function()
      return M.cycle(1)
    end)
  end, { force = true })
  api.nvim_create_user_command("BufferGroupsPrevious", function()
    report(function()
      return M.cycle(-1)
    end)
  end, { force = true })
  api.nvim_create_user_command("BufferGroupsClose", function(o)
    report(function()
      return M.close(nil, { force = o.bang })
    end)
  end, { force = true, bang = true })
  api.nvim_create_user_command("BufferGroupsCloseGroup", function(o)
    report(function()
      return M.close_group({ force = o.bang })
    end)
  end, { force = true, bang = true })
  api.nvim_create_user_command("BufferGroupsCloseOthers", function(o)
    report(function()
      return M.close_others({ force = o.bang })
    end)
  end, { force = true, bang = true })
  api.nvim_create_user_command("BufferGroupsToggleFullscreen", function()
    report(function()
      return M.toggle_fullscreen()
    end)
  end, { force = true })
  api.nvim_create_user_command("BufferGroupsEnable", function()
    M.enable()
  end, { force = true })
  api.nvim_create_user_command("BufferGroupsDisable", function()
    report(function()
      return M.disable()
    end)
  end, { force = true })
  M.enable()
  return M
end
return M
