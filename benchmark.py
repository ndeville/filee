"""Speed and memory benchmark: Filee, Finder, Path Finder and ForkLift on a folder of 10,000 files.

For each app and each run:

1. Launch: the app isn't running. `open -a <app> <folder A>`, then the time until the first files of folder A show.
2. Open: the app runs. `open -a <app> <folder B>`, then the time until the first files of folder B show.
3. Memory: the app's footprint (`footprint`, as Activity Monitor's Memory column) 4 s later.

"The first files show" means the first screen frame where the app's window shows a file name of that folder. A probe
(Swift, compiled on the first run) captures the screen with ScreenCaptureKit at 30 frames a second and reads the frames
with Vision OCR, so it never slows the app it measures. The time is the midpoint between the last frame without the files
and the first frame with them (about 0.1 s apart). At launch the capture starts with the app's first window, because a
running capture slows a launch; a window that shows its files in the first frame counts from the moment it appears.
Finder is always running, so it has no launch time.

Before each launch, ForkLift's saved windows (its "Windows" preference) are cleared: ForkLift reopens every tab of the
earlier runs, and each run would list more folders than the one before.

Writes assets/benchmark/results.json and the README chart (assets/benchmark/benchmark-light.svg, -dark.svg).

    python3 benchmark.py              # 1 warm-up round and 5 measured rounds, about 5 minutes
    python3 benchmark.py --runs 3
    python3 benchmark.py --svg-only   # redraw the charts from results.json

The apps open, take the focus and quit while it runs. A running Filee quits first and opens again at the end. The
Terminal (or the app that runs this script) needs Screen Recording and Accessibility access. A tool that moves new Finder windows elsewhere
(a Hammerspoon rule, for example) must be off: Finder shows "n/a" without its window.
"""

import argparse
import base64
import json
import plistlib
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "assets/benchmark"
WORK = Path(tempfile.gettempdir()) / "filee-bench"
FILES = 10_000
FILEE_ID = "com.nicolasdeville.filee"

PROBE_SOURCE = r'''
import AppKit
import ScreenCaptureKit
import Vision

// probe run <bundleId> <text> <timeout s> -- <command...>
//   Runs the command and times (ms from just before it) the first screen frame where the app's windows show <text>,
//   read by OCR. The app is never touched: frames come from the window server (ScreenCaptureKit). Prints JSON.
// probe close <bundleId> <window title>   presses the close button of that window (accessibility)
// probe closeall <bundleId>               presses the close button of every window of the app
// probe icon <app path> <out.png> <px>    writes the app's icon

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

struct Win { let id: Int; let pid: pid_t; let rect: CGRect }

/// pid → is the app: LaunchServices answers slowly, and asking it 100s of times a second slows app launches.
nonisolated(unsafe) var cache: [pid_t: Bool] = [:]
let cacheLock = NSLock()

func appWindows(_ bundleId: String) -> [Win] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [Win] = []
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        cacheLock.lock()
        let known = cache[pid]
        cacheLock.unlock()
        let mine = known ?? (NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleId)
        if known == nil { cacheLock.lock(); cache[pid] = mine; cacheLock.unlock() }
        let r = CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
        if mine && r.width > 200 && r.height > 200 { out.append(Win(id: w[kCGWindowNumber as String] as! Int, pid: pid, rect: r)) }
    }
    return out
}

func normalise(_ s: String) -> String {
    s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
}

final class Watcher: NSObject, SCStreamOutput, @unchecked Sendable {
    let bundleId: String, prefix: String
    let display: CGRect
    var t0 = 0.0
    var busy = false
    var lastNegative: Double? = nil
    var found: Double? = nil
    var firstFrameAfterStart: Double? = nil
    var frames = 0, ocrs = 0
    let queue = DispatchQueue(label: "ocr")
    init(bundleId: String, prefix: String, display: CGRect) { self.bundleId = bundleId; self.prefix = normalise(prefix); self.display = display }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, found == nil, t0 > 0, let pb = sb.imageBuffer else { return }
        // Only complete frames carry new content.
        if let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let raw = att[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        let t = now() - t0
        frames += 1
        if busy { return }
        busy = true
        let wins = appWindows(bundleId)
        queue.async {
            defer { self.busy = false }
            var hit = false
            for w in wins {
                let local = w.rect.offsetBy(dx: -self.display.minX, dy: -self.display.minY).intersection(CGRect(origin: .zero, size: self.display.size))
                if local.isEmpty { continue }
                // The top of the window: the first rows of every file list are there.
                let top = CGRect(x: local.minX, y: local.minY, width: local.width, height: min(local.height, 480))
                let roi = CGRect(x: top.minX / self.display.width, y: 1 - top.maxY / self.display.height,
                                 width: top.width / self.display.width, height: top.height / self.display.height)
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .fast
                req.usesLanguageCorrection = false
                req.regionOfInterest = roi
                try? VNImageRequestHandler(cvPixelBuffer: pb).perform([req])
                self.ocrs += 1
                if (req.results ?? []).contains(where: { normalise($0.topCandidates(1).first?.string ?? "").contains(self.prefix) }) { hit = true; break }
            }
            if hit { if self.found == nil { self.found = t } } else { self.lastNegative = t }
        }
    }
}

func startStream(_ watcher: Watcher, display: SCDisplay) async throws -> SCStream {
    let bounds = CGDisplayBounds(display.displayID)
    let scale = NSScreen.screens.first { ($0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }?.backingScaleFactor ?? 1
    let config = SCStreamConfiguration()
    config.width = Int(bounds.width * scale)
    config.height = Int(bounds.height * scale)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.queueDepth = 6
    config.showsCursor = false
    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
    try stream.addStreamOutput(watcher, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
    try await stream.startCapture()
    return stream
}

func displayFor(_ content: SCShareableContent, _ wins: [Win]) -> SCDisplay {
    content.displays.first { d in wins.contains { CGDisplayBounds(d.displayID).intersects($0.rect) } }
        ?? content.displays.first { $0.displayID == CGMainDisplayID() }!
}

func closeWindows(_ bundleId: String, title: String?) {
    func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        for w in (attr(el, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where title == nil || (attr(w, kAXTitleAttribute) as? String) == title {
            if let b = attr(w, kAXCloseButtonAttribute) { AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) }
        }
    }
}

@main
struct Main {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count >= 5 && args[1] == "icon" {
            // probe icon <app path> <out.png> <px>: the app's icon as the Dock shows it, for the chart.
            let px = Int(args[4])!
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: px, height: px)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSWorkspace.shared.icon(forFile: args[2]).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
            exit(0)
        }
        if args.count >= 3 && args[1] == "closeall" { closeWindows(args[2], title: nil); exit(0) }
        if args.count >= 4 && args[1] == "close" { closeWindows(args[2], title: args[3]); exit(0) }
        guard args.count >= 7, args[1] == "run", let sep = args.firstIndex(of: "--") else {
            FileHandle.standardError.write("usage: probe run <bundleId> <text> <timeout> -- <command...>\n".data(using: .utf8)!)
            exit(2)
        }
        let bundleId = args[2], prefix = args[3], timeout = Double(args[4])! * 1000
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let existing = appWindows(bundleId)
        let launching = existing.isEmpty
        var stream: SCStream? = nil
        var watcher: Watcher? = nil
        // The app runs: watch its display from before the command. It launches: the capture starts with its first
        // window, because a running capture slows the launch (the window server works for it).
        if !launching {
            let d = displayFor(content, existing)
            watcher = Watcher(bundleId: bundleId, prefix: prefix, display: CGDisplayBounds(d.displayID))
            stream = try await startStream(watcher!, display: d)
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let beforeIds = Set(existing.map(\.id))
        let t0 = now()
        watcher?.t0 = t0
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[sep + 1])
        proc.arguments = Array(args[(sep + 2)...])
        try proc.run()
        var windowMs: Double? = nil
        while now() - t0 < timeout && watcher?.found == nil {
            if windowMs == nil {
                let fresh = appWindows(bundleId).filter { !beforeIds.contains($0.id) }
                if !fresh.isEmpty {
                    windowMs = now() - t0
                    if launching {
                        let d = displayFor(try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true), fresh)
                        watcher = Watcher(bundleId: bundleId, prefix: prefix, display: CGDisplayBounds(d.displayID))
                        watcher!.t0 = t0
                        stream = try await startStream(watcher!, display: d)
                    }
                }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try? await stream?.stopCapture()
        var contentMs = watcher?.found
        // Midpoint between the last frame without the files and the first with them. A launch whose first frame
        // already shows them: the files came with the window.
        if let f = contentMs {
            if let n = watcher?.lastNegative, n >= (windowMs ?? 0) { contentMs = (n + f) / 2 } else if launching, let w = windowMs { contentMs = w }
        }
        let pid = appWindows(bundleId).first?.pid ?? 0
        func r(_ v: Double?) -> Any { v.map { ($0 * 10).rounded() / 10 } ?? NSNull() }
        let out: [String: Any] = ["content_ms": r(contentMs), "found_ms": r(watcher?.found), "window_ms": r(windowMs),
                                  "last_negative_ms": r(watcher?.lastNegative), "pid": Int(pid), "frames": watcher?.frames ?? 0, "ocrs": watcher?.ocrs ?? 0]
        print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
        exit(0)
    }
}
'''


def app_info(name: str, candidates: list[str]) -> dict | None:
    for c in candidates:
        path = Path(c)
        if path.exists():
            with open(path / "Contents/Info.plist", "rb") as f:
                info = plistlib.load(f)
            return {"name": name, "path": str(path), "bundle": info["CFBundleIdentifier"],
                    "version": info.get("CFBundleShortVersionString", "")}
    return None


def find_apps() -> list[dict]:
    apps = [
        app_info("Filee", ["/Applications/Filee.app"]),
        app_info("Finder", ["/System/Library/CoreServices/Finder.app"]),
        app_info("Path Finder", ["/Applications/Path Finder.app", "/Applications/Setapp/Path Finder.app"]),
        app_info("ForkLift", ["/Applications/ForkLift.app", "/Applications/Setapp/ForkLift.app"]),
    ]
    for a in apps:
        if a:
            a["size_mb"] = round(int(subprocess.run(["du", "-sk", a["path"]], capture_output=True, text=True).stdout.split()[0]) / 1024, 1)
    return [a for a in apps if a]


def build_probe() -> Path:
    probe = WORK / "probe"
    source = WORK / "probe.swift"
    if not (probe.exists() and source.exists() and source.read_text(encoding="utf-8") == PROBE_SOURCE):
        source.write_text(PROBE_SOURCE, encoding="utf-8")
        print("🛠  compiling the probe")
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(source), "-o", str(probe)], check=True, capture_output=True)
    return probe


def build_folders() -> tuple[Path, Path]:
    folders = []
    for letter in "ab":
        folder = WORK / f"bench-{letter}"
        if not folder.exists() or sum(1 for _ in folder.iterdir()) != FILES:
            shutil.rmtree(folder, ignore_errors=True)
            folder.mkdir(parents=True)
            for i in range(FILES):
                (folder / f"{letter}-file-{i:05d}.txt").write_text("", encoding="utf-8")
        folders.append(folder)
    return folders[0], folders[1]


def running(app: dict) -> bool:
    return subprocess.run(["pgrep", "-f", f"{app['path']}/Contents/MacOS/"], capture_output=True).returncode == 0


def quit_app(app: dict):
    subprocess.run(["osascript", "-e", f'tell application id "{app["bundle"]}" to quit'], capture_output=True)
    for _ in range(150):
        if not running(app):
            return
        time.sleep(0.1)
    subprocess.run(["pkill", "-f", f"{app['path']}/Contents/MacOS/"])
    time.sleep(1)


def probe_run(probe: Path, app: dict, prefix: str, command: list[str], timeout: int = 40) -> dict:
    r = subprocess.run([str(probe), "run", app["bundle"], prefix, str(timeout), "--"] + command, capture_output=True, text=True)
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {"pid": 0, "window_ms": None, "content_ms": None}


def footprint_mb(pid: int) -> float | None:
    r = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True)
    m = re.search(r"Footprint: ([\d.]+) (KB|MB|GB)", r.stdout)
    if not m:
        return None
    return round(float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)], 1)


def open_command(app: dict, folder: Path, home: Path | None = None) -> list[str]:
    cmd = ["/usr/bin/open", "-a", app["path"]]
    if home:
        cmd += ["-n", "--env", f"FILEE_HOME={home}"]
    return cmd + [str(folder)]


def measure(app: dict, probe: Path, a: Path, b: Path) -> dict:
    """1 round for 1 app: launch with folder A, open folder B, memory."""
    result = {"launch_ms": None, "open_ms": None, "memory_mb": None}
    if app["name"] == "Finder":
        r = probe_run(probe, app, "b-file-0", ["/usr/bin/open", "-a", app["path"], str(b)])
        result["open_ms"] = r["content_ms"]
        time.sleep(4)
        result["memory_mb"] = footprint_mb(r["pid"]) if r["pid"] else None
        subprocess.run([str(probe), "close", app["bundle"], b.name], capture_output=True)
        time.sleep(1)
        return result
    quit_app(app)
    time.sleep(1)
    home = None
    if app["bundle"] == FILEE_ID:
        # A clean config: Filee starts as it does for a new user.
        home = Path(tempfile.mkdtemp(prefix="filee-bench-home-"))
    if app["bundle"].startswith("com.binarynights.forklift"):
        subprocess.run(["defaults", "delete", app["bundle"], "Windows"], capture_output=True)
    r = probe_run(probe, app, "a-file-0", open_command(app, a, home))
    result["launch_ms"] = r["content_ms"]
    time.sleep(1.5)
    r2 = probe_run(probe, app, "b-file-0", ["/usr/bin/open", "-a", app["path"], str(b)])
    result["open_ms"] = r2["content_ms"]
    time.sleep(4)
    pid = r2["pid"] or r["pid"]
    result["memory_mb"] = footprint_mb(pid) if pid else None
    if app["bundle"] != FILEE_ID:
        subprocess.run([str(probe), "closeall", app["bundle"]], capture_output=True)
        time.sleep(1)
    quit_app(app)
    if home:
        shutil.rmtree(home, ignore_errors=True)
    return result


def run_benchmark(runs: int) -> dict:
    WORK.mkdir(parents=True, exist_ok=True)
    probe = build_probe()
    a, b = build_folders()
    apps = find_apps()
    print("📦 " + ", ".join(f"{x['name']} {x['version']}" for x in apps))
    filee = next((x for x in apps if x["bundle"] == FILEE_ID), None)
    filee_was_running = bool(filee and running(filee))
    rounds: dict[str, list[dict]] = {x["name"]: [] for x in apps}
    try:
        for i in range(runs + 1):
            label = "warm-up" if i == 0 else f"run {i} of {runs}"
            for app in apps:
                r = measure(app, probe, a, b)
                if i > 0:
                    rounds[app["name"]].append(r)
                print(f"⏱  {label:12} {app['name']:12} launch {r['launch_ms']} ms, open {r['open_ms']} ms, memory {r['memory_mb']} MB")
    finally:
        if filee and filee_was_running:
            subprocess.run(["open", "-a", filee["path"]])

    def median(name: str, key: str):
        values = [r[key] for r in rounds[name] if r[key] is not None]
        return round(statistics.median(values), 1) if values else None

    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    return {
        "date": date.today().isoformat(), "chip": chip, "macos": macos, "files": FILES, "runs": runs,
        "apps": [{**x, "launch_ms": median(x["name"], "launch_ms"), "open_ms": median(x["name"], "open_ms"),
                  "memory_mb": median(x["name"], "memory_mb"), "rounds": rounds[x["name"]]} for x in apps],
    }


# Charts

THEMES = {
    "light": {"bg": "#ffffff", "line": "#d0d7de", "stripe": "#f6f8fa", "text": "#1f2328", "muted": "#656d76",
              "bar": "#c4cad1", "accent": "#d63c2c", "accent_text": "#c0392b"},
    "dark": {"bg": "#0d1117", "line": "#30363d", "stripe": "#151b23", "text": "#e6edf3", "muted": "#8d96a0",
             "bar": "#3d444d", "accent": "#f0624f", "accent_text": "#ff7b6b"},
}


def fmt_ms(ms: float) -> str:
    return f"{ms / 1000:.1f} s" if ms >= 1000 else f"{ms:.0f} ms"


def fmt_mb(mb: float) -> str:
    return f"{mb / 1024:.1f} GB" if mb >= 1024 else (f"{mb:.0f} MB" if mb >= 10 else f"{mb:.1f} MB")


def european(iso: str) -> str:
    """2026-10-14 -> 14th October 2026."""
    d = date.fromisoformat(iso)
    suffix = "th" if 11 <= d.day <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(d.day % 10, "th")
    return f"{d.day}{suffix} {d.strftime('%B %Y')}"


def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def svg(results: dict, theme: str) -> str:
    t = THEMES[theme]
    apps = results["apps"]
    rows = [
        ("Launch", "Start the app with a folder of 10,000 files", "launch_ms", fmt_ms),
        ("Open a folder", "Open another 10,000-file folder", "open_ms", fmt_ms),
        ("Memory", "Footprint with the folder open", "memory_mb", fmt_mb),
        ("App size", "On disk", "size_mb", fmt_mb),
    ]
    W, pad, label_w, row_h, head_h, top = 960, 32, 250, 74, 64, 112
    col_w = (W - 2 * pad - label_w) / len(apps)
    H = top + head_h + row_h * len(rows) + 92
    font = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="{font}">',
         f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="14" fill="{t["bg"]}" stroke="{t["line"]}"/>',
         f'<text x="{pad}" y="52" font-size="24" font-weight="700" fill="{t["text"]}">Filee, Finder, Path Finder and ForkLift</text>',
         f'<text x="{pad}" y="80" font-size="14" fill="{t["muted"]}">Folders of {results["files"]:,} files · {esc(results["chip"])} · '
         f'macOS {results["macos"]} · median of {results["runs"]} runs · lower is better</text>']
    y = top
    for i, app in enumerate(apps):
        x = pad + label_w + i * col_w
        colour = t["accent_text"] if app["bundle"] == FILEE_ID else t["text"]
        icon = icon_data(app["name"])
        tx = x
        if icon:
            o.append(f'<image x="{x - 4:.0f}" y="{y + 2}" width="46" height="46" href="{icon}"/>')
            tx = x + 48
        o.append(f'<text x="{tx:.0f}" y="{y + 23}" font-size="17" font-weight="700" fill="{colour}">{esc(app["name"])}</text>')
        o.append(f'<text x="{tx:.0f}" y="{y + 43}" font-size="12.5" fill="{t["muted"]}">{esc(app["version"])}</text>')
    y += head_h
    for r, (title, sub, key, fmt) in enumerate(rows):
        if r % 2 == 0:
            o.append(f'<rect x="{pad - 12}" y="{y}" width="{W - 2 * pad + 24}" height="{row_h}" rx="8" fill="{t["stripe"]}"/>')
        o.append(f'<text x="{pad}" y="{y + 32}" font-size="16" font-weight="600" fill="{t["text"]}">{title}</text>')
        o.append(f'<text x="{pad}" y="{y + 53}" font-size="12.5" fill="{t["muted"]}">{sub}</text>')
        values = [a.get(key) for a in apps]
        known = [v for v in values if v]
        top_v, best = (max(known), min(known)) if known else (1, 0)
        bar_w = col_w - 34
        for i, (app, v) in enumerate(zip(apps, values)):
            x = pad + label_w + i * col_w
            is_filee = app["bundle"] == FILEE_ID
            if v is None:
                text = "always running" if key == "launch_ms" and app["name"] == "Finder" else "n/a"
                o.append(f'<text x="{x:.0f}" y="{y + 36}" font-size="14" font-style="italic" fill="{t["muted"]}">{text}</text>')
                continue
            weight = "700" if v == best else "500"
            colour = t["accent_text"] if is_filee else t["text"]
            label = fmt(v)
            if v == best and len(known) > 1:
                factor = sorted(known)[1] / v
                if factor >= 1.2:
                    word = "less" if key in ("memory_mb", "size_mb") else "faster"
                    shown = f"{factor:.1f}" if factor < 10 else f"{factor:.0f}"
                    label += f'  <tspan font-size="12.5" font-weight="600" fill="{t["muted"]}">{shown}× {word}</tspan>'
            o.append(f'<text x="{x:.0f}" y="{y + 32}" font-size="16" font-weight="{weight}" fill="{colour}">{label}</text>')
            w = max(4, bar_w * v / top_v)
            o.append(f'<rect x="{x:.0f}" y="{y + 44}" width="{bar_w:.0f}" height="8" rx="4" fill="{t["line"]}" opacity="0.45"/>')
            o.append(f'<rect x="{x:.0f}" y="{y + 44}" width="{w:.1f}" height="8" rx="4" fill="{t["accent"] if is_filee else t["bar"]}"/>')
        y += row_h
    o.append(f'<text x="{pad}" y="{y + 40}" font-size="12.5" fill="{t["muted"]}">Time from the open command until the first files show '
             f'on screen, read from screen captures by OCR. Memory as Activity Monitor shows it.</text>')
    o.append(f'<text x="{pad}" y="{y + 60}" font-size="12.5" fill="{t["muted"]}">Measured on {european(results["date"])} with benchmark.py '
             f'(github.com/ndeville/filee). Finder is part of macOS and always running.</text>')
    o.append("</svg>")
    return "\n".join(o) + "\n"


def slug(name: str) -> str:
    return name.lower().replace(" ", "-")


def app_icons(results: dict):
    """Each app's icon (128 px) in assets/benchmark/icons/, from the installed app, for the chart's header."""
    folder = OUT / "icons"
    folder.mkdir(parents=True, exist_ok=True)
    probe = None
    for app in results["apps"]:
        dest = folder / f"{slug(app['name'])}.png"
        if not Path(app["path"]).exists():
            continue
        if app["bundle"] == FILEE_ID and shutil.which("rsvg-convert"):
            filee_icon(dest)
        else:
            probe = probe or build_probe()
            subprocess.run([str(probe), "icon", app["path"], str(dest), "128"], check=True, capture_output=True)
        subprocess.run(["pngquant", "--force", "--skip-if-larger", "--quality", "80-98", "--ext", ".png", str(dest)], capture_output=True)


def filee_icon(dest: Path):
    """Filee's icon without its name: at 128 px macOS draws the version with "Filee" under the folder, too small to read
    in the chart. The rounded square and the margin follow Apple's icon grid (824 of 1024 px)."""
    from PIL import Image, ImageDraw
    body = 104
    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "icon.png"
        subprocess.run(["rsvg-convert", "-w", str(body), "-h", str(body), str(ROOT / "assets/AppIcon-small.svg"), "-o", str(raw)], check=True)
        art = Image.open(raw).convert("RGBA")
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], round(body * 0.225), fill=255)
    art.putalpha(mask)
    icon = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
    icon.alpha_composite(art, ((128 - body) // 2, (128 - body) // 2))
    icon.save(dest)


def icon_data(name: str) -> str | None:
    path = OUT / "icons" / f"{slug(name)}.png"
    return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode() if path.exists() else None


def write_charts(results: dict):
    app_icons(results)
    for theme in THEMES:
        (OUT / f"benchmark-{theme}.svg").write_text(svg(results, theme), encoding="utf-8")
    print(f"✅ charts: {(OUT / 'benchmark-light.svg').relative_to(ROOT)}, benchmark-dark.svg")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", type=int, default=5, help="measured rounds (default 5)")
    parser.add_argument("--svg-only", action="store_true", help="redraw the charts from results.json")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    results_file = OUT / "results.json"
    if args.svg_only:
        write_charts(json.loads(results_file.read_text(encoding="utf-8")))
        return
    results = run_benchmark(args.runs)
    results_file.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print(f"✅ results: {results_file.relative_to(ROOT)}")
    for a in results["apps"]:
        print(f"   {a['name']:12} launch {a['launch_ms']} ms · open {a['open_ms']} ms · memory {a['memory_mb']} MB · size {a['size_mb']} MB")
    write_charts(results)


if __name__ == "__main__":
    main()
