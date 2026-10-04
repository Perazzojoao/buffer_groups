#!/usr/bin/env python3
"""Exercise real key and optional Bufferline mouse input through a PTY."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import termios


ROOT = Path(__file__).resolve().parents[1]


def lua_quote(value: str) -> str:
    return json.dumps(value)


def has_bufferline(paths: str) -> bool:
    for raw in paths.split(os.pathsep):
        candidate = Path(raw)
        if candidate.name.lower() == "bufferline.nvim" or (candidate / "lua/bufferline.lua").is_file():
            return True
    return False


def drain(master: int, collected: bytearray, timeout: float = 0.05) -> bool:
    ready, _, _ = select.select([master], [], [], timeout)
    if not ready:
        return False
    try:
        chunk = os.read(master, 65536)
    except OSError:
        return False
    if not chunk:
        return False
    collected.extend(chunk)
    if len(collected) > 2_000_000:
        del collected[: len(collected) - 2_000_000]
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nvim", default=shutil.which("nvim"), required=False)
    args = parser.parse_args()
    if not args.nvim:
        parser.error("nvim was not found; pass --nvim PATH")
    nvim = str(Path(args.nvim).expanduser().resolve())
    if not Path(nvim).is_file():
        parser.error(f"Neovim executable does not exist: {nvim}")

    raw_temp_root = os.environ.get("BG_TEST_TMP")
    temp_root = Path(raw_temp_root) if raw_temp_root else Path(tempfile.mkdtemp(prefix="buffer-groups-tui-", dir="/tmp"))
    temp_root.mkdir(parents=True, exist_ok=True)
    state_dir = temp_root / "xdg-state"
    state_dir.mkdir(parents=True, exist_ok=True)
    ready = temp_root / "ready.txt"
    status = temp_root / "status.json"
    errors = temp_root / "startup-error.txt"
    setup_lua = temp_root / "tui-setup.lua"
    expected_bufferline = has_bufferline(os.environ.get("BG_TEST_PLUGIN_PATHS", ""))

    setup_lua.write_text(
        f'''local root = {lua_quote(str(ROOT))}
local temp = {lua_quote(str(temp_root))}
vim.opt.runtimepath:prepend(root)
for path in (vim.env.BG_TEST_PLUGIN_PATHS or ""):gmatch("[^:]+") do vim.opt.runtimepath:append(path) end
vim.opt.mouse = "a"
vim.opt.ttimeout = true
vim.opt.ttimeoutlen = 500
vim.opt.timeoutlen = 350
vim.opt.showtabline = 2
vim.g.mapleader = ","
local api = vim.api
local plugin = require("buffer_groups")
local function name(buf, label)
  api.nvim_buf_set_name(buf, temp .. "/" .. label)
  api.nvim_set_option_value("buflisted", true, {{ buf = buf }})
  api.nvim_set_option_value("buftype", "", {{ buf = buf }})
  api.nvim_buf_set_lines(buf, 0, -1, false, {{ label }})
  api.nvim_set_option_value("modified", false, {{ buf = buf }})
  return buf
end
local a = name(api.nvim_get_current_buf(), "a.txt")
local b = name(api.nvim_create_buf(true, false), "b.txt")
local c = name(api.nvim_create_buf(true, false), "c.txt")
plugin.setup({{ keymaps = {{ move_left = "<Leader>h", move_right = "<M-l>", previous = "<M-j>", next = "<M-k>" }} }})
local ok, err = plugin.move("right")
assert(ok, "initial split failed: " .. tostring(err))
local initial = plugin.get_state()
local left, right
for _, group in ipairs(initial.groups) do
  if group.side == "left" then left = group elseif group.side == "right" then right = group end
end
assert(left and right, "initial partition lacks both sides")
local moved, move_err = plugin.move("right", {{ buf = b }})
assert(moved, "failed to add a second right member: " .. tostring(move_err))
local start_right
for _, group in ipairs(plugin.get_state().groups) do if group.side == "right" then start_right = group end end
assert(start_right and vim.tbl_contains(start_right.buffers, a) and vim.tbl_contains(start_right.buffers, b), "right group fixture is incomplete")
local focused, focus_err = plugin.open(a, {{ win = start_right.win }})
assert(focused, "failed to show the initiating buffer before key input: " .. tostring(focus_err))

local bufferline_available = false
local mouse_expected = {"true" if expected_bufferline else "false"}
if mouse_expected then
  local adapter = require("buffer_groups.integrations.bufferline")
  local bufferline = require("bufferline")
  local config = adapter.extend({{ options = {{ mode = "buffers", always_show_bufferline = true, show_buffer_close_icons = false }} }})
  bufferline.setup(config)
  vim.cmd("redrawtabline")
  bufferline_available = true
end

local history = {{}}
api.nvim_create_autocmd("User", {{ pattern = "BufferGroupsChanged", callback = function()
  local owner = plugin.get_owner(a)
  local st = plugin.get_state()
  local current
  for _, group in ipairs(st.groups) do if group.side == "right" then current = group.current end end
  history[#history + 1] = {{ side = owner and owner.side or "none", current = current }}
end }})
history = {{}}
vim.fn.writefile({{ "ready" }}, vim.env.BG_TUI_READY)
vim.defer_fn(function()
  local st = plugin.get_state()
  local side
  for _, group in ipairs(st.groups) do if group.buffers and vim.tbl_contains(group.buffers, a) then side = group.side end end
  local right_events = {{}}
  local saw_left, saw_right = false, false
  for _, item in ipairs(history) do
    if item.side == "left" then saw_left = true end
    if saw_left and item.side == "right" then saw_right = true end
    if item.side == "right" and item.current ~= nil then right_events[#right_events + 1] = item.current end
  end
  local mouse_owner, mouse_buf, current_win
  if bufferline_available then
    mouse_owner = plugin.get_owner(c)
    current_win = api.nvim_get_current_win()
    mouse_buf = api.nvim_win_get_buf(mouse_owner and mouse_owner.win or current_win)
  end
  local result = {{
    active = st.active,
    side = side,
    saw_left = saw_left,
    saw_right_after_left = saw_right,
    right_events = right_events,
    events = history,
    mouse_expected = bufferline_available,
    current_win = current_win,
    mouse_owner_win = mouse_owner and mouse_owner.win,
    mouse_buffer = mouse_buf,
    left_buffer = c,
    right_members = start_right.buffers,
  }}
  vim.fn.writefile({{ vim.json.encode(result) }}, vim.env.BG_TUI_STATUS)
  vim.cmd("qa!")
end, 3600)
''',
        encoding="utf-8",
    )

    env = os.environ.copy()
    env.update(
        {
            "BG_TEST_ROOT": str(ROOT),
            "BG_TEST_TMP": str(temp_root),
            "BG_TUI_READY": str(ready),
            "BG_TUI_STATUS": str(status),
            "BG_TUI_STARTUP_ERROR": str(errors),
            "XDG_STATE_HOME": str(state_dir),
            "NVIM_LOG_FILE": str(temp_root / "nvim.log"),
            "NVIM_APPNAME": "buffer-groups-tui-test",
            "TERM": "xterm-256color",
            "LC_ALL": env.get("LC_ALL", "C.UTF-8"),
        }
    )
    lua_path = str(setup_lua).replace("\\", "\\\\").replace('"', '\\"')
    startup = (
        f'local ok, err = pcall(dofile, "{lua_path}"); '
        f'if not ok then vim.fn.writefile({{tostring(err)}}, vim.env.BG_TUI_STARTUP_ERROR); '
        'io.stderr:write(tostring(err) .. "\\n"); vim.cmd("cquit 2") end'
    )
    command = [nvim, "-u", "NONE", "-i", "NONE", "-n", "-c", "lua " + startup]

    pid, master = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(nvim, command, env)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 110, 0, 0))
    os.set_blocking(master, False)
    output = bytearray()
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline and not ready.is_file():
        drain(master, output, 0.05)
        done, _ = os.waitpid(pid, os.WNOHANG)
        if done:
            break
    if errors.is_file():
        print("FAIL TUI startup:\n" + errors.read_text(), file=sys.stderr)
        return 1
    if not ready.is_file():
        print("FAIL TUI: Neovim did not reach the input-ready marker", file=sys.stderr)
        if output:
            print(output[-3000:].decode(errors="replace"), file=sys.stderr)
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        return 1

    def send(data: bytes) -> None:
        os.write(master, data)
        # Let Neovim consume each mapped sequence before the next input.
        until = time.monotonic() + 0.18
        while time.monotonic() < until:
            drain(master, output, 0.03)

    # Real leader sequence, then terminal Alt-byte sequences (ESC+h/l/j/k).
    send(b",h")
    send(b"\x1bl")
    send(b"\x1bj")
    send(b"\x1bk")
    if expected_bufferline:
        # Bufferline's adapter orders owned groups first; the first buffer tab
        # belongs to the left group. Skip its rendered group title and send an
        # actual SGR mouse press and release over that buffer's label.
        send(b"\x1b[<0;32;1M")
        send(b"\x1b[<0;32;1m")

    deadline = time.monotonic() + 7
    child_status = None
    while time.monotonic() < deadline:
        drain(master, output, 0.05)
        done, wait_status = os.waitpid(pid, os.WNOHANG)
        if done:
            child_status = wait_status
            break
    if child_status is None:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        print("FAIL TUI: Neovim did not exit after the marker timer", file=sys.stderr)
        if output:
            print(output[-3000:].decode(errors="replace"), file=sys.stderr)
        return 1
    if errors.is_file():
        print("FAIL TUI startup:\n" + errors.read_text(), file=sys.stderr)
        return 1
    if not status.is_file():
        print("FAIL TUI: Lua did not write its state marker", file=sys.stderr)
        if output:
            print(output[-3000:].decode(errors="replace"), file=sys.stderr)
        return 1

    result = json.loads(status.read_text())
    failures = []
    if not result.get("active") or result.get("side") != "right":
        failures.append(f"leader/Alt movement did not return buffer a to the right owner: {result}")
    if not result.get("saw_left") or not result.get("saw_right_after_left"):
        failures.append(f"actual leader/Alt movement transitions were not observed: {result.get('right_events')}")
    cycles = result.get("right_events", [])
    cycle_end = len(cycles) - (1 if result.get("mouse_expected") else 0)
    if cycle_end < 3 or cycles[cycle_end - 1] != cycles[cycle_end - 3]:
        failures.append(f"Alt cycle keys did not make a local round trip: {cycles}")
    if result.get("mouse_expected"):
        if result.get("current_win") != result.get("mouse_owner_win"):
            failures.append(f"Bufferline mouse click did not focus the clicked buffer owner: {result}")
        if result.get("mouse_buffer") != result.get("left_buffer"):
            failures.append(f"Bufferline mouse click did not show the left-owned buffer: {result}")
    if failures:
        print("FAIL TUI:\n" + "\n".join(failures), file=sys.stderr)
        if output:
            print(output[-4000:].decode(errors="replace"), file=sys.stderr)
        return 1

    print("TUI: leader and Alt keys exercised through PTY")
    print("TUI: real Bufferline mouse click exercised through PTY" if expected_bufferline else "TUI: Bufferline mouse skipped (plugin unavailable)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
