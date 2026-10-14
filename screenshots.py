"""README screenshots: drives build/Filee.app on a demo folder and captures its window, in light and dark.

The demo folder (/Users/Shared/Studio) holds made-up projects, so no real file, folder or volume shows. The app
runs read-only with its own config home. Each "capture" step in the script hands its window ids to this script,
which runs screencapture, adds the shadow and writes assets/screenshots/<name>-<theme>.png.

    python3 screenshots.py              # both themes
    python3 screenshots.py --theme dark

Needs Pillow and pngquant (brew install pngquant). The window comes to the front for about 1 minute per theme.
"""

import argparse
import ctypes
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent
APP = ROOT / "build/Filee.app/Contents/MacOS/Filee"
DEMO = Path("/Users/Shared/Studio")
MARKER = ".filee-demo"
OUT = ROOT / "assets/screenshots"
NOW = datetime.now()

LOGOS = {
    "Website": '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#0e9f9a"/>'
                          '<path d="M15 47 L33 17 H49 L31 47 Z" fill="#fff"/></svg>',
    "Annual Report": '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="31" fill="#1d3a8a"/>'
                             '<path d="M8 36 q12 -10 24 0 t24 0 v6 q-12 -10 -24 0 t-24 0 z" fill="#f59e0b"/></svg>',
    "Podcast": '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#7c3aed"/>'
               '<rect x="25" y="12" width="14" height="25" rx="7" fill="#fff"/><path d="M18 30 a14 14 0 0 0 28 0" stroke="#fff" '
               'stroke-width="4" fill="none"/><rect x="30" y="44" width="4" height="9" fill="#fff"/></svg>',
}

PALETTES = [  # sky top, sky bottom, sun, near hills, far hills
    ((255, 183, 120), (255, 120, 120), (255, 241, 200), (92, 52, 84), (190, 104, 120)),
    ((120, 180, 240), (200, 228, 250), (255, 255, 235), (34, 84, 74), (110, 160, 150)),
    ((40, 48, 110), (240, 140, 120), (255, 220, 170), (30, 30, 60), (100, 70, 110)),
    ((250, 214, 160), (250, 170, 110), (255, 250, 220), (150, 80, 50), (210, 140, 90)),
    ((170, 210, 230), (230, 240, 230), (255, 255, 240), (40, 90, 60), (120, 170, 130)),
    ((190, 170, 230), (250, 200, 210), (255, 245, 240), (70, 60, 120), (150, 120, 180)),
    ((10, 20, 50), (40, 70, 120), (240, 240, 255), (10, 15, 30), (40, 55, 90)),
    ((255, 200, 170), (255, 150, 140), (255, 240, 220), (200, 80, 90), (240, 140, 140)),
]


def date_added(path: Path, when: datetime):
    """Set the file's "date added" (ATTR_CMN_ADDEDTIME), so only some files show the "new today" dot."""

    class AttrList(ctypes.Structure):
        _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_uint16), ("commonattr", ctypes.c_uint32),
                    ("volattr", ctypes.c_uint32), ("dirattr", ctypes.c_uint32), ("fileattr", ctypes.c_uint32),
                    ("forkattr", ctypes.c_uint32)]

    class TimeSpec(ctypes.Structure):
        _fields_ = [("tv_sec", ctypes.c_long), ("tv_nsec", ctypes.c_long)]

    libc = ctypes.CDLL("libc.dylib", use_errno=True)
    attrs = AttrList(5, 0, 0x10000000, 0, 0, 0, 0)
    ts = TimeSpec(int(when.timestamp()), 0)
    if libc.setattrlist(str(path).encode(), ctypes.byref(attrs), ctypes.byref(ts), ctypes.sizeof(ts), 1) != 0:
        print(f"❌ date added: {path}", file=sys.stderr)


def age(path: Path, when: datetime, added_today: bool = False):
    os.utime(path, (when.timestamp(), when.timestamp()))
    date_added(path, NOW if added_today else when)


def fake(path: Path, size: int, when: datetime, added_today: bool = False):
    """A file of the given size (sparse, so it costs no disk space)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.truncate(size)
    age(path, when, added_today)


def landscape(w: int, h: int, palette: tuple, seed: int) -> Image.Image:
    """A sunset or a valley: a sky gradient, a sun and 3 layers of hills."""
    rnd = random.Random(seed)
    top, bottom, sun, near, far = palette
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sx, sy, r = rnd.randint(w // 4, 3 * w // 4), rnd.randint(h // 5, h // 2), rnd.randint(h // 12, h // 7)
    ImageDraw.Draw(glow).ellipse([sx - 2 * r, sy - 2 * r, sx + 2 * r, sy + 2 * r], fill=sun + (90,))
    img.paste(glow.filter(ImageFilter.GaussianBlur(r)), (0, 0), glow.filter(ImageFilter.GaussianBlur(r)))
    d.ellipse([sx - r, sy - r, sx + r, sy + r], fill=sun)
    for layer in range(3):
        t = layer / 2
        colour = tuple(int(far[i] + (near[i] - far[i]) * t) for i in range(3))
        base = h * (0.55 + 0.13 * layer)
        points, x = [(0, h)], 0
        y = base + rnd.uniform(-40, 40)
        while x <= w:
            points.append((x, y))
            x += rnd.randint(30, 90)
            y = min(h - 20, max(h * 0.35, y + rnd.uniform(-45, 45)))
        points += [(w, y), (w, h)]
        d.polygon(points, fill=colour)
    return img


def mockup(w: int, h: int, accent: tuple, seed: int) -> Image.Image:
    """A web page design: navigation, hero, cards."""
    rnd = random.Random(seed)
    img = Image.new("RGB", (w, h), (248, 249, 251))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w, 70], fill=(255, 255, 255))
    d.rounded_rectangle([40, 22, 140, 48], 8, fill=accent)
    for i in range(4):
        d.rounded_rectangle([w - 520 + i * 110, 30, w - 450 + i * 110, 42], 6, fill=(200, 204, 212))
    d.rounded_rectangle([40, 110, w - 40, 470], 24, fill=accent)
    d.rounded_rectangle([90, 190, 620, 230], 12, fill=(255, 255, 255))
    d.rounded_rectangle([90, 250, 480, 275], 10, fill=(255, 255, 255, 180))
    d.rounded_rectangle([90, 320, 260, 370], 25, fill=(17, 24, 39))
    cw = (w - 80 - 2 * 30) // 3
    for i in range(3):
        x = 40 + i * (cw + 30)
        d.rounded_rectangle([x, 510, x + cw, h - 40], 20, fill=(255, 255, 255), outline=(226, 228, 233), width=2)
        d.rounded_rectangle([x + 30, 540, x + 90, 600], 14, fill=tuple(min(255, c + rnd.randint(40, 90)) for c in accent))
        for j in range(3):
            d.rounded_rectangle([x + 30, 630 + j * 30, x + cw - 30 - rnd.randint(0, 120), 645 + j * 30], 7, fill=(214, 217, 224))
    return img


def save_jpeg(img: Image.Image, path: Path, taken: datetime):
    """A photo with its capture date in EXIF, for the batch rename's YYMMDD."""
    exif = Image.Exif()
    exif[0x8769] = {0x9003: taken.strftime("%Y:%m:%d %H:%M:%S")}
    img.save(path, "JPEG", quality=88, exif=exif)
    age(path, taken)


def build_demo():
    if DEMO.exists():
        if not (DEMO / MARKER).exists():
            sys.exit(f"❌ {DEMO} exists and isn't the demo folder: move it first")
        shutil.rmtree(DEMO)
    DEMO.mkdir(parents=True)
    (DEMO / MARKER).write_text("Filee README demo folder, made by screenshots.py\n", encoding="utf-8")
    days = lambda n, hour=10, minute=0: (NOW - timedelta(days=n)).replace(hour=hour, minute=minute)
    MB = 1024 * 1024

    site = DEMO / "Website"
    accent = (14, 159, 154)
    for name, size, when in [("01 Brief/Brief v2.pdf", 1.2 * MB, days(21)), ("01 Brief/Kick-off notes.md", 6_200, days(20)),
                             ("01 Brief/Stakeholders.xlsx", 48_000, days(19)), ("03 Copy/Homepage copy.docx", 84_000, days(4)),
                             ("03 Copy/About us.docx", 61_000, days(6)), ("03 Copy/FAQ.md", 9_400, days(2)),
                             ("04 Build/deploy.sh", 2_100, days(1)), ("04 Build/redirects.csv", 14_000, days(1)),
                             ("Brand guide.pdf", 8.4 * MB, days(34)), ("Budget 2027.xlsx", 86_000, days(1, 17, 12)),
                             ("Contract.pdf", 640_000, days(40)), ("Hero loop.mp4", 48 * MB, days(3)),
                             ("Sitemap.md", 4_100, days(3)), ("Timeline.csv", 2_300, days(5)), ("README.md", 3_000, days(12))]:
        fake(site / name, int(size), when)
    fake(site / "Launch plan.pptx", int(5.1 * MB), NOW.replace(hour=9, minute=42), added_today=True)
    design = site / "02 Design"
    design.mkdir(parents=True)
    for i, name in enumerate(["Homepage.png", "Pricing.png", "Mobile nav.png", "Style tiles.png"]):
        mockup(1440, 900, accent if i % 2 == 0 else (37, 99, 235), i).save(design / name)
        age(design / name, days(i + 1, 15, 20), added_today=(i == 0))
    landscape(1600, 1000, PALETTES[1], 7).save(site / "Moodboard.png")
    age(site / "Moodboard.png", days(9))
    for sub in ["01 Brief", "02 Design", "03 Copy", "04 Build"]:
        age(site / sub, days(1))

    report = DEMO / "Annual Report"
    for name, size, when in [("Annual report 2026.pdf", 12.6 * MB, days(2)), ("Annual report 2025.pdf", 11.1 * MB, days(380)),
                             ("Print proof.pdf", 24.3 * MB, days(1)), ("Auditor letter.pdf", 310_000, days(15)),
                             ("Chair letter.docx", 72_000, days(8)), ("Financials 2026.xlsx", 420_000, days(3)),
                             ("KPI dashboard.xlsx", 190_000, days(1)), ("Board deck.pptx", 18.2 * MB, days(6)),
                             ("Translations/Annual report FR.docx", 260_000, days(4)),
                             ("Translations/Annual report DE.docx", 255_000, days(4)), ("Charts/Revenue.png", 0, days(7)),
                             ("Style notes.md", 5_800, days(10)), ("Timeline.md", 2_900, days(11))]:
        if name.endswith(".png"):
            (report / name).parent.mkdir(parents=True, exist_ok=True)
            mockup(1200, 800, (29, 58, 138), 3).save(report / name)
            age(report / name, when)
        else:
            fake(report / name, int(size), when)

    photos = DEMO / "Lisbon Offsite"
    photos.mkdir()
    start = datetime(2026, 9, 17, 9, 0)
    for i in range(12):
        taken = start + timedelta(hours=7 * i, minutes=13 * i)
        save_jpeg(landscape(1500, 1000, PALETTES[i % len(PALETTES)], 100 + i), photos / f"IMG_{4012 + i * 3}.jpg", taken)

    podcast = DEMO / "Podcast"
    for name, size, when in [("Episode 41.mov", 1.3 * 1024 * MB, days(0, 8, 5)), ("Episode 41.wav", 610 * MB, days(0, 8, 2)),
                             ("Episode 40.mov", 1.1 * 1024 * MB, days(7)), ("Episode 40.wav", 540 * MB, days(7)),
                             ("Show notes 41.md", 7_700, days(0, 10, 31)), ("Guests.xlsx", 39_000, days(9)),
                             ("Intro music.m4a", 4.2 * MB, days(60))]:
        fake(podcast / name, int(size), when, added_today=when.date() == NOW.date())
    landscape(1400, 1400, PALETTES[5], 42).save(podcast / "Cover art.png")
    age(podcast / "Cover art.png", days(14))

    archive = DEMO / "Archive"
    rnd = random.Random(5)
    clients = ["Brightline", "Harbour", "Northfield", "Kestrel", "Oakmont", "Riverside"]
    names = set()
    for month in range(1, 13):
        for c in rnd.sample(clients, 3):
            names.add(f"Invoice 2026-{month:02d} {c}.pdf")
        names.add(f"Bank statement 2026-{month:02d}.pdf")
        names.add(f"Team meeting 26{month:02d}{rnd.randint(1, 28):02d}.md")
    for q in range(1, 5):
        names |= {f"Q{q} report.pdf", f"Q{q} forecast.xlsx", f"Q{q} review.pptx"}
    names |= {"Insurance policy.pdf", "Office lease.pdf", "Holiday plan.xlsx", "Logo final.png", "Price list 2026.xlsx",
              "Proposal Kestrel.docx", "Proposal Oakmont.docx", "Onboarding checklist.md", "Travel expenses.xlsx"}
    for i, name in enumerate(sorted(names)):
        fake(archive / name, rnd.randint(20_000, 3_000_000), days(rnd.randint(2, 300), rnd.randint(8, 18), rnd.randint(0, 59)))

    for folder in [site, report, photos, podcast, archive]:
        if folder.name in LOGOS:
            (folder / ".filee-icon.svg").write_text(LOGOS[folder.name], encoding="utf-8")
    # Folders take the date of their newest item, so only the files meant to be new show the "new today" dot.
    for folder in sorted((p for p in DEMO.rglob("*") if p.is_dir()), key=lambda p: -len(p.parts)):
        newest = max((c.stat().st_mtime for c in folder.iterdir() if not c.name.startswith(".")), default=days(30).timestamp())
        when = datetime.fromtimestamp(newest)
        age(folder, when if when.date() < NOW.date() else days(1))
    print(f"✅ demo folder: {DEMO}")


def write_home(home: Path, theme: str):
    home.mkdir(parents=True, exist_ok=True)
    d = str(DEMO)
    settings = {
        "newTabPath": d,
        "favourites": [{"name": "Studio", "path": d}, {"name": "Website", "path": f"{d}/Website"},
                       {"name": "Annual Report", "path": f"{d}/Annual Report"},
                       {"name": "Lisbon Offsite", "path": f"{d}/Lisbon Offsite"}, {"name": "Podcast", "path": f"{d}/Podcast"},
                       {"name": "Applications", "path": "/Applications"}],
        "jumps": {"w": f"{d}/Website", "p": f"{d}/Podcast"},
    }
    actions = [{"name": "Optimise image", "command": ["/usr/bin/sips", "-Z", "1920", "{path}"], "extensions": ["png", "jpg"], "mode": "background"}]
    state = {
        "frame": "{{80, 80}, {1400, 900}}", "dualPane": True, "activePane": 0, "theme": theme,
        "panes": [{"tabs": [{"path": f"{d}/Website"}, {"path": f"{d}/Annual Report"}, {"path": f"{d}/Podcast"}], "activeTab": 0},
                  {"tabs": [{"path": f"{d}/Lisbon Offsite"}, {"path": f"{d}/Archive"}], "activeTab": 0}],
        "recent": [f"{d}/Website", f"{d}/Lisbon Offsite", f"{d}/Archive", f"{d}/Podcast"],
        "dropStack": [f"{d}/Podcast/Cover art.png", f"{d}/Website/Brand guide.pdf"],
    }
    for name, data in [("settings.json", settings), ("actions.json", actions), ("state.json", state)]:
        (home / name).write_text(json.dumps(data, indent=2), encoding="utf-8")


def script() -> list:
    d = str(DEMO)
    site, photos = f"{d}/Website", f"{d}/Lisbon Offsite"
    volumes = [{"name": "Macintosh HD", "path": "/", "free": "412 GB", "internal": True},
               {"name": "Backup", "free": "1.8 TB", "local": False}, {"name": "Photos", "free": "640 GB"},
               {"name": "Music", "free": "88 GB"}, {"name": "Video Projects", "free": "2.1 TB", "local": False}]
    return [
        {"op": "demoVolumes", "volumes": volumes},
        {"op": "navigate", "pane": 1, "path": photos},
        {"op": "navigate", "pane": 0, "path": site},
        {"op": "select", "pane": 0, "names": ["02 Design"]},
        {"op": "key", "keys": "right"},
        {"op": "select", "pane": 0, "names": ["Budget 2027.xlsx"]},
        {"op": "wait", "ms": 3000},
        {"op": "capture", "name": "hero"},

        {"op": "paletteOpen", "text": "copy"},
        {"op": "wait", "ms": 600},
        {"op": "capture", "name": "palette"},
        {"op": "paletteClose"},

        {"op": "navigate", "pane": 0, "path": f"{d}/Archive"},
        {"op": "type", "text": "invoice kes"},
        {"op": "wait", "ms": 800},
        {"op": "capture", "name": "filter"},
        {"op": "key", "keys": "escape"},

        {"op": "navigate", "pane": 0, "path": site},
        {"op": "command", "id": "nextTab"},
        {"op": "click", "pane": 0, "target": "type:pdf"},
        {"op": "wait", "ms": 2800},
        {"op": "capture", "name": "type-filter"},
        {"op": "renderView", "pane": 0, "name": "type-filter-zoom", "scale": 3},
        {"op": "click", "pane": 0, "target": "type:pdf"},
        {"op": "command", "id": "previousTab"},

        {"op": "navigate", "pane": 0, "path": d},
        {"op": "key", "keys": "cmd+1"},
        {"op": "key", "keys": "cmd+4"},
        {"op": "select", "pane": 0, "names": ["Website"]},
        {"op": "key", "keys": "right down right"},
        {"op": "wait", "ms": 2800},
        {"op": "capture", "name": "columns"},
        {"op": "key", "keys": "cmd+5"},
        {"op": "key", "keys": "cmd+2"},

        {"op": "navigate", "pane": 1, "path": photos},
        {"op": "selectAll", "pane": 1},
        {"op": "command", "id": "rename"},
        {"op": "renameFill", "base": "YYMMDD-lisbon-offsite"},
        {"op": "wait", "ms": 1200},
        {"op": "capture", "name": "rename"},
        {"op": "renameCancel"},
        {"op": "wait", "ms": 800},

        {"op": "key", "keys": "tab"},
        {"op": "command", "id": "nextTab"},
        {"op": "command", "id": "nextTab"},
        {"op": "select", "pane": 0, "names": ["Episode 41.mov", "Episode 41.wav"]},
        {"op": "transferDemo", "keep": True, "file": "Episode 41.mov"},
        {"op": "wait", "ms": 800},
        {"op": "capture", "name": "transfer"},
    ]


def grab(window: dict, path: Path):
    subprocess.run(["screencapture", "-x", "-o", "-l", str(window["id"]), str(path)], check=True)


def shadowed(img: Image.Image, blur: int, offset: int, opacity: int, margin: int) -> Image.Image:
    """The image on a transparent canvas with a soft shadow, as macOS draws a window."""
    w, h = img.size
    canvas = Image.new("RGBA", (w + 2 * margin, h + 2 * margin), (0, 0, 0, 0))
    alpha = img.getchannel("A")
    shadow = Image.new("RGBA", img.size, (0, 0, 0, opacity))
    shadow.putalpha(alpha.point(lambda a: a * opacity // 255))
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    layer.paste(shadow, (margin, margin + offset))
    canvas = Image.alpha_composite(canvas, layer.filter(ImageFilter.GaussianBlur(blur)))
    canvas.alpha_composite(img, (margin, margin))
    return canvas


def compose(info: dict, work: Path, name: str) -> Image.Image:
    """The window as it shows. screencapture -l on a child window (the palette, a sheet) captures it with its parent."""
    path = work / f"{name}.png"
    grab(info["windows"][-1], path)
    return Image.open(path).convert("RGBA")


def close_up(src: Path, dest: Path):
    """A view drawn at 3x by the app (renderView): rounded corners and a shadow, as a card."""
    img = Image.open(src).convert("RGBA")
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1], 36, fill=255)
    img.putalpha(mask)
    shadowed(img, 30, 14, 90, 70).save(dest)
    subprocess.run(["pngquant", "--force", "--skip-if-larger", "--quality", "80-98", "--ext", ".png", str(dest)], check=False)


def finish_image(img: Image.Image, dest: Path):
    """The window with its shadow, at most 1800 px wide, compressed."""
    framed = shadowed(img, 28, 16, 110, 60)
    if framed.width > 1800:
        framed = framed.resize((1800, round(framed.height * 1800 / framed.width)), Image.LANCZOS)
    framed.save(dest)
    subprocess.run(["pngquant", "--force", "--skip-if-larger", "--quality", "75-95", "--ext", ".png", str(dest)], check=False)


def readme_icon():
    """The app icon for the README header, masked to the macOS rounded square, as the Dock shows it."""
    size, body = 512, 464
    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "icon.png"
        subprocess.run(["rsvg-convert", "-w", str(body), "-h", str(body), str(ROOT / "assets/AppIcon-small.svg"), "-o", str(raw)], check=True)
        art = Image.open(raw).convert("RGBA")
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], round(body * 0.225), fill=255)
    art.putalpha(mask)
    icon = shadowed(art, 10, 6, 90, (size - body) // 2)
    icon.save(OUT / "icon.png")
    subprocess.run(["pngquant", "--force", "--skip-if-larger", "--quality", "80-98", "--ext", ".png", str(OUT / "icon.png")], check=False)
    print("✅ icon.png")


def run_theme(theme: str, work: Path):
    home, out = work / f"home-{theme}", work / f"out-{theme}"
    write_home(home, theme)
    out.mkdir(parents=True, exist_ok=True)
    steps = work / f"script-{theme}.json"
    steps.write_text(json.dumps(script(), indent=2), encoding="utf-8")
    env = dict(os.environ, FILEE_HOME=str(home), FILEE_QA=str(steps), FILEE_QA_OUT=str(out), FILEE_QA_ACTIVATE="1",
               FILEE_READONLY="1")
    proc = subprocess.Popen([str(APP)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    handled = set()
    deadline = time.time() + 240
    while proc.poll() is None and time.time() < deadline:
        for f in sorted(out.glob("*.capture.json")):
            name = f.name.removesuffix(".capture.json")
            if name in handled:
                continue
            time.sleep(0.3)
            info = json.loads(f.read_text(encoding="utf-8"))
            img = compose(info, work, f"{name}-{theme}")
            finish_image(img, OUT / f"{name}-{theme}.png")
            handled.add(name)
            (out / f"{name}.done").write_text("", encoding="utf-8")
            print(f"📸 {name}-{theme}.png")
        time.sleep(0.1)
    for view in out.glob("*-zoom.png"):
        close_up(view, OUT / f"{view.stem}-{theme}.png")
        handled.add(view.stem)
        print(f"📸 {view.stem}-{theme}.png")
    if proc.poll() is None:
        proc.terminate()
        print(f"❌ {theme}: the app didn't finish", file=sys.stderr)
    report = json.loads((out / "report.json").read_text(encoding="utf-8"))
    for s in report["steps"]:
        if not s["ok"]:
            print(f"❌ {theme}: step failed: {s['op']} {s.get('label', '')}", file=sys.stderr)
    return len(handled)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--theme", choices=["light", "dark"], help="1 theme only")
    parser.add_argument("--keep", action="store_true", help="keep the demo folder and the work folder")
    parser.add_argument("--icon", action="store_true", help="only the README icon")
    args = parser.parse_args()
    if not APP.exists():
        sys.exit("❌ build/Filee.app is missing: run ./build.sh")
    OUT.mkdir(parents=True, exist_ok=True)
    readme_icon()
    if args.icon:
        return
    build_demo()
    total = 0
    with tempfile.TemporaryDirectory(prefix="filee-shots-", delete=not args.keep) as tmp:
        print(f"work folder: {tmp}")
        for theme in [args.theme] if args.theme else ["light", "dark"]:
            total += run_theme(theme, Path(tmp))
    if not args.keep:
        shutil.rmtree(DEMO)
    print(f"✅ {total} screenshots in {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
