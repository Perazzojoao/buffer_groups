# buffer_groups

Two editor groups with separate, ordered buffer lists for Neovim. Moving a
buffer transfers its ownership; cycling stays inside the focused group. Empty
groups close their split automatically.

Requires Neovim 0.11 or newer. No runtime dependencies. Bufferline and Snacks are
optional. Core management supports two independent groups per tabpage. The
optional native group winbar requires the Bufferline 4.9.1 adapter.

## Installation

With Neovim's built-in package manager, add the published release and configure
it in your plugin setup:

```lua
vim.pack.add({
  { src = "https://github.com/Perazzojoao/buffer_groups", version = "v0.2.0" },
})
require("buffer_groups").setup({
  keymaps = {
    move_left = "<leader>h",
    move_right = "<leader>l",
    previous = "<A-h>",
    next = "<A-l>",
    close_group = "<leader>kg",
    close_others = "<leader>ko",
    toggle_fullscreen = "<leader>mm",
  },
})
```

The plugin does not require `vim.pack`; other package managers can install the
same repository and call `setup()`. `setup({})` installs commands and observes
buffers, but does not install keymaps or immediately split the editor.

### Development installation

For local development, prepend the checkout to `runtimepath` instead of adding a
package-manager entry:

```lua
vim.opt.runtimepath:prepend(vim.fn.expand("~/Dev/Personal/buffer_groups"))
require("buffer_groups").setup({
  keymaps = {
    move_left = "<leader>h",
    move_right = "<leader>l",
    previous = "<A-h>",
    next = "<A-l>",
    close_group = "<leader>kg",
    close_others = "<leader>ko",
    toggle_fullscreen = "<leader>mm",
  },
})
```

Keep local registration in a single module. Removing that module and restarting
Neovim disables the plugin. For a manual runtimepath installation, generate the
help index once with `:helptags ~/Dev/Personal/buffer_groups/doc`.

## Working with groups

Start with two listed editing buffers. `move("right")` splits the editor, puts
the current buffer on the right and keeps the other buffers on the left.
`move("left")` does the reverse. Existing pairs of editor windows are adopted;
more than two eligible windows prevents initialization.
Two stacked editor windows are rearranged side by side when adopted; their IDs
and excluded sidebars are preserved.

Within a split, moving transfers one buffer to the requested side. The target's
previously displayed buffer remains in its list. The source displays another
buffer from its own list, or closes when the list becomes empty. Focus follows
the moved buffer. Moving to its current side does nothing.

```
Normal:             [A, B, C]       focus A
Move right:         [B, C] | [A]
Open D on right:    [B, C] | [A, D]
Move D left:        [B, C, D] | [A]
Move A left:        [B, C, D, A]     normal again
```

New buffers join the editor group that opens them. Selecting a buffer belonging
to another group focuses its owner by default. Moving is the explicit way to
change its group. Group membership is exclusive within a tabpage; different
tabpages maintain independent state. Listed but unloaded buffers remain available.

Closing a managed window manually merges its buffers into the remaining group.
Extra windows opened while partitioned remain unmanaged. No groups are restored
across Neovim restarts.

### Close a group

`close_group()` closes every buffer in the focused group, then closes that
group's split. It checks all members for unsaved changes before deleting any;
`close_group({ force = true })` explicitly discards those changes. The other
group keeps its buffers. Closing the visible group while fullscreen reveals
the other group first.

The last group follows `closing.last_buffer`: `"quit"` exits when no other listed
editing buffers remain globally; the default `"empty"` leaves an editable empty
replacement when Neovim needs a final editor window.

### Fullscreen toggle

`toggle_fullscreen()` expands the focused group into the editing area by hiding
the other group's split. With only one group, it returns `true, false` without
changing the layout. Two initialized groups must be the only eligible editing
windows; additional editing splits cause an error. Excluded sidebars
and auxiliary windows stay in place. All buffers, their order and their group
membership remain intact. Calling it again restores the hidden split and its
displayed buffer.

Moving a buffer to the hidden group or selecting a hidden group's buffer with
the default owner policy reveals that group. Local cycling and newly opened
buffers continue to use the visible group. Disabling the plugin restores hidden
groups before releasing their state.

### Close other buffers in a group

`close_others()` keeps the focused group's current buffer and closes its other
members. The group's split, fullscreen state and the other group's buffers stay
intact. With only one member, it succeeds with an empty list.

By default it refuses unsaved changes. Set `closing.save_others = true` to save
modified target buffers first, or override it for one call with
`close_others({ save = true })`. Every save must succeed before deletion starts;
a write failure keeps all buffers open, although earlier successful writes stay
saved. The current buffer is never saved or closed by this method.
`close_others({ force = true })` skips automatic saving and discards modifications;
an explicit `save = true` still requests saving even when forced.

## Configuration

```lua
require("buffer_groups").setup({
  keymaps = {}, -- Optional keys: move_left, move_right, previous, next, close,
                -- close_group, close_others, toggle_fullscreen, toggle_winbar, toggle_tabs,
                -- toggle_tabline_groups.
  exclude = {
    floating = true, -- Floating windows cannot be group owners.
    unlisted = true,
    filetypes = { "snacks_layout_box", "snacks_picker_list" },
    buftypes = { "nofile", "help", "terminal", "quickfix", "prompt" },
    bufname = {}, -- Lua patterns against the full buffer name.
    window = function(ctx)
      return vim.w[ctx.win].buffer_groups_ignore == true
    end,
    buffer = function(ctx)
      return vim.b[ctx.buf].buffer_groups_ignore == true
    end,
  },
  behavior = {
    follow_buffer = true,
    empty_group = "close",
    existing_buffer = "focus_owner", -- Alternative: "transfer".
    single_buffer_split = "require_two", -- Alternative: "new_buffer".
    manual_window_close = "merge",
  },
  tabline = { show_groups = true }, -- Hide group controls with false.
  closing = {
    last_buffer = "empty", -- Alternative: "quit".
    save_others = false, -- Save modified buffers before close_others().
  },
})
```

List options replace their defaults. Exclusion predicates receive
`{ buf, win, tabpage }`; `win` may be absent for a hidden buffer. Returning `true`
excludes it. Any matching exclusion wins. Use filetype/buftype exclusions for
explorers and plugin views, and predicates for your own rules. `floating=false`
is unsupported because the managed layout requires normal splits.

Moves and cycles invoked from excluded windows do not operate on their buffers.
`open()` and `register()` accept an explicit editor destination for prompts and
asynchronous integrations. Without one, they can use the remembered editor group.

`close()` refuses unsaved changes unless explicitly forced. The default last
buffer policy opens an editable empty buffer; `"quit"` exits only when no other
listed editing buffers remain, including buffers in other tabs. Your save and
close keymaps can save first, then call `close()`.

## Public API

```lua
local groups = require("buffer_groups")
groups.move("right", { buf = bufnr, win = editor_win })
groups.cycle(1) -- Use -1 to cycle backwards.
groups.open(bufnr, { win = editor_win })
groups.register(bufnr, { win = editor_win })
groups.close(bufnr, { force = false })
groups.close_group({ force = false })
groups.close_others({ save = true, force = false })
groups.toggle_fullscreen()

local owner = groups.get_owner(bufnr, { tabpage = tabpage })
local state = groups.get_state({ tabpage = tabpage })
groups.set_winbar_enabled(false)
local winbar_enabled = groups.is_winbar_enabled()
groups.set_group_tabs_visible(false, { group_id = group_id, tabpage = tabpage })
groups.toggle_group_tabs() -- Defaults to the focused group and tabpage.
groups.set_tabline_groups_visible(false)
groups.toggle_tabline_groups()
local tabline_options = groups.get_tabline_options()
groups.disable()
groups.enable()
local enabled = groups.is_enabled()
```

Mutations return `true, result` or `false, error`. Commands notify errors.
`get_state()` and `get_owner()` return copies; changing them never changes the
plugin. State contains `enabled`, `tabpage`, `active`, `focused`, `groups`,
`owners`, `fullscreen` and `winbar_enabled`. Each group has `id`, `win`, `side`,
`buffers`, `current`, `hidden` and `tabs_visible`. `side` is
`left`, `right` or `single`; IDs stay stable while groups exist. Options may use
`group` to select a group ID explicitly.

`close_group({ win?, tabpage?, group?, force? })` returns the closed buffer IDs.
`close_others({ win?, tabpage?, group?, save?, force? })` returns the closed buffer IDs,
excluding the selected group's current buffer.
`toggle_fullscreen({ win?, tabpage? })` returns the new fullscreen boolean.
These methods operate on an eligible editor group; commands invoked from excluded views
are refused. Hidden groups have `win = nil`. Restoring a split creates a new
window ID; integrations should refresh it through `get_owner()` or `get_state()`.

`disable()` preserves all windows and buffers, removes observer isolation and
reveals any hidden groups, and restores prior keymaps if they have not been
replaced by the user. Commands stay
available for reactivation. `setup()` is idempotent.

Commands: `:BufferGroupsMove left|right`, `:BufferGroupsNext`,
`:BufferGroupsPrevious`, `:BufferGroupsClose[!]`, `:BufferGroupsCloseGroup[!]`,
`:BufferGroupsCloseOthers[!]`,
`:BufferGroupsToggleFullscreen`, `:BufferGroupsEnable`,
`:BufferGroupsDisable`.

Subscribe to committed state changes without accessing plugin internals:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "BufferGroupsChanged",
  callback = function(event)
    -- event.data contains reason and tabpage.
  end,
})
```

## Optional Bufferline integration and native winbar

Load/configure buffer_groups before calling Bufferline's setup once. The adapter
preserves the host configuration, then attaches after setup:

```lua
local config = { options = { diagnostics = "nvim_lsp" } }
local adapter
if package.loaded["buffer_groups"] then
  adapter = require("buffer_groups.integrations.bufferline")
  config = adapter.extend(config, { display = "groups" })
end
require("bufferline").setup(config)
if adapter and type(adapter.attach) == "function" then
  adapter.attach()
end
```

The default adapter display is `buffers`, which keeps the legacy grouped-buffer
presentation. With more than one group, `display = "groups"` shows group
controls; clicking a control only toggles that group's tabs. With one group,
BufferGroups restores the original winbar and displays all buffer tabs on the
global tabline, regardless of that group's `tabs_visible` preference. Creating
another group restores the winbars and their visibility preferences. Fullscreen
still retains two groups, including the hidden group. Tabs from external Bufferline groups retain their
normal visibility. The adapter follows core ownership and cycle order, directs
clicks to the owning split, and preserves host filters, options and close
callbacks. Its fullscreen filter hides buffers owned by the hidden group; the
native winbar reveal setting is independent of fullscreen.

To hide the group controls in the global tabline, configure:

```lua
require("buffer_groups").setup({
  winbar = { enabled = true },
  tabline = { show_groups = false },
})
```

`tabline.show_groups` is a boolean and defaults to `true`. With an attached
adapter using `display = "groups"` and multiple groups, `false` removes only the
plugin's group controls. The entire tabline is hidden if Bufferline's evaluated
output contains no visible content apart from sidebar offsets. External
buffers, custom areas and native tabpage indicators keep the line visible.
Sidebar offsets (including their labels and separators) only reserve layout
space; they do not reveal an otherwise empty line when an explorer opens.
Offsets remain unchanged whenever other content makes the tabline visible.
Whitespace and highlight/fill formatting alone do not count as content. With one group, or
when the winbar or plugin is disabled, normal Bufferline behavior returns.
While the controller owns visibility, it checks rendered content every 200 ms,
including while the line is hidden, so asynchronous custom areas can reveal it
without an editor event. The timer stops when ownership ends or rendering
fails. Bufferline options are read from the current configuration after
colorscheme changes, preserving each options table's native auto-toggle setting.
Previous visibility and native auto-toggle settings are restored when the
plugin releases ownership. `get_tabline_options()` returns a copy of these
settings. This option requires no Bufferline dependency in the core.

Use `:BufferGroupsToggleTablineGroups` to toggle the group controls for the
current Neovim session. To assign your own shortcut:

```lua
require("buffer_groups").setup({
  winbar = { enabled = true },
  tabline = { show_groups = false }, -- Initial visibility.
  keymaps = { toggle_tabline_groups = "<leader>mt" },
})
```

The toggle applies globally across tabpages. It changes only session state;
it does not modify your configured default or write state to disk. Disabling
and enabling the plugin retains the session choice. Calling `setup()` again,
or reopening Neovim, restores `tabline.show_groups`. The API also exposes
`toggle_tabline_groups()` and `set_tabline_groups_visible(boolean)`; both return
`true, visible`, or `false, error` for invalid setter input.
`get_tabline_options().show_groups` reports effective session visibility.
Normal buffer tabs in single-group mode are unaffected.

Bufferline is optional to the core. The native group winbar UI requires a
compatible Bufferline adapter to be attached. The internal renderer contract is
validated against Bufferline 4.9.1; pin that version when using the native winbar.
If attachment is unavailable or
incompatible, the UI disables itself and warns while the core group management
continues. The adapter never calls Bufferline setup itself. Pin, native cycle,
pick and hover commands remain global and are not adapted in this version.

Configure the native winbar in `setup()`:

```lua
require("buffer_groups").setup({
  winbar = {
    enabled = true,
    position = "prepend", -- prepend, append, replace, or manual
    alignment = "left", -- left, center, or right
    reveal_on_use = false,
  },
})
```

With `reveal_on_use = false`, hiding the winbar persists. With `true`, using a
group reveals its tabs when focused, cycled, or used to open a buffer. Fullscreen remains a separate layout
operation. `:BufferGroupsWinbar enable|disable|toggle` controls the winbar;
`:BufferGroupsToggleTabs` toggles the focused group's tabs. The optional
`toggle_winbar` and `toggle_tabs` keymaps can be configured without adding local
key bindings by default.

For manual composition, `require("buffer_groups.ui.winbar").render(win)`
returns the native tab fragment for the given window. With `position = "manual"`,
the external provider places that fragment and owns the winbar option. Other
position modes compose with the existing content and apply `alignment`. The native UI element owns its
rendering and exposes no styling flags; Bufferline remains responsible for
Bufferline icons and appearance. Existing window width and window controls are
restored safely, and Treesitter context stays below the winbar.

The optional `managed_order = false` adapter setting retains Bufferline's native
sorter. The history-based modes `insert_after_current` and `insert_at_end` need
that setting because their render history is private to Bufferline.

The renderer iterates groups dynamically; the current core still manages at most
two groups. Extending the core layout is a separate change.

## Tests

```sh
python3 tests/run.py
python3 tests/run.py --nvim /path/to/nvim
python3 tests/run.py --integration --tui
```

Core and adapter tests run without external plugins. Optional integration tests
use installed Bufferline/Snacks or a dependency directory selected by
`BG_TEST_DEPS`. Tests isolate Neovim state/log files under temporary directories.
The PTY suite feeds actual keyboard/mouse input. See `:help buffer_groups` for
the option and API reference.

License: MIT.
