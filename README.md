# buffer_groups

Two editor groups with separate, ordered buffer lists for Neovim. Moving a
buffer transfers its ownership; cycling stays inside the focused group. Empty
groups close their split automatically.

Requires Neovim 0.11 or newer. No runtime dependencies. Bufferline and Snacks are
optional. This repository is currently being developed locally; the GitHub
installation example is for use after publication.

## Local installation

```lua
vim.opt.runtimepath:prepend(vim.fn.expand("~/Dev/Personal/buffer_groups"))
require("buffer_groups").setup({
  keymaps = {
    move_left = "<leader>h",
    move_right = "<leader>l",
    previous = "<A-h>",
    next = "<A-l>",
  },
})
```

Keep these lines in a single registration module. Removing that module and
restarting Neovim disables the plugin. `setup({})` installs commands and observes
buffers, but does not install any keymaps or immediately split the editor.
For a manual runtimepath installation, generate the help index once with
`:helptags ~/Dev/Personal/buffer_groups/doc`.

Once published, Neovim configurations using `vim.pack` can register the repository
URL instead of extending the local runtimepath:

```lua
vim.pack.add({
  { src = "https://github.com/Perazzojoao/buffer_groups", version = "v0.1.0" },
})
require("buffer_groups").setup({ --[[ your options ]] })
```

The plugin itself does not require `vim.pack`. Other package managers can load
the same repository and call `setup()`.

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

## Configuration

```lua
require("buffer_groups").setup({
  keymaps = {}, -- Optional keys: move_left, move_right, previous, next, close.
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
  closing = {
    last_buffer = "empty", -- Alternative: "quit".
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

local owner = groups.get_owner(bufnr, { tabpage = tabpage })
local state = groups.get_state({ tabpage = tabpage })
groups.disable()
groups.enable()
local enabled = groups.is_enabled()
```

Mutations return `true, result` or `false, error`. Commands notify errors.
`get_state()` and `get_owner()` return copies; changing them never changes the
plugin. State contains `enabled`, `tabpage`, `active`, `focused`, `groups` and
`owners`. Each group has `id`, `win`, `side`, `buffers` and `current`. `side` is
`left`, `right` or `single`; IDs stay stable while groups exist. Options may use
`group` to select a group ID explicitly.

`disable()` preserves all windows and buffers, removes observer isolation and
restores prior keymaps if they have not been replaced by the user. Commands stay
available for reactivation. `setup()` is idempotent.

Commands: `:BufferGroupsMove left|right`, `:BufferGroupsNext`,
`:BufferGroupsPrevious`, `:BufferGroupsClose[!]`, `:BufferGroupsEnable`,
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

## Optional bufferline integration

Load/configure buffer_groups before calling Bufferline's setup once:

```lua
local config = { options = { diagnostics = "nvim_lsp" } }
if package.loaded["buffer_groups"] then
  config = require("buffer_groups.integrations.bufferline").extend(config)
end
require("bufferline").setup(config)
```

The adapter copies the configuration, shows Left/Right owner groups in one global
bar, follows the group's cycle order, and directs clicks to the owning split.
Existing filters, visual options and close callbacks are preserved/composed.
It never calls Bufferline setup itself. Disabling the core restores original
callback behavior; unregistering the local plugin keeps the config above usable.

The optional second argument to `extend(config, adapter_opts)` accepts
`managed_order = false` to keep Bufferline's sorter. By default managed groups
follow their buffer order; the host sorter still orders unmanaged buffers.
The history-based sort modes `insert_after_current` and `insert_at_end` require
`managed_order = false` because their render history is private to Bufferline.

Separate bars aligned above each split are not supported. Bufferline's native
cycle, pin and manual move commands operate globally; use this plugin's cycling
API and avoid pinning/manually sorting managed buffers. Existing host groups
remain usable for buffers outside the managed owner groups.

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
