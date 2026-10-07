#!/usr/bin/env python3
"""Check Shift-Alt reorder keys and Alt cycling in an actual Neovim PTY."""

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
import termios
import time


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
    if ready:
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
        print("SKIP reorder TUI: Bufferline is not installed in BG_TEST_PLUGIN_PATHS or the local Neovim pack path")
        return 0

    temp_root = Path(tempfile.mkdtemp(prefix="buffer-groups-reorder-tui-", dir="/tmp"))
    state_dir = temp_root / "xdg-state"
    state_dir.mkdir()
    setup_lua = temp_root / "setup.lua"
    request = temp_root / "snapshot.request"
    snapshot = temp_root / "snapshot.json"
    ready = temp_root / "ready"
    setup_error = temp_root / "setup-error.txt"
    setup_lua.write_text(
        f'''local root = {lua_quote(str(ROOT))}
local temp = {lua_quote(str(temp_root))}
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append({lua_quote(str(bufferline))})
vim.o.showtabline = 2
vim.o.ttimeout = true
vim.o.ttimeoutlen = 500
vim.o.timeoutlen = 350
local api = vim.api
local plugin = require("buffer_groups")
local scenario = vim.env.BG_REORDER_SCENARIO
local buffers = {{ api.nvim_get_current_buf() }}
local function name(buf, label)
  api.nvim_buf_set_name(buf, temp .. "/" .. label .. ".txt")
  api.nvim_set_option_value("buflisted", true, {{ buf = buf }})
  api.nvim_set_option_value("buftype", "", {{ buf = buf }})
  api.nvim_buf_set_lines(buf, 0, -1, false, {{ label }})
  api.nvim_set_option_value("modified", false, {{ buf = buf }})
end
name(buffers[1], "a")
for index = 2, 4 do
  buffers[index] = api.nvim_create_buf(true, false)
  name(buffers[index], string.char(96 + index))
end
api.nvim_set_current_buf(buffers[2])
plugin.setup({{
  reordering = {{ enabled = true }},
  keymaps = {{ previous = "<A-h>", next = "<A-l>", reorder_left = "<A-H>", reorder_right = "<A-L>" }},
  winbar = {{ enabled = scenario == "groups" }},
}})
if scenario == "groups" then
  local ok, err = plugin.move("right")
  assert(ok, "could not initialize two groups: " .. tostring(err))
  local right = plugin.get_owner(buffers[2])
  local extra = api.nvim_create_buf(true, false)
  name(extra, "e")
  assert(plugin.open(extra, {{ win = right.win }}), "could not add second right-group member")
end
local adapter = require("buffer_groups.integrations.bufferline")
local Bufferline = require("bufferline")
Bufferline.setup(adapter.extend({{ options = {{ mode = "buffers", always_show_bufferline = true, show_buffer_icons = false, show_buffer_close_icons = false }} }}, {{ display = scenario == "groups" and "groups" or "buffers", managed_order = true }}))
assert(adapter.attach(), "Bufferline adapter did not attach")
local function capture()
  api.nvim_eval_statusline(vim.o.tabline, {{ use_tabline = true, maxwidth = vim.o.columns }})
  vim.cmd("redrawtabline")
  local visual = {{}}
  if scenario ~= "groups" then
    for _, element in ipairs(Bufferline.get_elements().elements) do visual[#visual + 1] = element.id end
  end
  local st = plugin.get_state()
  local groups = {{}}
  local managed = {{}}
  for _, group in ipairs(st.groups) do
    local item = {{ id = group.id, buffers = vim.deepcopy(group.buffers) }}
    if scenario == "groups" then
      local option = api.nvim_get_option_value("winbar", {{ win = group.win }})
      item.text = api.nvim_eval_statusline(option, {{ winid = group.win, use_winbar = true, maxwidth = vim.o.columns }}).str
      local positioned = {{}}
      item.omitted = {{}}
      for _, buf in ipairs(group.buffers) do
        local filename = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":t")
        local position = item.text:find(filename, 1, true)
        if position then
          positioned[#positioned + 1] = {{ buf = buf, position = position }}
        else
          item.omitted[#item.omitted + 1] = filename
        end
      end
      table.sort(positioned, function(a, b) return a.position < b.position end)
      item.visual = {{}}
      for _, entry in ipairs(positioned) do item.visual[#item.visual + 1] = entry.buf end
    end
    groups[#groups + 1] = item
    vim.list_extend(managed, group.buffers)
  end
  return {{ groups = groups, managed = managed, visual = visual, current = api.nvim_get_current_buf(), enabled = plugin.is_reordering_enabled() }}
end
local function poll()
  if vim.fn.filereadable(vim.env.BG_REORDER_REQUEST) == 1 then
    vim.fn.delete(vim.env.BG_REORDER_REQUEST)
    local tmp = vim.env.BG_REORDER_SNAPSHOT .. ".tmp"
    vim.fn.writefile({{ vim.json.encode(capture()) }}, tmp)
    assert(os.rename(tmp, vim.env.BG_REORDER_SNAPSHOT), "could not publish PTY snapshot")
  end
  vim.defer_fn(poll, 15)
end
vim.fn.writefile({{ "ready" }}, vim.env.BG_REORDER_READY)
poll()
''',
        encoding="utf-8",
    )

    env = os.environ.copy()
    env.update({
        "BG_TEST_ROOT": str(ROOT),
        "BG_TEST_PLUGIN_PATHS": str(bufferline),
        "BG_REORDER_READY": str(ready),
        "BG_REORDER_REQUEST": str(request),
        "BG_REORDER_SNAPSHOT": str(snapshot),
        "BG_REORDER_SETUP_ERROR": str(setup_error),
        "XDG_STATE_HOME": str(state_dir),
        "NVIM_LOG_FILE": str(temp_root / "nvim.log"),
        "NVIM_APPNAME": "buffer-groups-reorder-tui-test",
        "TERM": "xterm-256color",
        "LC_ALL": os.environ.get("LC_ALL", "C.UTF-8"),
    })
    command = [nvim, "-u", "NONE", "-i", "NONE", "-n", "-c",
               "lua local ok, err = pcall(dofile, " + lua_quote(str(setup_lua)) + "); if not ok then vim.fn.writefile({tostring(err)}, vim.env.BG_REORDER_SETUP_ERROR); io.stderr:write(tostring(err)..'\\n'); vim.cmd('cquit 2') end"]
    output = bytearray()
    failures: list[str] = []

    def run_case(scenario: str) -> None:
        env["BG_REORDER_SCENARIO"] = scenario
        for path in (request, snapshot, ready, setup_error):
            path.unlink(missing_ok=True)
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(ROOT)
            os.execvpe(nvim, command, env)
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 180, 0, 0))
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
            failures.append(f"{scenario}: timed out waiting for {label}")
            if setup_error.is_file():
                failures.append(setup_error.read_text(errors="replace"))
            elif output:
                failures.append(output[-3000:].decode(errors="replace"))
            return False

        def observe(label: str) -> dict | None:
            snapshot.unlink(missing_ok=True)
            request.write_text("snapshot", encoding="utf-8")
            if not wait_file(snapshot, label):
                return None
            try:
                return json.loads(snapshot.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError) as error:
                failures.append(f"{scenario}: invalid {label}: {error}")
                return None

        try:
            if not wait_file(ready, "ready marker"):
                return
            before = observe("initial state")
            if before is None:
                return
            def assert_rendered(snapshot: dict, label: str) -> bool:
                if scenario == "groups":
                    for group in snapshot["groups"]:
                        if group.get("visual") != group["buffers"]:
                            failures.append(f"{scenario}: {label} winbar order differs from its group order: {group}")
                            return False
                elif snapshot["visual"] != snapshot["managed"]:
                    failures.append(f"{scenario}: {label} Bufferline order differs from group order: {snapshot}")
                    return False
                return True

            if not assert_rendered(before, "initial"):
                return
            source = before["current"]
            current_group = next((g for g in before["groups"] if source in g["buffers"]), None)
            if current_group is None:
                failures.append(f"{scenario}: current buffer has no group: {before}")
                return
            source_index = current_group["buffers"].index(source)
            if source_index == 0:
                os.write(master, b"\x1bL")
                wanted_index = source_index + 1
                key = "Shift-Alt-L"
            else:
                os.write(master, b"\x1bH")
                wanted_index = source_index - 1
                key = "Shift-Alt-H"
            time.sleep(0.18)
            after_reorder = observe(key)
            if after_reorder is None:
                return
            wanted = list(current_group["buffers"])
            wanted[source_index], wanted[wanted_index] = wanted[wanted_index], wanted[source_index]
            actual_group = next(g for g in after_reorder["groups"] if g["id"] == current_group["id"])
            if actual_group["buffers"] != wanted:
                failures.append(f"{scenario}: {key} did not swap adjacent buffers: {after_reorder}")
                return
            if after_reorder["current"] != source:
                failures.append(f"{scenario}: {key} changed focus: {after_reorder}")
                return
            if not assert_rendered(after_reorder, key):
                return

            opposite_key = b"\x1bH" if key.endswith("L") else b"\x1bL"
            os.write(master, opposite_key)
            time.sleep(0.18)
            restored = observe("opposite Shift-Alt reorder")
            if restored is None:
                return
            restored_group = next(g for g in restored["groups"] if g["id"] == current_group["id"])
            if restored_group["buffers"] != current_group["buffers"]:
                failures.append(f"{scenario}: opposite Shift-Alt mapping did not restore order: {restored}")
                return
            if not assert_rendered(restored, "opposite reorder"):
                return
            os.write(master, b"\x1bL" if key.endswith("L") else b"\x1bH")
            time.sleep(0.18)
            after_reorder = observe("repeat Shift-Alt reorder")
            if after_reorder is None:
                return
            active = next(g for g in after_reorder["groups"] if source in g["buffers"])
            if active["buffers"] != wanted or not assert_rendered(after_reorder, "repeated reorder"):
                failures.append(f"{scenario}: repeated Shift-Alt mapping did not restore the reordered state: {after_reorder}")
                return

            # The ordinary lowercase Alt keys continue to cycle by group order.
            current_index = active["buffers"].index(source)
            cycle_key = b"\x1bl" if current_index + 1 < len(active["buffers"]) else b"\x1bh"
            cycle_index = current_index + (1 if cycle_key.endswith(b"l") else -1)
            os.write(master, cycle_key)
            time.sleep(0.18)
            after_cycle = observe("Alt cycle")
            if after_cycle is None:
                return
            expected_current = active["buffers"][cycle_index]
            if after_cycle["current"] != expected_current:
                failures.append(f"{scenario}: lowercase Alt cycle selected {after_cycle['current']}, expected {expected_current}")
                return
            if not assert_rendered(after_cycle, "Alt cycle"):
                return
            print(f"PASS reorder TUI/{scenario}: {key}, Bufferline render, and Alt cycling")
            os.write(master, b"\x1b")
            time.sleep(0.05)
            os.write(master, b":qa!\r")
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                drain(master, output)
                done, wait_status = os.waitpid(pid, os.WNOHANG)
                if done:
                    if not os.WIFEXITED(wait_status) or os.WEXITSTATUS(wait_status) != 0:
                        failures.append(f"{scenario}: Neovim exited abnormally ({wait_status})")
                    return
            failures.append(f"{scenario}: Neovim did not exit after qa!")
        finally:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            os.close(master)

    try:
        run_case("single")
        run_case("groups")
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)
    if failures:
        print("FAIL reorder TUI:\n" + "\n".join(failures), file=sys.stderr)
        return 1
    print("REORDER_TUI_OK: Shift-Alt reorder, Bufferline display order, and Alt cycles verified through PTY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
