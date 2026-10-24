#!/usr/bin/env python3
"""Filee CLI for agents: status, the selection, tabs, the drop stack, and the filee:// actions. Python 3 standard library, runs on Python 3.9.

Reads ~/.filee/run/live.json, which the running app rewrites on every navigation, selection and transfer
(FILEE_HOME moves ~/.filee). Commands that change something go through the app (filee:// URLs, opened in the
background with the running copy), so only the app acts. Every command takes --json
(agent interface: ~/ai/.claude/skills/appee/references/agent-interface.md).

    filee status                 # running, active folder, selection count, transfers, drop stack
    filee selection              # the selected paths in the active pane
    filee tabs                   # every pane's tabs
    filee stack                  # the drop stack
    filee reveal <path>          # a folder in the active pane, or a file selected in its folder
    filee new-tab [path]         # a new tab in the active pane
    filee stack-add <path>...    # add paths to the drop stack
    filee stack-clear            # empty the drop stack (the files stay where they are)
    filee show                   # bring the Filee window to the front
    filee describe --json        # what Filee can do, for agents
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
import urllib.parse
import uuid
from pathlib import Path

HOME = Path(os.path.expanduser(os.environ.get("FILEE_HOME", "~/.filee")))
LIVE = HOME / "run" / "live.json"
SAVED = HOME / "state.json"
APP = Path("/Applications/Filee.app")
OPEN_TOOL = os.environ.get("FILEE_OPEN_TOOL", "/usr/bin/open")
JSON = False

COMMANDS = [
    ("describe", "filee describe --json", "What Filee can do, for agents", "read", False),
    ("status", "filee status --json", "Running, active folder, selection count, transfers running, drop stack size", "read", False),
    ("selection", "filee selection [-n 50] --json", "The selected paths in the active pane", "read", True),
    ("tabs", "filee tabs --json", "Every pane's tabs (folder paths) and the active one", "read", True),
    ("stack", "filee stack [-n 50] --json", "The drop stack: paths collected to copy or move later", "read", False),
    ("reveal", "filee reveal <path> [--show] --json", "Show a folder in the active pane, or a file selected in its folder", "write", True),
    ("new-tab", "filee new-tab [path] [--show] --json", "Open a new tab in the active pane (default: the new-tab folder)", "write", True),
    ("stack-add", "filee stack-add <path>... --json", "Add files or folders to the drop stack", "write", True),
    ("stack-clear", "filee stack-clear --json", "Empty the drop stack (the files stay where they are)", "write", True),
    ("show", "filee show --json", "Bring the Filee window to the front (takes the screen)", "write", True),
]


def emit(data: dict, human: str = "") -> int:
    """Print the result: 1 JSON document with --json, else the human line."""
    if JSON:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    elif human:
        print(human)
    return 0


def fail(error: str, hint: str = "", code: int = 1) -> int:
    print(f"❌ {error}" + (f" {hint}" if hint else ""), file=sys.stderr)
    if JSON:
        print(json.dumps({"ok": False, "error": error, "hint": hint}, ensure_ascii=False))
    return code


def read_json(path: Path) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def read_live() -> dict:
    return read_json(LIVE)


def pid_alive(pid) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def installed_pid() -> int | None:
    """The pid of /Applications/Filee.app when it runs without live.json (a build before 0.1.1). Real home only."""
    if "FILEE_HOME" in os.environ:
        return None
    r = subprocess.run(["pgrep", "-f", str(APP / "Contents/MacOS/Filee")], capture_output=True, text=True)
    pids = [int(x) for x in r.stdout.split() if x.isdigit()]
    return pids[0] if pids else None


def app_version() -> str:
    try:
        with open(APP / "Contents/Info.plist", "rb") as f:
            return plistlib.load(f).get("CFBundleShortVersionString", "")
    except (OSError, plistlib.InvalidFileException):
        return ""


def live_or_fail() -> tuple:
    live = read_live()
    if pid_alive(live.get("pid")):
        return live, 0
    if installed_pid():
        return {}, fail("This Filee build doesn't publish its live state", "Install Filee 0.1.1 or later: ./build.sh --install", 1)
    return {}, fail("Filee isn't running", "Start it: open -a Filee", 4)


def send(action: str, params: list | None = None, wait: float = 3.0) -> dict:
    """Open filee://<action> in the background with the running copy and wait until live.json echoes the request id."""
    live = read_live()
    if not pid_alive(live.get("pid")):
        if installed_pid():
            return {"ok": False, "error": "This Filee build doesn't confirm actions", "hint": "Install Filee 0.1.1 or later: ./build.sh --install", "code": 1}
        return {"ok": False, "error": "Filee isn't running", "hint": "Start it: open -a Filee", "code": 4}
    rid = uuid.uuid4().hex[:12]
    query = urllib.parse.urlencode((params or []) + [("rid", rid)])
    target = ["-a", live["bundle_path"]] if live.get("bundle_path") else []
    if subprocess.run([OPEN_TOOL, "-g", *target, f"filee://{action}?{query}"]).returncode != 0:
        return {"ok": False, "error": f"open filee://{action} failed", "hint": "", "code": 1}
    deadline = time.time() + wait
    while time.time() < deadline:
        last = read_live().get("last_action") or {}
        if last.get("rid") == rid:
            if not last.get("ok"):
                return {"ok": False, "error": f"Filee couldn't run '{action}'", "hint": "Check the path, and that a Filee window is open", "code": 1}
            return {"ok": True, "confirmed": True, "action": action}
        time.sleep(0.05)
    return {"ok": False, "error": f"Filee didn't confirm '{action}' within {wait:.0f} s", "hint": "Check that Filee 0.1.1 or later runs", "code": 1}


def run_action(action: str, params: list | None, human: str) -> int:
    r = send(action, params)
    if not r["ok"]:
        return fail(r["error"], r.get("hint", ""), r.get("code", 1))
    live = read_live()
    r["active_path"] = live.get("active_path")
    r["selection_count"] = live.get("selection_count", 0)
    r["stack"] = len(live.get("stack") or [])
    return emit(r, human)


def show_params(args: argparse.Namespace) -> list:
    return [("show", "1")] if getattr(args, "show", False) else []


def existing(path: str) -> Path | None:
    p = Path(os.path.expanduser(path)).resolve()
    return p if p.exists() else None


def cmd_describe(args: argparse.Namespace) -> int:
    data = {
        "contract": 1, "app": "filee", "name": "Filee", "version": app_version(),
        "summary": "Native macOS dual-pane file manager (replaces Path Finder)", "kind": "macos-app",
        "bundle_id": "com.nicolasdeville.filee", "url_scheme": "filee", "port": None, "home": "~/.filee",
        "hotkeys": [],
        "commands": [{"name": n, "usage": u, "does": d, "effect": e, "needs_app": a} for n, u, d, e, a in COMMANDS],
        "privacy": "status prints the active folder and counts. selection, tabs and stack print paths, never file contents.",
    }
    if JSON:
        return emit(data)
    for n, u, d, e, a in COMMANDS:
        print(f"{u:<40} {d}{'' if e == 'read' else f'  ({e})'}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    live = read_live()
    running = pid_alive(live.get("pid"))
    pid = live.get("pid") if running else installed_pid()
    stack = live.get("stack") if running else read_json(SAVED).get("dropStack")
    data = {
        "ok": True, "app": "filee", "running": bool(pid), "pid": pid,
        "version": (live.get("version") if running else None) or app_version(),
        "live": running,
        "windows": live.get("windows") if running else None,
        "active_path": live.get("active_path") if running else None,
        "selection_count": live.get("selection_count") if running else None,
        "transfers": live.get("transfers") if running else None,
        "stack": len(stack or []),
        "home": str(HOME),
    }
    if not pid:
        human = "⏹  not running"
    elif not running:
        human = f"✅ running (pid {pid}), no live state: Filee {data['version']} predates the agent interface"
    else:
        human = (f"✅ running, {data['selection_count']} selected, {data['transfers']} transfers, "
                 f"{data['stack']} in the drop stack")
    return emit(data, human)


def cmd_selection(args: argparse.Namespace) -> int:
    live, code = live_or_fail()
    if code:
        return code
    sel = live.get("selection") or []
    total = live.get("selection_count", len(sel))
    shown = sel[: max(args.n, 1)]
    if JSON:
        return emit({"ok": True, "folder": live.get("active_path"), "count": total, "paths": shown, "more": total > len(shown)})
    for p in shown:
        print(p)
    if total > len(shown):
        print(f"… {total - len(shown)} more", file=sys.stderr)
    return 0


def cmd_tabs(args: argparse.Namespace) -> int:
    live, code = live_or_fail()
    if code:
        return code
    panes = live.get("panes") or []
    if JSON:
        return emit({"ok": True, "active_pane": live.get("active_pane"), "dual_pane": live.get("dual_pane"), "panes": panes})
    for i, p in enumerate(panes):
        mark = "▶" if i == live.get("active_pane") else " "
        print(f"{mark} pane {i + 1}")
        for j, t in enumerate(p.get("tabs") or []):
            print(f"   {'•' if j == p.get('active_tab') else ' '} {t}")
    return 0


def cmd_stack(args: argparse.Namespace) -> int:
    live = read_live()
    stack = live.get("stack") if pid_alive(live.get("pid")) else read_json(SAVED).get("dropStack")
    stack = stack or []
    shown = stack[: max(args.n, 1)]
    if JSON:
        return emit({"ok": True, "count": len(stack), "paths": shown, "more": len(stack) > len(shown)})
    for p in shown:
        print(p)
    return 0


def cmd_reveal(args: argparse.Namespace) -> int:
    p = existing(args.path)
    if not p:
        return fail(f"Nothing at {args.path}", "Give the path of an existing file or folder")
    return run_action("reveal", [("path", str(p))] + show_params(args), f"📂 Revealed {p}")


def cmd_new_tab(args: argparse.Namespace) -> int:
    params = show_params(args)
    if args.path:
        p = existing(args.path)
        if not p or not p.is_dir():
            return fail(f"Not a folder: {args.path}", "Give the path of an existing folder")
        params = [("path", str(p))] + params
    return run_action("new-tab", params, "🗂  New tab")


def cmd_stack_add(args: argparse.Namespace) -> int:
    paths = [existing(x) for x in args.paths]
    missing = [x for x, p in zip(args.paths, paths) if not p]
    if missing:
        return fail(f"Nothing at {missing[0]}", "Give paths of existing files or folders")
    return run_action("stack-add", [("path", str(p)) for p in paths], f"📥 {len(paths)} added to the drop stack")


def cmd_stack_clear(args: argparse.Namespace) -> int:
    return run_action("stack-clear", None, "🧹 Drop stack empty")


def cmd_show(args: argparse.Namespace) -> int:
    return run_action("show", [("show", "1")], "🪟 Filee in front")


def main() -> int:
    global JSON
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="print 1 JSON document (for agents)")
    p = argparse.ArgumentParser(prog="filee", description="Filee file manager: status, selection, tabs, drop stack, actions.", parents=[common])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("describe", parents=[common], help="what Filee can do, for agents").set_defaults(func=cmd_describe)
    sub.add_parser("status", parents=[common], help="running, active folder, selection").set_defaults(func=cmd_status)
    s = sub.add_parser("selection", parents=[common], help="the selected paths")
    s.add_argument("-n", type=int, default=50)
    s.set_defaults(func=cmd_selection)
    sub.add_parser("tabs", parents=[common], help="every pane's tabs").set_defaults(func=cmd_tabs)
    s = sub.add_parser("stack", parents=[common], help="the drop stack")
    s.add_argument("-n", type=int, default=50)
    s.set_defaults(func=cmd_stack)
    r = sub.add_parser("reveal", parents=[common], help="show a folder, or a file in its folder")
    r.add_argument("path")
    r.add_argument("--show", action="store_true", help="bring Filee to the front")
    r.set_defaults(func=cmd_reveal)
    t = sub.add_parser("new-tab", parents=[common], help="a new tab in the active pane")
    t.add_argument("path", nargs="?")
    t.add_argument("--show", action="store_true", help="bring Filee to the front")
    t.set_defaults(func=cmd_new_tab)
    a = sub.add_parser("stack-add", parents=[common], help="add paths to the drop stack")
    a.add_argument("paths", nargs="+")
    a.set_defaults(func=cmd_stack_add)
    sub.add_parser("stack-clear", parents=[common], help="empty the drop stack").set_defaults(func=cmd_stack_clear)
    sub.add_parser("show", parents=[common], help="bring the window to the front").set_defaults(func=cmd_show)
    args = p.parse_args()
    JSON = args.json
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
