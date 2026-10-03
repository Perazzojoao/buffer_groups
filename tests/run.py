#!/usr/bin/env python3
"""Run buffer_groups contract suites with only Python's standard library."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "tests"
CORE_CASES = [
    "singlebuffer_refusal",
    "singlebuffer_new_buffer",
    "directional_initialization",
    "adopt_two_distinct_windows",
    "adopt_stacked_windows",
    "adopt_duplicate_currents",
    "refuse_more_than_two_windows",
    "membership_transfer_and_local_cycle",
    "new_file_and_foreign_buffer",
    "existing_buffer_transfer_policy",
    "modified_and_unloaded_buffers",
    "follow_buffer_disabled",
    "float_preview_preserves_owner",
    "rename_and_deferred_delete",
    "manual_window_close_merges",
    "close_hidden_member_preserves_display",
    "exclusions",
    "exclusion_predicates",
    "quit_counts_excluded_listed_files",
    "tabs_are_independent",
    "disable_reenable_and_setup_idempotence",
    "buffer_local_map_shadow_and_restore",
]


def find_plugin_paths() -> list[Path]:
    """Find installed Snacks/Bufferline roots without installing anything."""
    roots: list[Path] = []
    supplied = os.environ.get("BG_TEST_DEPS")
    if supplied:
        roots.extend(Path(item).expanduser() for item in supplied.split(os.pathsep) if item)
    home = Path.home()
    roots.extend(
        [
            home / ".local/share/nvim/lazy",
            home / ".local/share/nvim/site/pack",
            home / ".local/share/nvim/pack",
            home / ".config/nvim/pack",
        ]
    )

    found: set[Path] = set()
    for base in roots:
        if not base.exists():
            continue
        candidates = [base]
        candidates.extend(base.glob("*"))
        candidates.extend(base.glob("*/start/*"))
        candidates.extend(base.glob("*/opt/*"))
        candidates.extend(base.glob("pack/*/start/*"))
        candidates.extend(base.glob("pack/*/opt/*"))
        for candidate in candidates:
            if not candidate.is_dir():
                continue
            name = candidate.name.lower()
            if name in {"snacks.nvim", "bufferline.nvim"}:
                found.add(candidate.resolve())
            elif (candidate / "lua/snacks/init.lua").is_file() or (candidate / "lua/bufferline/init.lua").is_file():
                found.add(candidate.resolve())
    return sorted(found)


def base_env(temp_root: Path, nvim: str, plugin_paths: list[Path]) -> dict[str, str]:
    temp_root.mkdir(parents=True, exist_ok=True)
    state_root = temp_root / "xdg-state"
    state_root.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(
        {
            "BG_TEST_ROOT": str(ROOT),
            "BG_TEST_TMP": str(temp_root),
            "BG_TEST_PLUGIN_PATHS": os.pathsep.join(str(path) for path in plugin_paths),
            "BUFFER_GROUPS_ROOT": str(ROOT),
            "NVIM_APPNAME": "buffer-groups-test",
            "XDG_STATE_HOME": str(state_root),
            "NVIM_LOG_FILE": str(temp_root / "nvim.log"),
            "TERM": env.get("TERM", "xterm-256color"),
        }
    )
    return env


def run_nvim_script(nvim: str, script: Path, env: dict[str, str], cwd: Path) -> subprocess.CompletedProcess[str]:
    lua_path = str(script).replace("\\", "\\\\").replace('"', '\\"')
    plugin_paths = [path for path in env.get("BG_TEST_PLUGIN_PATHS", "").split(os.pathsep) if path]
    lua_paths = "{" + ", ".join(json.dumps(path) for path in plugin_paths) + "}"
    load_lua = (
        f'local ok, err = pcall(dofile, "{lua_path}"); '
        'if not ok then io.stderr:write(tostring(err) .. "\\n"); vim.cmd("cquit 2") end'
    )
    command = [
        nvim,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "-n",
        "--cmd",
        "lua vim.opt.runtimepath:prepend(vim.env.BG_TEST_ROOT); for _, p in ipairs(" + lua_paths + ") do vim.opt.runtimepath:append(p) end",
        "-c",
        "lua " + load_lua,
    ]
    return subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True, timeout=12)


def run_core(nvim: str, temp_root: Path) -> tuple[int, int]:
    passed = failed = 0
    for case in CORE_CASES:
        case_dir = temp_root / case
        case_dir.mkdir()
        status = case_dir / "status.txt"
        env = base_env(case_dir, nvim, [])
        env["BG_TEST_CASE"] = case
        env["BG_TEST_STATUS"] = str(status)
        try:
            result = run_nvim_script(nvim, TESTS / "core.lua", env, ROOT)
            returncode, output = result.returncode, (result.stdout + result.stderr).strip()
        except subprocess.TimeoutExpired as error:
            returncode = 124
            output = "timeout while running nvim\n" + "\n".join(
                part.decode(errors="replace") if isinstance(part, bytes) else (part or "")
                for part in (error.stdout, error.stderr)
            )
        success = returncode == 0 and status.is_file() and status.read_text().strip() == "ok"
        if success:
            print(f"PASS core/{case}")
            passed += 1
        else:
            print(f"FAIL core/{case}", file=sys.stderr)
            if output:
                print(output, file=sys.stderr)
            if status.is_file():
                print(status.read_text(), file=sys.stderr)
            failed += 1
    return passed, failed


def run_adapter(nvim: str, temp_root: Path) -> tuple[int, int]:
    script = TESTS / "adapter.lua"
    if not script.is_file():
        print("FAIL adapter: required tests/adapter.lua is missing", file=sys.stderr)
        return 0, 1
    case_dir = temp_root / "adapter"
    case_dir.mkdir()
    env = base_env(case_dir, nvim, [])
    try:
        result = run_nvim_script(nvim, script, env, ROOT)
    except subprocess.TimeoutExpired as error:
        print("FAIL adapter: nvim timed out", file=sys.stderr)
        for part in (error.stdout, error.stderr):
            if part:
                print(part.decode(errors="replace") if isinstance(part, bytes) else part, file=sys.stderr)
        return 0, 1
    output = (result.stdout + result.stderr).strip()
    if result.returncode == 0:
        print("PASS adapter")
        if output:
            print(output)
        return 1, 0
    print("FAIL adapter", file=sys.stderr)
    if output:
        print(output, file=sys.stderr)
    return 0, 1


def run_integration(nvim: str, temp_root: Path, plugin_paths: list[Path]) -> tuple[int, int]:
    script = TESTS / "integrations.lua"
    case_dir = temp_root / "integration"
    case_dir.mkdir()
    env = base_env(case_dir, nvim, plugin_paths)
    try:
        result = run_nvim_script(nvim, script, env, ROOT)
    except subprocess.TimeoutExpired as error:
        print("FAIL integration: nvim timed out", file=sys.stderr)
        for part in (error.stdout, error.stderr):
            if part:
                print(part.decode(errors="replace") if isinstance(part, bytes) else part, file=sys.stderr)
        return 0, 1
    output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        print("FAIL integration", file=sys.stderr)
        if output:
            print(output, file=sys.stderr)
        return 0, 1
    if "SKIP integration:" in output:
        print(output)
        return 0, 0
    print("PASS integration")
    if output:
        print(output)
    return 1, 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nvim", default=shutil.which("nvim"), help="Neovim executable (defaults to PATH nvim)")
    parser.add_argument("--core-only", action="store_true", help="run only the dependency-free core suite")
    parser.add_argument("--integration", action="store_true", help="run optional real Snacks and Bufferline integration")
    parser.add_argument("--tui", action="store_true", help="run actual key and mouse input in a PTY")
    args = parser.parse_args()
    if not args.nvim:
        parser.error("nvim was not found; pass --nvim PATH")
    nvim = str(Path(args.nvim).expanduser().resolve())
    if not Path(nvim).is_file():
        parser.error(f"Neovim executable does not exist: {nvim}")

    plugin_paths = find_plugin_paths()
    passed = failed = 0
    with tempfile.TemporaryDirectory(prefix="buffer-groups-tests-", dir="/tmp") as temporary:
        temp_root = Path(temporary)
        core_passed, core_failed = run_core(nvim, temp_root)
        passed += core_passed
        failed += core_failed
        if not args.core_only:
            adapter_passed, adapter_failed = run_adapter(nvim, temp_root)
            passed += adapter_passed
            failed += adapter_failed
        if args.integration:
            integration_passed, integration_failed = run_integration(nvim, temp_root, plugin_paths)
            passed += integration_passed
            failed += integration_failed
        if args.tui:
            try:
                tui = subprocess.run(
                    [sys.executable, str(TESTS / "tui.py"), "--nvim", nvim],
                    cwd=ROOT,
                    env=base_env(temp_root / "tui", nvim, plugin_paths),
                    text=True,
                    capture_output=True,
                    timeout=30,
                )
                tui_returncode = tui.returncode
                out = (tui.stdout + tui.stderr).strip()
            except subprocess.TimeoutExpired as error:
                tui_returncode = 124
                out = "TUI runner timed out\n" + "\n".join(
                    part.decode(errors="replace") if isinstance(part, bytes) else (part or "")
                    for part in (error.stdout, error.stderr)
                )
            if tui_returncode:
                print("FAIL tui", file=sys.stderr)
                if out:
                    print(out, file=sys.stderr)
                failed += 1
            else:
                print("PASS tui")
                if out:
                    print(out)
                passed += 1

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
