#!/usr/bin/env python3
"""Check Bufferline order and Alt-h/l cycling in a real Neovim PTY."""

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
import sys
import tempfile
import time
import termios


ROOT = Path(__file__).resolve().parents[1]
LOCAL_BUFFERLINE = Path.home() / ".local/share/nvim/site/pack/core/opt/bufferline.nvim"


def lua_quote(value: str) -> str:
    return json.dumps(value)


def find_bufferline(paths: str) -> Path | None:
    candidates = [Path(item).expanduser() for item in paths.split(os.pathsep) if item]
    home = Path.home()
    for base in (
        home / ".local/share/nvim/lazy",
        home / ".local/share/nvim/site/pack",
        home / ".local/share/nvim/pack",
        home / ".config/nvim/pack",
    ):
        candidates.extend((base, *base.glob("*"), *base.glob("*/start/*"), *base.glob("*/opt/*"),
                           *base.glob("pack/*/start/*"), *base.glob("pack/*/opt/*")))
    candidates.append(LOCAL_BUFFERLINE)
    for candidate in candidates:
        if candidate.is_dir() and (candidate / "lua/bufferline.lua").is_file():
            return candidate.resolve()
    return None


def drain(master: int, output: bytearray, timeout: float = 0.04) -> None:
    ready, _, _ = select.select([master], [], [], timeout)
    if not ready:
        return
    try:
        chunk = os.read(master, 65536)
    except OSError:
        return
    if chunk:
        output.extend(chunk)
        if len(output) > 12000:
            del output[:-12000]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nvim", default=shutil.which("nvim"))
    args = parser.parse_args()
    if not args.nvim:
        parser.error("nvim was not found; pass --nvim PATH")
    nvim = str(Path(args.nvim).expanduser().resolve())
    if not Path(nvim).is_file():
        parser.error(f"Neovim executable does not exist: {nvim}")
    bufferline = find_bufferline(os.environ.get("BG_TEST_PLUGIN_PATHS", ""))
    if bufferline is None:
        print("SKIP cycle TUI: Bufferline is not installed in BG_TEST_PLUGIN_PATHS or the local Neovim pack path")
        return 0

    supplied_tmp = os.environ.get("BG_TEST_TMP")
    temp_root = Path(supplied_tmp) if supplied_tmp else Path(tempfile.mkdtemp(prefix="buffer-groups-cycle-tui-", dir="/tmp"))
    temp_root.mkdir(parents=True, exist_ok=True)
    state_dir = temp_root / "xdg-state"
    state_dir.mkdir(parents=True, exist_ok=True)
    setup_lua = temp_root / "cycle-setup.lua"
    request = temp_root / "snapshot.request"
    snapshot = temp_root / "snapshot.json"
    snapshot_tmp = temp_root / "snapshot.json.tmp"
    ready = temp_root / "ready"
    startup_error = temp_root / "startup-error.txt"

    setup_lua.write_text(
        f'''local root = {lua_quote(str(ROOT))}
local temp = {lua_quote(str(temp_root))}
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append({lua_quote(str(bufferline))})
vim.opt.mouse = "a"
vim.opt.ttimeout = true
vim.opt.ttimeoutlen = 500
vim.opt.timeoutlen = 350
vim.o.showtabline = 2
local api = vim.api
local plugin = require("buffer_groups")
local count = tonumber(vim.env.BG_CYCLE_COUNT)
local scenario = vim.env.BG_CYCLE_SCENARIO
local buffers = {{ api.nvim_get_current_buf() }}
local function name(buf, label)
  api.nvim_buf_set_name(buf, temp .. "/" .. label)
  api.nvim_set_option_value("buflisted", true, {{ buf = buf }})
  api.nvim_set_option_value("buftype", "", {{ buf = buf }})
  api.nvim_buf_set_lines(buf, 0, -1, false, {{ label }})
  api.nvim_set_option_value("modified", false, {{ buf = buf }})
end
name(buffers[1], "buf-1.txt")
for i = 2, count do
  buffers[i] = api.nvim_create_buf(true, false)
  name(buffers[i], "buf-" .. i .. ".txt")
end
api.nvim_set_current_buf(buffers[2])
plugin.setup({{ keymaps = {{ previous = "<M-h>", next = "<M-l>" }} }})
local moved, err = plugin.move("right")
assert(moved, "initial split failed: " .. tostring(err))
if scenario == "transfer" then
  moved, err = plugin.move("left")
  assert(moved, "transfer collapse failed: " .. tostring(err))
elseif scenario == "close" then
  local owner = plugin.get_owner(buffers[2])
  assert(owner, "the right-side buffer has no owner")
  api.nvim_win_close(owner.win, true)
  assert(vim.wait(1200, function() return #plugin.get_state().groups == 1 end, 10), "manual close did not merge groups")
else
  error("unknown scenario " .. tostring(scenario))
end

local state = plugin.get_state()
assert(#state.groups == 1, "fixture did not collapse to one managed group: " .. vim.inspect(state))
local group = state.groups[1]
assert(#group.buffers == count, "collapse changed managed buffer membership: " .. vim.inspect(group.buffers))
for _, buf in ipairs(buffers) do
  assert(plugin.get_owner(buf), "fixture buffer lost its owner: " .. tostring(buf))
end
local adapter = require("buffer_groups.integrations.bufferline")
local Bufferline = require("bufferline")
local config = adapter.extend({{ options = {{ mode = "buffers", always_show_bufferline = true, show_buffer_close_icons = false }} }})
Bufferline.setup(config)
vim.cmd("redrawtabline")

local function capture()
  api.nvim_eval_statusline(vim.o.tabline, {{ use_tabline = true, maxwidth = 240 }})
  vim.cmd("redrawtabline")
  local elements = Bufferline.get_elements().elements
  local visual = {{}}
  for _, element in ipairs(elements) do visual[#visual + 1] = element.id end
  local managed = {{}}
  for _, buf in ipairs(plugin.get_state().groups[1].buffers) do managed[#managed + 1] = buf end
  return {{ visual = visual, managed = managed, current = api.nvim_get_current_buf(), count = count, scenario = scenario }}
end

-- Start from the first element in Bufferline's publicly rendered order so both
-- directions, including wrapping at either end, are directly observable.
local initial = capture()
assert(#initial.visual == count, "Bufferline did not render every fixture buffer: " .. vim.inspect(initial))
assert(vim.deep_equal(initial.visual, initial.managed), "Bufferline display order differs from collapsed managed order: " .. vim.inspect(initial))
local opened, open_err = plugin.open(initial.visual[1], {{ win = group.win }})
assert(opened, "could not focus first visually displayed buffer: " .. tostring(open_err))
vim.fn.writefile({{ "ready" }}, vim.env.BG_CYCLE_READY)

local function poll()
  if vim.fn.filereadable(vim.env.BG_CYCLE_REQUEST) == 1 then
    vim.fn.delete(vim.env.BG_CYCLE_REQUEST)
    local result = capture()
    local tmp = vim.env.BG_CYCLE_SNAPSHOT .. ".tmp"
    vim.fn.writefile({{ vim.json.encode(result) }}, tmp)
    assert(os.rename(tmp, vim.env.BG_CYCLE_SNAPSHOT), "could not publish cycle snapshot atomically")
  end
  vim.defer_fn(poll, 15)
end
poll()
''',
        encoding="utf-8",
    )

    env = os.environ.copy()
    env.update(
        {
            "BG_TEST_ROOT": str(ROOT),
            "BG_TEST_TMP": str(temp_root),
            "BG_CYCLE_READY": str(ready),
            "BG_CYCLE_REQUEST": str(request),
            "BG_CYCLE_SNAPSHOT": str(snapshot),
            "BG_CYCLE_SNAPSHOT_TMP": str(snapshot_tmp),
            "BG_CYCLE_SCENARIO": "transfer",
            "XDG_STATE_HOME": str(state_dir),
            "NVIM_LOG_FILE": str(temp_root / "nvim.log"),
            "NVIM_APPNAME": "buffer-groups-cycle-test",
            "TERM": "xterm-256color",
            "LC_ALL": os.environ.get("LC_ALL", "C.UTF-8"),
        }
    )
    command = [nvim, "-u", "NONE", "-i", "NONE", "-n", "-c",
               "lua local ok, err = pcall(dofile, " + lua_quote(str(setup_lua)) + "); if not ok then vim.fn.writefile({tostring(err)}, vim.env.BG_CYCLE_STARTUP_ERROR); io.stderr:write(tostring(err)..'\\n'); vim.cmd('cquit 2') end"]
    env["BG_CYCLE_STARTUP_ERROR"] = str(startup_error)
    failures: list[str] = []
    output = bytearray()

    def run_case(count: int, scenario: str) -> None:
        env["BG_CYCLE_COUNT"] = str(count)
        env["BG_CYCLE_SCENARIO"] = scenario
        for path in (request, snapshot, snapshot_tmp, ready, startup_error):
            path.unlink(missing_ok=True)
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(ROOT)
            os.execvpe(nvim, command, env)
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 110, 0, 0))
        os.set_blocking(master, False)

        def wait_file(path: Path, label: str, timeout: float = 8) -> bool:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                drain(master, output)
                if path.is_file():
                    return True
                done, _ = os.waitpid(pid, os.WNOHANG)
                if done:
                    break
            failures.append(f"{count}-buffer {scenario}: timed out waiting for {label}")
            if startup_error.is_file():
                failures.append(startup_error.read_text(errors="replace"))
            elif output:
                failures.append(output[-3000:].decode(errors="replace"))
            return False

        try:
            if not wait_file(ready, "ready marker"):
                return

            def observe(label: str) -> dict | None:
                snapshot.unlink(missing_ok=True)
                request.write_text("capture", encoding="utf-8")
                if not wait_file(snapshot, label):
                    return None
                try:
                    return json.loads(snapshot.read_text(encoding="utf-8"))
                except (json.JSONDecodeError, OSError) as error:
                    failures.append(f"{count}-buffer {scenario}: invalid {label}: {error}")
                    return None

            initial = observe("initial visual order")
            if initial is None:
                return
            visual = initial["visual"]
            expected_members = sorted(initial["managed"])
            if sorted(visual) != expected_members or len(set(visual)) != count:
                failures.append(f"{count}-buffer {scenario}: public Bufferline membership mismatch: {initial}")
                return
            if visual != initial["managed"]:
                failures.append(f"{count}-buffer {scenario}: public Bufferline order is not core order: {initial}")
                return
            if initial["current"] != visual[0]:
                failures.append(f"{count}-buffer {scenario}: fixture did not focus first visual element: {initial}")
                return

            cases = [
                (b"\x1bl", 1, "Alt-l next"),
                (b"\x1bh", 0, "Alt-h previous"),
                (b"\x1bh", count - 1, "Alt-h wraps to last"),
                (b"\x1bl", 0, "Alt-l wraps to first"),
            ]
            for key, index, label in cases:
                os.write(master, key)
                # Give Neovim time to consume the literal ESC + key sequence
                # before requesting an observable public/core state snapshot.
                deadline = time.monotonic() + 0.16
                while time.monotonic() < deadline:
                    drain(master, output, 0.02)
                current = observe(label)
                if current is None:
                    return
                wanted = visual[index]
                if current["current"] != wanted:
                    failures.append(f"{count}-buffer {scenario}: {label} selected {current['current']}, expected visual buffer {wanted}; order={visual}")
                    return
                if current["visual"] != visual:
                    failures.append(f"{count}-buffer {scenario}: Bufferline membership/order changed after {label}: {current}")
                    return
                if sorted(current["managed"]) != expected_members:
                    failures.append(f"{count}-buffer {scenario}: membership changed after {label}: {current}")
                    return
                print(f"PASS cycle/{count}/{scenario}/{label}: {current['current']} in visual order {visual}")

            os.write(master, b"\x1b")
            time.sleep(0.04)
            os.write(master, b":qa!\r")
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                drain(master, output)
                done, wait_status = os.waitpid(pid, os.WNOHANG)
                if done:
                    if not os.WIFEXITED(wait_status) or os.WEXITSTATUS(wait_status) != 0:
                        failures.append(f"{count}-buffer {scenario}: Neovim exited abnormally ({wait_status})")
                    return
            failures.append(f"{count}-buffer {scenario}: Neovim did not exit after qa!")
        finally:
            def reap_until(timeout: float) -> bool:
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    try:
                        done, _ = os.waitpid(pid, os.WNOHANG)
                    except ChildProcessError:
                        return True
                    if done:
                        return True
                    time.sleep(0.04)
                return False

            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            if not reap_until(1.2):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                if not reap_until(1.2):
                    failures.append(f"{count}-buffer {scenario}: Neovim remained unreaped after SIGKILL")
            os.close(master)

    for count in (3, 4):
        for scenario in ("transfer", "close"):
            run_case(count, scenario)

    if failures:
        print("FAIL cycle TUI:\n" + "\n".join(failures), file=sys.stderr)
        return 1
    print("CYCLE_TUI_OK: real Bufferline order and Alt-h/l cycles verified through PTY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
