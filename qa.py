"""End-to-end QA for Filee: drives build/Filee.app with scripted steps on fixture folders.

The app runs with its own config home (FILEE_HOME) and fixture folders in $TMPDIR/filee-qa, so real
folders are never written to. Each suite writes report.json and screenshots to its out folder.

    python3 qa.py                  # all suites
    python3 qa.py --only ops       # 1 suite
    python3 qa.py --list           # suite names
"""

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import time
import zlib
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
APP = ROOT / "build/Filee.app/Contents/MacOS/Filee"
BASE = Path(os.environ.get("TMPDIR", "/tmp")) / "filee-qa"
YYMMDD = datetime.now().strftime("%y%m%d")


def png_bytes(w: int, h: int, rgb: tuple) -> bytes:
    """A small valid PNG, so Quick Look and thumbnails have real images."""
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def build_fixtures(base: Path) -> dict:
    """Fresh fixture folders for 1 suite."""
    if base.exists():
        shutil.rmtree(base)
    a, b, big = base / "A", base / "B", base / "big"
    for d in (a / "sub" / "deeper", b, big):
        d.mkdir(parents=True, exist_ok=True)
    (a / "alpha.txt").write_text("alpha", encoding="utf-8")
    (a / "beta.md").write_text("# beta", encoding="utf-8")
    (a / "260320-roadmap.pptx").write_bytes(b"pptx")
    (a / "notes for the world summit ai in amsterdam with a deliberately very long file name.md").write_text("x", encoding="utf-8")
    (a / ".hidden").write_text("h", encoding="utf-8")
    (a / "sub" / "inner.txt").write_text("inner", encoding="utf-8")
    (a / "sub" / "deeper" / "deep.txt").write_text("deep", encoding="utf-8")
    for i, color in enumerate([(231, 76, 60), (11, 107, 203), (47, 138, 58)], start=1):
        (a / f"IMG0{i}.png").write_bytes(png_bytes(64, 48, color))
    pics = base / "pics"
    pics.mkdir(parents=True, exist_ok=True)
    for i in range(5):
        (pics / f"photo-{i}.png").write_bytes(png_bytes(120, 80, (40 * i, 100, 200 - 30 * i)))
    for i in range(10000):
        (big / f"file-{i:05d}.txt").write_text("", encoding="utf-8")
    # A folder with a .filee-icon.svg shows that image in the sidebar; the same SVG is a volume's logo (volumeIcons).
    logo = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="28" fill="#e2231a"/></svg>'
    (base / "Branded").mkdir(exist_ok=True)
    (base / "Branded" / ".filee-icon.svg").write_text(logo, encoding="utf-8")
    (base / "volume-logo.svg").write_text(logo, encoding="utf-8")
    return {"A": str(a), "B": str(b), "big": str(big), "pics": str(pics), "branded": str(base / "Branded"),
            "volumeLogo": str(base / "volume-logo.svg")}


def write_home(home: Path, fx: dict):
    """Config home for QA: new tabs open in the fixtures, jumps point to them, 1 test action."""
    home.mkdir(parents=True, exist_ok=True)
    settings = {"newTabPath": fx["A"], "jumps": {"k": fx["A"], "a": fx["B"]},
                "favourites": [{"name": "A", "path": fx["A"]}, {"name": "B", "path": fx["B"]}],
                "volumeIcons": {"Philips": fx["volumeLogo"]}}
    (home / "settings.json").write_text(json.dumps(settings, indent=2), encoding="utf-8")
    actions = [
        {"name": "Mark done", "command": ["/usr/bin/touch", "{path}.done"], "extensions": ["txt", "md"], "mode": "background", "key": "ctrl+cmd+m"},
        # An external program that takes the path as an argument (decision 48).
        {"name": "Back up", "command": ["/bin/cp", "{path}", "{path}.bak"], "extensions": ["png", "jpg"], "mode": "background"},
    ]
    (home / "actions.json").write_text(json.dumps(actions, indent=2), encoding="utf-8")
    state = {"panes": [{"tabs": [{"path": fx["A"]}], "activeTab": 0}, {"tabs": [{"path": fx["B"]}], "activeTab": 0}],
             "dualPane": True, "activePane": 0, "frame": "{{80, 80}, {1400, 900}}"}
    (home / "state.json").write_text(json.dumps(state), encoding="utf-8")


def system_is_dark() -> bool:
    """macOS appearance: the first theme switch goes to the other one."""
    r = subprocess.run(["defaults", "read", "-g", "AppleInterfaceStyle"], capture_output=True, text=True)
    return r.stdout.strip() == "Dark"


def suites(fx: dict) -> dict:
    A, B, big, pics = fx["A"], fx["B"], fx["big"], fx.get("pics", "")
    branded = fx.get("branded", "")
    first, second = ("light", "dark") if system_is_dark() else ("dark", "light")
    return {
        "browse": [
            {"op": "navigate", "pane": 0, "path": A},
            {"op": "expect", "label": "A listed, hidden file not shown", "visible": 8, "path": A},
            {"op": "click", "target": "type:powerpoint"},
            {"op": "expect", "label": "type filter: PowerPoint shows the deck and the folder", "visible": 2, "types": "powerpoint"},
            {"op": "screenshot", "name": "00-type-filter"},
            {"op": "command", "id": "typeFilter", "args": "markdown"},
            {"op": "expect", "label": "Show Only Markdown Files", "visible": 3, "types": "markdown"},
            {"op": "select", "names": ["sub"]},
            {"op": "key", "keys": "enter"},
            {"op": "expect", "label": "the filter stays with the tab in a subfolder", "path": A + "/sub", "visible": 1, "types": "markdown"},
            {"op": "key", "keys": "cmd+up"},
            {"op": "click", "target": "type:markdown"},
            {"op": "expect", "label": "a 2nd click on the type shows everything again", "visible": 8, "types": "all"},
            {"op": "key", "keys": "cmd+g"},
            {"op": "expect", "label": "cmd+g opens the path bar", "pathEditing": True},
            {"op": "key", "keys": "escape"},
            {"op": "key", "keys": "cmd+b"},
            {"op": "expect", "label": "cmd+b hides the sidebar", "sidebar": False},
            {"op": "key", "keys": "cmd+b"},
            {"op": "expect", "label": "cmd+b shows it again", "sidebar": True},
            {"op": "select", "pane": 0, "names": ["beta.md"]},
            {"op": "key", "keys": "cmd+="},
            {"op": "expect", "label": "cmd+= enlarges the files, the tab names, the path and the type icons, and keeps the selection",
             "zoom": 1, "selected": ["beta.md"]},
            {"op": "screenshot", "name": "00-zoom"},
            {"op": "key", "keys": "cmd+0"},
            {"op": "expect", "label": "cmd+0 resets the size and leaves the sidebar", "zoom": 0, "sidebar": True},
            {"op": "expect", "label": "rounded corners by default", "corners": "rounded", "radius": 4},
            {"op": "command", "id": "focusFavourites"},
            {"op": "settings", "set": {"windowCorners": "square", "cornerRadius": 0}},
            {"op": "expect", "label": "settings.json squares the window and the highlights at once, selections stay",
             "corners": "square", "radius": 0, "sidebarSelected": A},
            {"op": "screenshot", "name": "00-square"},
            {"op": "settings", "set": {"windowCorners": "rounded", "cornerRadius": 8}},
            {"op": "expect", "label": "and rounds them again", "corners": "rounded", "radius": 8, "selected": ["beta.md"]},
            {"op": "settings", "set": {"cornerRadius": 4}},
            {"op": "key", "keys": "cmd+h"},
            {"op": "expect", "label": "cmd+h goes to the home folder", "path": "~"},
            {"op": "navigate", "pane": 0, "path": A},
            {"op": "wait", "ms": 300},
            {"op": "expect", "label": "under the tabs: the folder's folders and files, and the volume's free space",
             "countContains": ["1 folder · 7 files", " free"]},
            {"op": "expect", "label": "a folder with a .filee-icon.svg shows that image", "customIcon": branded},
            {"op": "expect", "label": "name column fits the longest name", "nameFits": True},
            {"op": "screenshot", "name": "01-list"},
            {"op": "select", "pane": 0, "names": ["sub"]},
            {"op": "key", "keys": "cmd+i"},
            {"op": "wait", "ms": 500},
            {"op": "expect", "label": "cmd+i: a folder's size, size on disk and contents, walked in the background",
             "infoContains": ["Size\t9 B\n", "On disk\t", "Files\t2\n", "Folders\t1\n", "Permissions\tdrwx"]},
            {"op": "select", "pane": 0, "names": ["IMG01.png"]},
            {"op": "key", "keys": "ctrl+cmd+i"},
            {"op": "wait", "ms": 500},
            {"op": "expect", "label": "ctrl+cmd+i still opens Get Info: an image's size on disk and dimensions",
             "infoContains": ["IMG01.png", "On disk\t", "Dimensions\t64 × 48 px"]},
            {"op": "infoClose"},
            {"op": "select", "names": ["sub"]},
            {"op": "key", "keys": "enter"},
            {"op": "expect", "label": "Enter opens a folder", "path": A + "/sub"},
            {"op": "key", "keys": "cmd+up"},
            {"op": "expect", "label": "cmd+up goes back up and selects the folder we came from", "path": A, "selected": ["sub"]},
            {"op": "key", "keys": "cmd+["},
            {"op": "expect", "label": "cmd+[ goes back", "path": A + "/sub"},
            {"op": "key", "keys": "cmd+]"},
            {"op": "expect", "label": "cmd+] goes forward", "path": A},
            {"op": "key", "keys": "cmd+down"},
            {"op": "expect", "label": "cmd+down selects the last item and stays in the folder", "path": A, "selectedLast": True},
            {"op": "navigate", "pane": 0, "path": A + "/sub"},
            {"op": "key", "keys": "cmd+1"},
            {"op": "key", "keys": "alt+cmd+up"},
            {"op": "expect", "label": "alt+cmd+up shows the enclosing folder in the other pane, this folder selected, dual pane on",
             "pane": 1, "path": A, "selected": ["sub"], "activePane": 0, "dual": True},
            {"op": "expect", "label": "and the active pane stays in its folder", "path": A + "/sub"},
            {"op": "navigate", "pane": 0, "path": A + "/sub/deeper"},
            {"op": "expect", "label": "the path above the files shows each folder down to this one", "crumbsEnd": ["A", "sub", "deeper"]},
            {"op": "crumb", "title": "A"},
            {"op": "expect", "label": "a click on a folder in the path goes there and selects the folder we came from",
             "path": A, "selected": ["sub"], "pathEditing": False},
            {"op": "select", "names": ["sub"]},
            {"op": "key", "keys": "right"},
            {"op": "expect", "label": "right arrow expands the folder in place", "path": A},
            {"op": "command", "id": "collapseAll"},
            {"op": "expect", "label": "Collapse All closes every folder", "rows": 8},
            {"op": "key", "keys": "alt+cmd+right"},
            {"op": "expect", "label": "alt+cmd+right expands all, 1 level", "rows": 10},
            {"op": "command", "id": "expandAll"},
            {"op": "expect", "label": "Expand All again goes 1 level deeper", "rows": 11},
            {"op": "select", "names": ["sub/deeper/deep.txt"]},
            {"op": "key", "keys": "alt+cmd+left"},
            {"op": "expect", "label": "alt+cmd+left collapses all, selects the top folder", "rows": 8, "selected": ["sub"]},
            {"op": "click", "target": "titleCopy"},
            {"op": "expect", "label": "the title bar copy button copies the full path", "clipboard": A},
            {"op": "click", "pane": 1, "target": "pathField"},
            {"op": "expect", "label": "a click on a pane's path opens it for editing in that pane", "pathEditing": True, "activePane": 1},
            {"op": "pastePath", "pane": 1, "text": "'" + A + "/sub/inner.txt'\n"},
            {"op": "key", "keys": "enter"},
            {"op": "expect", "label": "a pasted file path (quoted) goes to its folder and selects it", "pane": 1,
             "path": A + "/sub", "selected": ["inner.txt"], "pathEditing": False},
            {"op": "navigate", "pane": 1, "path": B},
            {"op": "navigate", "pane": 0, "path": A},
            {"op": "select", "names": ["sub"]},
            {"op": "key", "keys": "cmd+4"},
            {"op": "expect", "label": "cmd+4 columns", "view": "columns"},
            {"op": "select", "names": ["sub"]},
            {"op": "key", "keys": "right"},
            {"op": "expect", "label": "columns: right enters the folder's column", "selected": ["deeper"]},
            {"op": "key", "keys": "right"},
            {"op": "expect", "label": "columns: right again goes 1 level deeper", "selected": ["deep.txt"]},
            {"op": "screenshot", "name": "02-columns"},
            {"op": "key", "keys": "left"},
            {"op": "key", "keys": "left"},
            {"op": "expect", "label": "columns: left comes back", "selected": ["sub"]},
            {"op": "key", "keys": "cmd+3"},
            {"op": "expect", "label": "cmd+3 thumbnails", "view": "thumbnails"},
            {"op": "wait", "ms": 800},
            {"op": "screenshot", "name": "03-thumbnails"},
            {"op": "key", "keys": "cmd+5"},
            {"op": "expect", "label": "cmd+5 list", "view": "list"},
            {"op": "key", "keys": "tab"},
            {"op": "expect", "label": "Tab switches the active pane", "activePane": 1},
            {"op": "key", "keys": "tab"},
            {"op": "expect", "label": "Tab switches back", "activePane": 0},
            {"op": "key", "keys": "cmd+1"},
            {"op": "expect", "label": "cmd+1 single pane", "dual": False},
            {"op": "screenshot", "name": "04-single"},
            {"op": "key", "keys": "cmd+2"},
            {"op": "expect", "label": "cmd+2 dual pane", "dual": True},
            {"op": "expect", "label": "mounted volumes have an eject button, the startup disk none", "ejectButtons": True},
            {"op": "select", "names": ["alpha.txt"]},
            {"op": "key", "keys": "shift+cmd+d"},
            {"op": "expect", "label": "shift+cmd+d copies the path and says so in a toast", "statusContains": "Copied path " + A + "/alpha.txt"},
            {"op": "screenshot", "name": "05c-toast"},
            {"op": "key", "keys": "f1"},
            {"op": "expect", "label": "F1 (Fn+= on the Kinesis) toggles to single pane", "dual": False},
            {"op": "key", "keys": "f1"},
            {"op": "expect", "label": "F1 again: dual pane", "dual": True},
            {"op": "expect", "label": "title bar: logo, Filee and the folder, above the panes", "titleBar": True},
            {"op": "expect", "label": "sidebar rows sized from sidebarFontSize (14)", "sidebarFont": 14},
            {"op": "expect", "label": "each mounted volume has an icon and its own colour", "volumeIcons": True},
            *([{"op": "expect", "label": "the Dropbox folder shows the Dropbox logo (read only)", "customIcon": "~/Dropbox"}]
              if (Path.home() / "Dropbox").is_dir() else []),
            {"op": "expect", "label": "volumeIcons gives a volume named Philips its logo", "volumeLogo": "Philips"},
            {"op": "navigate", "pane": 0, "path": A + "/sub"},
            {"op": "key", "keys": "shift+cmd+f"},
            {"op": "expect", "label": "shift+cmd+f adds the folder to Favourites, under A", "favouritesContain": "A(sub)",
             "statusContains": "Added “sub” to Favourites"},
            {"op": "key", "keys": "alt+cmd+f"},
            {"op": "expect", "label": "alt+cmd+f: the sidebar has the keyboard, on the current folder", "sidebarFocus": A + "/sub"},
            {"op": "key", "keys": "up"},
            {"op": "expect", "label": "up moves in the sidebar", "sidebarFocus": A},
            {"op": "key", "keys": "enter"},
            {"op": "expect", "label": "enter opens the row and gives the keyboard back to the pane", "path": A, "sidebarFocus": ""},
            {"op": "key", "keys": "shift+alt+cmd+f"},
            {"op": "expect", "label": "shift+alt+cmd+f: Volumes, first row", "sidebarFocus": "/"},
            {"op": "key", "keys": "escape"},
            {"op": "expect", "label": "escape goes back to the pane", "sidebarFocus": "", "path": A},
            {"op": "navigate", "pane": 0, "path": A + "/sub"},
            {"op": "key", "keys": "shift+cmd+f"},
            {"op": "expect", "label": "shift+cmd+f again removes it, and says so", "favouritesLack": "A(sub)",
             "statusContains": "Removed “sub” from Favourites"},
            {"op": "key", "keys": "shift+cmd+f"},
            {"op": "expect", "label": "and adds it back", "favouritesContain": "A(sub)", "favouritesLack": "sub sub"},
            {"op": "screenshot", "name": "09-favourites-tree"},
            {"op": "foldFavourite", "path": A},
            {"op": "expect", "label": "the chevron folds A", "favouritesContain": "-A(sub)"},
            {"op": "foldFavourite", "path": A},
            {"op": "expect", "label": "and unfolds it", "favouritesContain": "A(sub)", "favouritesLack": "-A"},
            {"op": "navigate", "pane": 0, "path": A},
            {"op": "command", "id": "toggleTheme"},
            {"op": "wait", "ms": 300},
            {"op": "expect", "label": "theme switch: pinned to 1 theme, colours follow", "theme": first},
            {"op": "screenshot", "name": "05a-theme-1"},
            {"op": "key", "keys": "ctrl+cmd+l"},
            {"op": "wait", "ms": 300},
            {"op": "expect", "label": "ctrl+cmd+l switches to the other theme", "theme": second},
            {"op": "screenshot", "name": "05b-theme-2"},
            {"op": "click", "target": "titleTheme"},
            {"op": "wait", "ms": 300},
            {"op": "expect", "label": "the title bar theme button switches back", "theme": first},
            {"op": "command", "id": "systemTheme"},
            {"op": "wait", "ms": 300},
            {"op": "expect", "label": "Use System Theme follows macOS again", "theme": "system"},
            {"op": "key", "keys": "cmd+t"},
            {"op": "expect", "label": "cmd+t new tab", "tabs": 2},
            {"op": "key", "keys": "cmd+w"},
            {"op": "expect", "label": "cmd+w closes the tab", "tabs": 1},
            {"op": "key", "keys": "shift+cmd+i"},
            {"op": "expect", "label": "shift+cmd+i shows invisible files", "visible": 9},
            {"op": "key", "keys": "shift+cmd+i"},
            {"op": "expect", "label": "and hides them again", "visible": 8},
            {"op": "key", "keys": "cmd+j a"},
            {"op": "expect", "label": "cmd+j a jumps to B", "path": B},
            {"op": "key", "keys": "cmd+j k"},
            {"op": "expect", "label": "cmd+j k jumps to A", "path": A},
            {"op": "palette", "label": "cmd+k palette opens, every shortcut in view", "screenshot": "00-palette", "shortcutsFit": True},
            {"op": "paletteOpen", "text": ""},
            {"op": "paletteKey", "keys": "escape"},
            {"op": "expect", "label": "Esc in the palette's field closes it", "palette": False},
            {"op": "paletteOpen", "text": "zz"},
            {"op": "paletteKey", "keys": "escape", "focus": "list"},
            {"op": "expect", "label": "Esc closes the palette after a click in its list", "palette": False},
            {"op": "paletteOpen", "text": ""},
            {"op": "paletteKey", "keys": "cmd+w"},
            {"op": "expect", "label": "cmd+w closes the palette and leaves the tab", "palette": False, "tabs": 1},
            {"op": "paletteOpen", "text": ""},
            {"op": "paletteResign"},
            {"op": "expect", "label": "a click outside the palette closes it", "palette": False},
            {"op": "command", "id": "palette"},
            {"op": "command", "id": "palette"},
            {"op": "expect", "label": "cmd+k again closes the palette", "palette": False},
            {"op": "navigate", "pane": 0, "path": pics},
            {"op": "expect", "label": "an image folder opens as thumbnails", "view": "thumbnails"},
            {"op": "screenshot", "name": "08-auto-thumbnails"},
        ],
        "filter": [
            {"op": "navigate", "pane": 0, "path": A},
            {"op": "type", "text": "road"},
            {"op": "expect", "label": "typing filters", "visible": 1, "query": "road", "selected": ["260320-roadmap.pptx"]},
            {"op": "screenshot", "name": "05-filter"},
            {"op": "key", "keys": "backspace"},
            {"op": "expect", "label": "backspace edits the filter", "query": "roa"},
            {"op": "expect", "label": "the filter bar shows what was typed, above the list", "filterShows": "roa"},
            {"op": "key", "keys": "escape"},
            {"op": "expect", "label": "escape clears it", "query": "", "visible": 8},
            {"op": "expect", "label": "the filter bar hides when the filter is empty", "filterShows": ""},
            {"op": "type", "text": "img"},
            {"op": "expect", "label": "fuzzy: 3 images", "visible": 3},
            {"op": "key", "keys": "escape"},
        ],
        "ops": [
            {"op": "navigate", "pane": 1, "path": B},
            {"op": "navigate", "pane": 0, "path": A},
            {"op": "select", "pane": 0, "names": ["alpha.txt"]},
            {"op": "key", "keys": "f5"},
            {"op": "waitIdle"},
            {"op": "expect", "label": "F5 copies to the other pane", "exists": [B + "/alpha.txt", A + "/alpha.txt"]},
            {"op": "expect", "label": "the copy shows a progress row above the status bar", "transferRows": 1},
            {"op": "wait", "ms": 2500},
            {"op": "expect", "label": "the finished row goes after 2 s", "transferRows": 0},
            {"op": "transferDemo", "name": "06-transfer-progress"},
            {"op": "select", "pane": 0, "names": ["beta.md"]},
            {"op": "key", "keys": "f6"},
            {"op": "waitIdle"},
            {"op": "expect", "label": "F6 moves to the other pane", "exists": B + "/beta.md", "missing": A + "/beta.md"},
            {"op": "key", "keys": "cmd+z"},
            {"op": "expect", "label": "cmd+z undoes the move", "exists": A + "/beta.md", "missing": B + "/beta.md"},
            {"op": "key", "keys": "shift+cmd+z"},
            {"op": "expect", "label": "shift+cmd+z redoes it", "exists": B + "/beta.md"},
            {"op": "select", "pane": 0, "names": ["alpha.txt"]},
            {"op": "key", "keys": "f5"},
            {"op": "waitIdle"},
            {"op": "expect", "label": "copy onto an existing name keeps both", "exists": B + "/alpha 2.txt"},
            {"op": "select", "pane": 0, "names": ["alpha.txt"]},
            {"op": "key", "keys": "cmd+backspace"},
            {"op": "expect", "label": "cmd+backspace moves to the Trash", "missing": A + "/alpha.txt"},
            {"op": "key", "keys": "cmd+z"},
            {"op": "expect", "label": "cmd+z puts it back", "exists": A + "/alpha.txt"},
            {"op": "touch", "path": A + "/gone.txt"},
            {"op": "navigate", "pane": 0, "path": A},
            {"op": "noTrash", "folder": A, "confirm": False},
            {"op": "select", "pane": 0, "names": ["gone.txt"]},
            {"op": "key", "keys": "cmd+backspace"},
            {"op": "expect", "label": "a volume without a Trash asks first: Cancel keeps the file", "exists": A + "/gone.txt"},
            {"op": "noTrash", "folder": A, "confirm": True},
            {"op": "select", "pane": 0, "names": ["gone.txt"]},
            {"op": "key", "keys": "cmd+backspace"},
            {"op": "expect", "label": "and Delete deletes it for good", "missing": A + "/gone.txt",
             "statusContains": "Deleted 1 item for good"},
            {"op": "noTrash"},
            {"op": "key", "keys": "shift+cmd+n"},
            {"op": "key", "keys": "escape"},
            {"op": "expect", "label": "shift+cmd+n makes a folder", "exists": A + "/untitled folder"},
            {"op": "select", "pane": 0, "names": ["sub"]},
            {"op": "command", "id": "expand"},
            {"op": "select", "pane": 0, "names": ["sub/inner.txt"]},
            {"op": "key", "keys": "shift+cmd+n"},
            {"op": "key", "keys": "escape"},
            {"op": "expect", "label": "new folder goes next to the selected file", "exists": A + "/sub/untitled folder"},
            {"op": "command", "id": "collapseAll"},
            {"op": "select", "pane": 0, "names": ["sub"]},
            {"op": "key", "keys": "ctrl+cmd+c"},
            {"op": "wait", "ms": 1500},
            {"op": "expect", "label": "ctrl+cmd+c zips", "exists": A + "/sub.zip"},
            {"op": "select", "pane": 0, "names": ["sub.zip"]},
            {"op": "command", "id": "extract"},
            {"op": "wait", "ms": 1500},
            {"op": "expect", "label": "extract next to the zip", "exists": A + "/sub 2/deeper/deep.txt"},
            {"op": "select", "pane": 0, "names": ["alpha.txt"]},
            {"op": "command", "id": "duplicate"},
            {"op": "waitIdle"},
            {"op": "expect", "label": "duplicate", "exists": A + "/alpha 2.txt"},
            {"op": "select", "pane": 0, "names": ["alpha.txt"]},
            {"op": "key", "keys": "ctrl+cmd+m"},
            {"op": "wait", "ms": 1200},
            {"op": "expect", "label": "custom action ran from its key", "exists": A + "/alpha.txt.done"},
            {"op": "select", "pane": 0, "names": ["IMG01.png"]},
            {"op": "action", "name": "Back up", "wait": 3000},
            {"op": "expect", "label": "an external program ran with the path argument", "exists": A + "/IMG01.png.bak"},
            {"op": "select", "pane": 0, "names": ["alpha.txt"]},
            {"op": "key", "keys": "ctrl+cmd+d"},
            {"op": "expect", "label": "ctrl+cmd+d adds to the drop stack", "stack": 1},
            {"op": "navigate", "pane": 0, "path": B},
            {"op": "command", "id": "stackCopyHere"},
            {"op": "waitIdle"},
            {"op": "expect", "label": "drop stack copied here", "exists": B + "/alpha 3.txt"},
            {"op": "command", "id": "stackClear"},
            {"op": "expect", "label": "stack cleared", "stack": 0},
            {"op": "navigate", "pane": 0, "path": A},
            {"op": "select", "pane": 0, "names": ["260320-roadmap.pptx"]},
            {"op": "edit", "action": "copy"},
            {"op": "navigate", "pane": 0, "path": B},
            {"op": "edit", "action": "paste"},
            {"op": "waitIdle"},
            {"op": "expect", "label": "Edit > Copy then Paste copies the file", "exists": [B + "/260320-roadmap.pptx", A + "/260320-roadmap.pptx"]},
            {"op": "navigate", "pane": 0, "path": A},
            {"op": "select", "pane": 0, "names": ["alpha 2.txt"]},
            {"op": "edit", "action": "cut"},
            {"op": "navigate", "pane": 0, "path": B},
            {"op": "edit", "action": "paste"},
            {"op": "waitIdle"},
            {"op": "expect", "label": "Edit > Cut then Paste moves the file", "exists": B + "/alpha 4.txt", "missing": A + "/alpha 2.txt"},
            {"op": "navigate", "pane": 0, "path": A + "/sub/deeper"},
            {"op": "crumb", "title": "A", "drop": [A + "/sub/deeper/deep.txt"]},
            {"op": "waitIdle"},
            {"op": "expect", "label": "a file dropped on a folder in the path moves there", "exists": A + "/deep.txt",
             "missing": A + "/sub/deeper/deep.txt"},
            {"op": "crumb", "title": "sub", "drop": [A + "/deep.txt"], "copy": True},
            {"op": "waitIdle"},
            {"op": "expect", "label": "a drop with option copies", "exists": [A + "/deep.txt", A + "/sub/deep.txt"]},
            {"op": "crumb", "title": "deeper", "drop": [A + "/sub"], "refused": True},
            {"op": "expect", "label": "a folder can't be dropped into its own subfolder", "exists": A + "/sub/deeper"},
            {"op": "screenshot", "name": "06-after-ops"},
        ],
        "rename": [
            {"op": "navigate", "pane": 0, "path": A},
            {"op": "select", "pane": 0, "names": ["IMG01.png", "IMG02.png", "IMG03.png"]},
            {"op": "key", "keys": "cmd+r"},
            {"op": "wait", "ms": 400},
            {"op": "rename", "base": "YYMMDD-world-summit-ai"},
            {"op": "wait", "ms": 300},
            {"op": "expect", "label": "sequence rename with the capture date",
             "exists": [f"{A}/{YYMMDD}-world-summit-ai_01.png", f"{A}/{YYMMDD}-world-summit-ai_02.png", f"{A}/{YYMMDD}-world-summit-ai_03.png"],
             "missing": A + "/IMG01.png", "selectedCount": 3},
            {"op": "key", "keys": "cmd+z"},
            {"op": "expect", "label": "1 undo reverts the whole batch", "exists": [A + "/IMG01.png", A + "/IMG03.png"]},
            {"op": "select", "pane": 0, "names": ["beta.md"]},
            {"op": "key", "keys": "cmd+r"},
            {"op": "type", "text": "gamma"},
            {"op": "key", "keys": "enter"},
            {"op": "wait", "ms": 300},
            {"op": "expect", "label": "cmd+r inline rename keeps the extension", "exists": A + "/gamma.md", "missing": A + "/beta.md"},
            # A file arrives while a rename is open (crash of 13th October 2026): the rename stays open.
            {"op": "select", "pane": 0, "names": ["alpha.txt"]},
            {"op": "key", "keys": "cmd+r"},
            {"op": "type", "text": "omega"},
            {"op": "touch", "path": A + "/arrived.txt"},
            {"op": "wait", "ms": 1500},
            {"op": "expect", "label": "a file arriving during a rename keeps the rename open", "renaming": True, "exists": A + "/alpha.txt"},
            {"op": "key", "keys": "enter"},
            {"op": "wait", "ms": 500},
            {"op": "expect", "label": "then the rename and the new file both show", "renaming": False,
             "exists": [A + "/omega.txt", A + "/arrived.txt"], "missing": A + "/alpha.txt", "visible": 9},
        ],
        "budgets": [
            {"op": "navigate", "pane": 0, "path": big},
            {"op": "measure", "pane": 0, "query": "fl9"},
            {"op": "expect", "label": "10,000 files listed", "visible": 10000},
            {"op": "screenshot", "name": "07-big"},
            {"op": "navigate", "pane": 0, "path": A},
            {"op": "key", "keys": "cmd+t"},
            {"op": "key", "keys": "cmd+t"},
            {"op": "key", "keys": "tab"},
            {"op": "key", "keys": "cmd+t"},
            {"op": "wait", "ms": 1500},
            {"op": "measure", "pane": 0},
            {"op": "expect", "label": "memory under 120 MB with 2 panes and 5 tabs", "memoryBelowMB": 120},
        ],
    }


def run_suite(name: str, steps: list, home: Path, out: Path, fx: dict) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    script = out / "steps.json"
    script.write_text(json.dumps(steps, indent=2), encoding="utf-8")
    env = dict(os.environ)
    env.update({"FILEE_HOME": str(home), "FILEE_QA": str(script), "FILEE_QA_OUT": str(out), "FILEE_QA_CONFLICT": "keepBoth"})
    env.pop("PYTHONPATH", None)
    start = time.time()
    try:
        subprocess.run([str(APP)], env=env, timeout=180, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return {"suite": name, "error": "timeout"}
    report_path = out / "report.json"
    if not report_path.exists():
        return {"suite": name, "error": "no report"}
    report = json.loads(report_path.read_text(encoding="utf-8"))
    if len(report["steps"]) < len(steps):
        # The report is written step by step: a short one means Filee stopped (a crash) mid-suite.
        last = steps[len(report["steps"])]
        return {"suite": name, "error": f"Filee stopped at step {len(report['steps']) + 1} of {len(steps)} ({last.get('op')}): "
                                        "see ~/Library/Logs/DiagnosticReports/Filee-*.ips"}
    report["suite"] = name
    report["seconds"] = round(time.time() - start, 1)
    return report


FAKE_OPEN = r"""#!/usr/bin/env python3
# Stands in for /usr/bin/open in the cli suite: answers a filee:// URL the way the app does, in live.json.
import json, os, sys, urllib.parse
url = urllib.parse.urlparse(sys.argv[-1])
q = urllib.parse.parse_qs(url.query)
live = os.path.join(os.environ["FILEE_HOME"], "run", "live.json")
with open(live, encoding="utf-8") as f:
    state = json.load(f)
state["last_action"] = {"name": url.netloc, "rid": q.get("rid", [""])[0], "ok": os.environ.get("FAKE_OK", "1") == "1"}
if url.netloc == "stack-add":
    state["stack"] = state.get("stack", []) + q.get("path", [])
if url.netloc == "reveal":
    state["active_path"] = q["path"][0]
with open(live + ".tmp", "w", encoding="utf-8") as f:
    json.dump(state, f)
os.replace(live + ".tmp", live)
"""


def suite_cli() -> int:
    """The agent interface contract (~/ai/.claude/skills/appee/references/agent-interface.md) on a scratch home.

    Never sends a real filee:// URL: LaunchServices would hand it to Nic's running Filee. Writes run against a
    fake `open` (FILEE_OPEN_TOOL), and the app's own echo runs through the QA harness `url` op.
    """
    import re
    import threading
    fails = 0
    checks = 0

    def ok(cond, label):
        nonlocal fails, checks
        checks += 1
        fails += not cond
        if not cond:
            print(f"   ❌ {label}", file=sys.stderr)

    base = BASE / "cli"
    fx = build_fixtures(base / "fixtures")
    home = base / "home"
    if home.exists():
        shutil.rmtree(home)
    write_home(home, fx)
    a, b = Path(fx["A"]), Path(fx["B"])
    saved = json.loads((home / "state.json").read_text(encoding="utf-8"))
    saved["dropStack"] = [str(a / "alpha.txt")]
    (home / "state.json").write_text(json.dumps(saved), encoding="utf-8")
    fake = base / "fake-open.py"
    fake.write_text(FAKE_OPEN, encoding="utf-8")
    fake.chmod(0o755)
    cli = [sys.executable, str(ROOT / "filee.py")]
    env = dict(os.environ, FILEE_HOME=str(home), FILEE_OPEN_TOOL=str(fake))
    env.pop("PYTHONPATH", None)

    def j(args: list, e: dict = env):
        r = subprocess.run(cli + args + ["--json"], env=e, capture_output=True, text=True)
        try:
            return r.returncode, json.loads(r.stdout)
        except json.JSONDecodeError:
            return r.returncode, None

    rc, d = j(["describe"])
    names = {x["name"] for x in (d or {}).get("commands", [])}
    helptext = subprocess.run(cli + ["--help"], capture_output=True, text=True).stdout
    parsed = set(re.search(r"\{([a-z,\-]+)\}", helptext).group(1).split(","))
    ok(rc == 0 and d and d["app"] == "filee", "describe --json")
    ok(names == parsed, f"describe lists every subcommand ({sorted(parsed - names)} missing)")
    ok(d and all(x["effect"] in ("read", "write", "destructive") for x in d["commands"]), "each command has an effect")
    rc, s = j(["status"])
    ok(rc == 0 and s and s["running"] is False and s["pid"] is None and s["stack"] == 1, "status --json without the app")
    rc, s = j(["stack"])
    ok(rc == 0 and s and s["count"] == 1 and s["paths"] == [str(a / "alpha.txt")], "stack --json reads state.json without the app")
    rc, s = j(["selection"])
    ok(rc == 4 and s and s["ok"] is False, "selection without the app exits 4")
    rc, s = j(["reveal", str(a)])
    ok(rc == 4 and s and s["ok"] is False, "a write without the app exits 4")
    rc, s = j(["reveal", str(a / "missing.txt")])
    ok(rc == 1 and s and s["ok"] is False, "reveal refuses a missing path")
    rc, s = j(["new-tab", str(a / "alpha.txt")])
    ok(rc == 1 and s and s["ok"] is False, "new-tab refuses a file")
    r = subprocess.run(cli + ["no-such-command", "--json"], env=env, capture_output=True, text=True)
    ok(r.returncode == 2, "an unknown command is a usage error")

    # A live state with this process as the app: the CLI's half of a confirmed write.
    live = home / "run" / "live.json"
    live.parent.mkdir(parents=True, exist_ok=True)
    live.write_text(json.dumps({"pid": os.getpid(), "version": "qa", "windows": 1, "transfers": 0, "stack": [],
                                "active_path": str(a), "selection": [str(a / "alpha.txt"), str(a / "beta.md")],
                                "selection_count": 2, "active_pane": 0, "dual_pane": True,
                                "panes": [{"tabs": [str(a)], "active_tab": 0}, {"tabs": [str(b)], "active_tab": 0}]}), encoding="utf-8")
    rc, s = j(["status"])
    ok(rc == 0 and s and s["running"] and s["selection_count"] == 2 and s["active_path"] == str(a), "status --json reads live.json")
    rc, s = j(["selection", "-n", "1"])
    ok(rc == 0 and s and s["count"] == 2 and len(s["paths"]) == 1 and s["more"] is True, "selection -n 1 --json is bounded")
    rc, s = j(["tabs"])
    ok(rc == 0 and s and len(s["panes"]) == 2, "tabs --json")
    rc, s = j(["stack-add", str(a / "beta.md")])
    ok(rc == 0 and s and s["confirmed"] and s["stack"] == 1, "stack-add --json is confirmed and changes status")
    rc, s = j(["reveal", str(b)])
    ok(rc == 0 and s and s["confirmed"] and s["active_path"] == str(b.resolve()), "reveal --json is confirmed")
    rc, s = j(["stack-clear"], dict(env, FAKE_OK="0"))
    ok(rc == 1 and s and s["ok"] is False, "an action the app reports as failed exits 1")
    live.write_text(json.dumps({"pid": 999_999}), encoding="utf-8")
    rc, s = j(["status"])
    ok(rc == 0 and s and s["running"] is False, "a dead pid in live.json means not running")

    # The app's half: the running QA instance publishes live.json and echoes request ids.
    live.unlink()
    steps = [{"op": "navigate", "pane": 0, "path": str(a)},
             {"op": "select", "pane": 0, "names": ["alpha.txt", "beta.md"]},
             {"op": "wait", "ms": 1500},
             {"op": "url", "url": f"filee://reveal?path={b}&rid=qarid1"},
             {"op": "url", "url": f"filee://stack-add?path={a / 'beta.md'}&rid=qarid2"},
             {"op": "wait", "ms": 3000}]
    out = BASE / "reports" / datetime.now().strftime("%y%m%d-%H%M%S") / "cli-app"
    t = threading.Thread(target=run_suite, args=("cli-app", steps, home, out, fx))
    t.start()
    seen_selection = False
    s, state = None, {}
    for _ in range(120):
        time.sleep(0.1)
        rc, s = j(["status"])
        if s and s.get("selection_count") == 2:
            rc2, sel = j(["selection"])
            seen_selection = bool(sel and [Path(p).name for p in sel["paths"]] == ["alpha.txt", "beta.md"])
        try:
            state = json.loads(live.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            state = {}
        if (state.get("last_action") or {}).get("rid") == "qarid2":
            break
    rc, s = j(["status"])  # after the echo: status read in the loop can predate the last write
    ok(seen_selection, "selection --json reads the running app's selection")
    ok(s and s["running"] and s["pid"] and s["windows"] == 1, "status --json reads the running app's live.json")
    ok(os.path.realpath(str(s and s.get("active_path"))) == os.path.realpath(b), "reveal moved the active pane")
    last = state.get("last_action") or {}
    ok(last.get("rid") == "qarid2" and last.get("ok") is True and last.get("name") == "stack-add", "the app echoes the request id")
    ok(s and s["stack"] == 2, "stack-add changed the drop stack")
    ok(str(state.get("bundle_path", "")).endswith("Filee.app"), "live.json names the app copy, for open -a")
    t.join()
    rc, s = j(["status"])
    ok(s and s["running"] is False, "status --json after the app quit")
    print(f"{'✅' if not fails else '❌'} cli: {checks - fails}/{checks} checks passed")
    return fails


def main():
    ap = argparse.ArgumentParser(description="Filee end-to-end QA")
    ap.add_argument("--only", help="run 1 suite")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if not APP.exists():
        print("❌ build/Filee.app missing: run ./build.sh", file=sys.stderr)
        sys.exit(1)
    names = list(suites({"A": "", "B": "", "big": "", "pics": ""}).keys()) + ["cli"]
    if args.list:
        print("\n".join(names))
        return
    chosen = [args.only] if args.only else names
    total_fail = 0
    stamp = datetime.now().strftime("%y%m%d-%H%M%S")
    for name in chosen:
        if name == "cli":
            print("▶ cli (agent interface)…", flush=True)
            total_fail += suite_cli()
            continue
        base = BASE / name
        fx = build_fixtures(base / "fixtures")
        home = base / "home"
        if home.exists():
            shutil.rmtree(home)
        write_home(home, fx)
        steps = suites(fx)[name]
        out = BASE / "reports" / stamp / name
        print(f"▶ {name} ({len(steps)} steps)…", flush=True)
        r = run_suite(name, steps, home, out, fx)
        if "error" in r:
            print(f"❌ {name}: {r['error']}", file=sys.stderr)
            total_fail += 1
            continue
        fails = [s for s in r["steps"] if not s.get("ok")]
        total_fail += len(fails)
        checks = [s for s in r["steps"] if s.get("op") == "expect"]
        print(f"{'✅' if not fails else '❌'} {name}: {len(checks) - len([f for f in fails if f.get('op') == 'expect'])}/{len(checks)} checks passed in {r['seconds']}s (launch {r.get('launch_ms')} ms)")
        for f in fails:
            print(f"   ❌ {f.get('op')} {f.get('label', '')}: {json.dumps({k: v for k, v in f.items() if k not in ('op', 'label', 'ok')})}", file=sys.stderr)
        for s in r["steps"]:
            if s.get("op") == "measure":
                print(f"   📏 {s.get('items')} items: list {s.get('list_ms')} ms (syscalls {s.get('lister_ms')} ms), filter {s.get('filter_ms')} ms, memory {s.get('memory_mb')} MB, launch {s.get('launch_ms')} ms")
        print(f"   📁 {out}")
    print(f"\n{'✅ All suites passed' if total_fail == 0 else f'❌ {total_fail} failure(s)'}")
    sys.exit(1 if total_fail else 0)


if __name__ == "__main__":
    main()
