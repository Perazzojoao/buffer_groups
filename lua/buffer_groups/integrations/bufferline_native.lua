-- Compatibility boundary for Bufferline 4.9.1. Bufferline owns every tab's
-- visual components; this module only encodes and fits those components.
local M = {}
local api = vim.api
local modules

function M.attach()
  local ok, result = pcall(function()
    local m = {
      ui = require("bufferline.ui"),
      models = require("bufferline.models"),
      config = require("bufferline.config"),
      diagnostics = require("bufferline.diagnostics"),
      duplicates = require("bufferline.duplicates"),
      groups = require("bufferline.groups"),
    }
    assert(type(m.ui.element) == "function", "missing native element renderer")
    assert(type(m.models.Buffer.new) == "function", "missing native buffer model")
    assert(type(m.diagnostics.get) == "function", "missing diagnostics provider")
    assert(
      type(m.duplicates.mark) == "function" and type(m.duplicates.reset) == "function",
      "missing duplicate metadata"
    )
    assert(type(m.groups.set_id) == "function", "missing group metadata")
    assert(type(m.config.options) == "table" and type(m.config.highlights) == "table", "Bufferline setup is incomplete")
    assert(m.config.options.mode ~= "tabs", "winbar requires Bufferline mode='buffers'")
    assert(m.config.highlights.fill and m.config.highlights.fill.hl_group, "missing native fill highlight")
    return m
  end)
  if not ok then
    return false, "unsupported Bufferline renderer: " .. tostring(result)
  end
  modules = result
  return true
end

function M.options()
  return modules and modules.config.options
end

local function highlight(name)
  return name and "%#" .. name .. "#" or ""
end

-- Encode native Segment attributes, including extended highlights and nested
-- mouse actions. No filename, icon, diagnostic or separator is generated here.
local function encode(segments, click)
  local locations, extensions, globals, out = {}, {}, {}, {}
  for i, segment in ipairs(segments) do
    local attr = segment.attr or {}
    if attr.__id then
      locations[attr.__id] = i
    end
    for _, extension in ipairs(attr.extends or {}) do
      extensions[extension.id] = extension.highlight or segment.highlight
    end
  end
  local function actions(value)
    return (value or ""):gsub("%%(%d+)@v:lua%.___bufferline_private%.([%w_]+)@", function(buf, action)
      if action == "handle_click" or action == "handle_close" then
        return click(tonumber(buf), action == "handle_close" and "close" or "click")
      end
      error("unsupported native mouse action " .. action)
    end)
  end
  for _, segment in ipairs(segments) do
    local attr = segment.attr or {}
    if attr.global then
      globals[#globals + 1] = { actions(attr.prefix), attr.suffix or "%T" }
    end
    local hl = segment.highlight
    if attr.__id and locations[attr.__id] then
      hl = extensions[attr.__id] or hl
    end
    out[#out + 1] = highlight(hl)
      .. (not attr.global and actions(attr.prefix) or "")
      .. (segment.text or "")
      .. (not attr.global and (attr.suffix or "") or "")
  end
  local text = table.concat(out)
  for i = #globals, 1, -1 do
    text = globals[i][1] .. text .. globals[i][2]
  end
  return text
end

function M.prepare(snapshot, filter)
  local options = modules.config.options
  local diagnostics = modules.diagnostics.get(options)
  local all, by_group = {}, {}
  local valid = vim.tbl_filter(function(buf)
    return api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted
  end, api.nvim_list_bufs())
  for _, group in ipairs(snapshot.groups) do
    local list = {}
    by_group[group.id] = list
    for _, buf in ipairs(group.buffers) do
      if api.nvim_buf_is_valid(buf) and (type(filter) ~= "function" or filter(buf, valid)) then
        local model = modules.models.Buffer:new({
          id = buf,
          ordinal = #all + 1,
          path = api.nvim_buf_get_name(buf),
          diagnostics = diagnostics[buf],
          name_formatter = options.name_formatter,
        })
        -- Override instance context, leaving Bufferline's shared prototype intact.
        model.current = function(self)
          return self.id == group.current
        end
        model.visible = function(self)
          for _, win in ipairs(vim.fn.win_findbuf(self.id)) do
            if api.nvim_win_get_tabpage(win) == snapshot.tabpage then
              return true
            end
          end
          return false
        end
        model.group = modules.groups.set_id(model)
        list[#list + 1], all[#all + 1] = model, model
      end
    end
  end
  -- This is a scheduled preparation pass, never a statusline evaluation.
  -- Bufferline resets this metadata itself on each global rendering pass.
  modules.duplicates.reset()
  modules.duplicates.mark(all)
  for _, list in pairs(by_group) do
    for i, model in ipairs(list) do
      list[i] = modules.ui.element({ is_picking = false }, model)
    end
  end
  return by_group
end

local function marker(count, icon)
  if count == 0 then
    return ""
  end
  return highlight(modules.config.highlights.trunc_marker.hl_group) .. " " .. count .. " " .. icon .. " "
end

local function width(text, win)
  return api.nvim_eval_statusline(text, { winid = win, use_winbar = true, maxwidth = 100000 }).width
end

function M.render(items, available, win, click)
  if #items == 0 or available <= 0 then
    return ""
  end
  local selected = 1
  for i, item in ipairs(items) do
    if item:current() then
      selected = i
      break
    end
  end
  local left, right, size = 1, #items, 0
  for _, item in ipairs(items) do
    size = size + item.length
  end
  if items[selected].length > available then
    return ""
  end
  local options = modules.config.options
  local lmark, rmark = "", ""
  while true do
    lmark = marker(left - 1, options.left_trunc_marker)
    rmark = marker(#items - right, options.right_trunc_marker)
    local overhead = width(lmark .. rmark, win)
    if size + overhead <= available then
      break
    end
    if left == selected and right == selected then
      lmark, rmark = "", ""
      break
    end
    local before, after = 0, 0
    for i = left, selected - 1 do
      before = before + items[i].length
    end
    for i = selected + 1, right do
      after = after + items[i].length
    end
    if left < selected and (before >= after or right == selected) then
      size, left = size - items[left].length, left + 1
    else
      size, right = size - items[right].length, right - 1
    end
  end
  local out = { lmark }
  for i = left, right do
    out[#out + 1] = encode(items[i].component(i < right and items[i + 1] or nil), click)
  end
  out[#out + 1] = rmark
  return table.concat(out)
end

return M
