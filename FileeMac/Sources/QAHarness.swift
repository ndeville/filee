import AppKit
import FileeCore

/// Scripted checks, used only when FILEE_QA points to a script (JSON steps). Drives the real app: key
/// events go through the same path as the keyboard. Writes report.json and screenshots to FILEE_QA_OUT.
final class QAHarness {
    static private(set) var isRunning = false
    private static var instance: QAHarness?

    private var steps: [[String: Any]]
    private var index = 0
    private var records: [[String: Any]] = []
    private let out: URL
    private var failures = 0

    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FILEE_QA"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let steps = (try? JSONC.object(from: data)) as? [[String: Any]] else { return }
        let out = URL(fileURLWithPath: env["FILEE_QA_OUT"] ?? NSTemporaryDirectory() + "filee-qa")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        isRunning = true
        _ = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Filee QA")
        instance = QAHarness(steps: steps, out: out)
        // A tiling window manager (Nic runs Amethyst) resizes new windows to a screen tile: 1920x2129 cost the
        // budgets 30-40 MB. A window that can't be resized keeps the QA size.
        if let w = AppDelegate.shared.activeWindow?.window {
            w.styleMask.remove(.resizable)
            w.setFrame(NSRect(x: 80, y: 80, width: 1400, height: 900), display: true)
            // README screenshots: an active window has coloured traffic lights.
            if env["FILEE_QA_ACTIVATE"] == "1" {
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
                w.standardWindowButton(.zoomButton)?.isEnabled = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { instance?.next() }
    }

    private init(steps: [[String: Any]], out: URL) {
        self.steps = steps
        self.out = out
    }

    private var wc: BrowserWindowController { AppDelegate.shared.activeWindow! }

    private func pane(_ step: [String: Any]) -> PaneController {
        if let i = step["pane"] as? Int { return wc.panes[i] }
        return wc.activePane
    }

    private func next() {
        guard index < steps.count else {
            finish()
            return
        }
        let step = steps[index]
        index += 1
        Keymap.qaWindow = wc.window
        let delay = (step["after"] as? Double) ?? 0.12
        run(step) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.next() }
        }
    }

    private func record(_ step: [String: Any], ok: Bool = true, _ extra: [String: Any] = [:]) {
        var r: [String: Any] = ["op": step["op"] ?? "", "label": step["label"] ?? "", "ok": ok]
        for (k, v) in extra { r[k] = v }
        if !ok { failures += 1 }
        records.append(r)
        writeReport()
    }

    private func writeReport() {
        let report: [String: Any] = ["steps": records, "failures": failures, "launch_ms": AppDelegate.shared.launchMilliseconds]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("report.json"))
        }
    }

    private func finish() {
        writeReport()
        QAHarness.isRunning = false
        if ProcessInfo.processInfo.environment["FILEE_QA_KEEP_OPEN"] != "1" { NSApp.terminate(nil) }
    }

    private func names(_ items: [FileItem]) -> [String] { items.map(\.name) }

    // MARK: Steps

    private func run(_ step: [String: Any], done: @escaping () -> Void) {
        let op = step["op"] as? String ?? ""
        switch op {
        case "navigate":
            let p = pane(step)
            wc.activate(pane: p.index)
            p.navigate(to: (step["path"] as? String ?? "~").expandingHome)
            p.folderModel.load(sync: true)
            p.focusContent()
            record(step, ["path": p.path])
            done()

        case "command":
            let ok = wc.perform(step["id"] as? String ?? "", args: step["args"] as? String)
            record(step, ok: ok)
            done()

        case "key":
            // "cmd+5", "enter", "tab", "down": through the key map, then the first responder, like a real key.
            let keys = (step["keys"] as? String ?? "").split(separator: " ").map(String.init)
            for k in keys { sendKey(k) }
            record(step, ["keys": keys])
            done()

        case "type":
            let text = step["text"] as? String ?? ""
            for ch in text { sendKey(String(ch)) }
            record(step, ["text": text])
            done()

        case "select":
            let p = pane(step)
            let want = (step["names"] as? [String] ?? []).map { (p.targetFolder as NSString).appendingPathComponent($0) }
            p.fileView.select(paths: want, scroll: true)
            p.focusContent()
            record(step, ok: p.selectedItems.count == want.count, ["selected": names(p.selectedItems)])
            done()

        case "selectAll":
            let p = pane(step)
            p.focusContent()
            wc.perform("selectAll")
            record(step, ["count": p.selectedItems.count])
            done()

        case "wait":
            let ms = step["ms"] as? Double ?? 300
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) {
                self.record(step)
                done()
            }

        case "noTrash":
            // Items in "folder" act as if their volume had no Trash; "confirm" answers the delete question.
            let ops = OperationCenter.shared
            ops.qaNoTrashFolders = (step["folder"] as? String).map { [canonicalFolder($0.expandingHome)] } ?? []
            ops.qaConfirmDelete = step["confirm"] as? Bool
            record(step)
            done()

        case "settings":
            // Writes keys into settings.json, as Nic would in an editor, and waits for Filee to reload it.
            let url = AppDelegate.shared.config.settingsURL
            let set = step["set"] as? [String: Any] ?? [:]
            var json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            json.merge(set) { _, new in new }
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) { try? data.write(to: url) }
            let start = Date()
            func poll() {
                let s = Theme.settings
                let loaded = set.allSatisfy { k, v in
                    switch k {
                    case "windowCorners": return s.windowCorners == v as? String
                    case "cornerRadius": return s.cornerRadius == (v as? NSNumber)?.doubleValue
                    default: return true
                    }
                }
                if loaded || Date().timeIntervalSince(start) > 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.record(step, ok: loaded)
                        done()
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
                }
            }
            poll()

        case "waitIdle":
            // Until no operation runs (copy, move), then 1 more turn for the reload.
            let start = Date()
            func poll() {
                if OperationCenter.shared.running.isEmpty || Date().timeIntervalSince(start) > 30 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        for p in self.wc.panes { p.folderModel.load(sync: true) }
                        self.record(step, ["ms": Int(Date().timeIntervalSince(start) * 1000)])
                        done()
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
                }
            }
            poll()

        case "expect":
            record(step, ok: check(step), observed(step))
            done()

        case "edit":
            // Edit menu actions, as ⌘D / ⌘X / ⌘F reach them through the menu.
            switch step["action"] as? String {
            case "copy": wc.copy(nil)
            case "cut": wc.cut(nil)
            case "paste": wc.paste(nil)
            default: break
            }
            record(step)
            done()

        case "rename":
            let ok = RenameSheet.qaApply(base: step["base"] as? String ?? "")
            record(step, ok: ok)
            done()

        case "palette":
            wc.showPalette()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                var ok = self.wc.palette?.isVisible ?? false
                if let name = step["screenshot"] as? String { self.screenshot(name, of: self.wc.palette?.contentView) }
                if step["shortcutsFit"] as? Bool == true { ok = ok && (self.wc.palette?.shortcutsFit ?? false) }
                self.wc.palette?.close()
                self.record(step, ok: ok)
                done()
            }

        case "transferDemo":
            // A copy halfway through, for the screenshot: real copies on APFS are clones and finish at once.
            // "keep": the row stays, for a capture.
            let key = NSObject()
            wc.transfers.update(key, OperationProgress(title: "Copying", currentName: step["file"] as? String ?? "260320-world-summit-keynote.mov", itemsDone: 1,
                                                       itemsTotal: 3, bytesDone: 1_288_490_188, bytesTotal: 4_294_967_296)) {}
            if step["keep"] as? Bool == true {
                record(step)
                done()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.screenshot(step["name"] as? String ?? "transfer")
                self.wc.transfers.finish(key, text: "✅ Copied 3 items to ~/Videos", error: false)
                self.record(step, ok: self.wc.transfers.rows.count >= 1)
                done()
            }

        case "paletteOpen":
            wc.showPalette()
            wc.palette?.qaType(step["text"] as? String ?? "")
            record(step, ok: wc.palette?.qaPanel.isVisible ?? false)
            done()

        case "paletteClose":
            wc.palette?.close()
            record(step)
            done()

        case "paletteKey":
            // A key pressed in the open palette, with the keyboard in the "field" or the "list" (after a click on a row).
            guard let panel = wc.palette?.qaPanel, panel.isVisible, let ev = keyEvent(step["keys"] as? String ?? "", window: panel) else {
                record(step, ok: false)
                done()
                return
            }
            if step["focus"] as? String == "list" { wc.palette?.qaFocusList() }
            // As NSApplication does: the key window's key equivalents first, then the first responder.
            if !(ev.modifierFlags.contains(.command) && panel.performKeyEquivalent(with: ev)) { panel.sendEvent(ev) }
            record(step)
            done()

        case "paletteResign":
            // Another window or app takes the keyboard (a click outside the palette).
            wc.palette?.qaPanel.resignKey()
            record(step)
            done()

        case "crumb":
            // A click on a folder in the pane's path ("" for the free space after it), or a drop of "drop" paths on it.
            let p = pane(step)
            let title = step["title"] as? String ?? ""
            var ok: Bool
            if let paths = step["drop"] as? [String] {
                ok = p.crumbs.qaDrop(paths.map { $0.expandingHome }, on: title, copy: step["copy"] as? Bool ?? false)
                if step["refused"] as? Bool == true { ok = !ok }
            } else {
                ok = p.crumbs.qaClick(title)
            }
            record(step, ok: ok, ["crumbs": p.crumbs.titles])
            done()

        case "renameFill":
            record(step, ok: RenameSheet.qaFill(base: step["base"] as? String ?? ""))
            done()

        case "renameCancel":
            RenameSheet.qaCancel()
            record(step)
            done()

        case "demoVolumes":
            // [{"name", "free", "local", "internal"}]: the sidebar shows these instead of the mounted volumes.
            let list = step["volumes"] as? [[String: Any]] ?? []
            wc.sidebar.demoVolumes = list.map { v in
                let name = v["name"] as? String ?? ""
                return (path: v["path"] as? String ?? "/Volumes/" + name,
                        info: SidebarController.VolumeInfo(name: name, free: v["free"] as? String ?? "", isLocal: v["local"] as? Bool ?? true,
                                                 isInternal: v["internal"] as? Bool ?? false))
            }
            // The panes show the startup volume's made-up free space, not this Mac's.
            PaneController.demoFreeSpace = list.first { $0["path"] as? String == "/" }?["free"] as? String
            for p in wc.panes { p.reload() }
            record(step)
            done()

        case "renderView":
            // README close-up: the type filter and the item count under it, drawn at "scale" (3) times, so it stays sharp
            // on a 1x screen.
            let p = pane(step)
            let scale = step["scale"] as? Double ?? 3
            let u = p.typeBar.frame.union(p.countLabel.frame)
            let r = NSRect(x: u.minX - 12, y: p.typeBar.frame.minY + 1, width: u.width + 18, height: p.countLabel.frame.maxY + 3 - (p.typeBar.frame.minY + 1))
                .intersection(p.container.bounds)
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(r.width * scale), pixelsHigh: Int(r.height * scale),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = r.size
                p.container.cacheDisplay(in: r, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(step["name"] as? String ?? "view").png"))
            }
            record(step)
            done()

        case "capture":
            // README screenshots (screenshots.py): the window ids and frames go to <name>.capture.json, screenshots.py
            // captures them with screencapture and writes <name>.done. Then the script goes on.
            let name = step["name"] as? String ?? "capture-\(index)"
            var seen = Set<Int>()
            let windows = ([wc.window] + (wc.window?.childWindows ?? []) + [wc.window?.attachedSheet])
                .compactMap { $0 }.filter { $0.isVisible && seen.insert($0.windowNumber).inserted }
            let list = windows.map { w -> [String: Any] in
                ["id": w.windowNumber, "x": w.frame.minX, "y": w.frame.minY, "w": w.frame.width, "h": w.frame.height,
                 "scale": w.backingScaleFactor]
            }
            let doneFile = out.appendingPathComponent("\(name).done")
            try? FileManager.default.removeItem(at: doneFile)
            // Active again, in case another app took the focus: the traffic lights only show their colours then.
            if ProcessInfo.processInfo.environment["FILEE_QA_ACTIVATE"] == "1" && !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
                Thread.sleep(forTimeInterval: 0.3)
            }
            if let data = try? JSONSerialization.data(withJSONObject: ["windows": list]) {
                try? data.write(to: out.appendingPathComponent("\(name).capture.json"))
            }
            let start = Date()
            func poll() {
                if FileManager.default.fileExists(atPath: doneFile.path) || Date().timeIntervalSince(start) > 60 {
                    record(step, ok: FileManager.default.fileExists(atPath: doneFile.path))
                    done()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
                }
            }
            poll()

        case "foldFavourite":
            // The chevron of 1 favourite, as a click on it.
            let ok = wc.sidebar.toggle(path: (step["path"] as? String ?? "").expandingHome)
            record(step, ok: ok, ["favourites": wc.sidebar.favouritesOutline])
            done()

        case "click":
            // "titleCopy" or "pathField": mouse down and up at the view's centre, through NSWindow.sendEvent.
            guard let window = wc.window else { record(step, ok: false); done(); return }
            let p = pane(step)
            let targets: [String: NSView] = ["titleCopy": wc.titleBar.copyButton, "titleTheme": wc.titleBar.themeButton]
            let target = step["target"] as? String ?? ""
            let typeButton = target.hasPrefix("type:") ? FileTypeFilter(rawValue: String(target.dropFirst(5))).flatMap { p.typeBar.button(for: $0) } : nil
            let view = targets[target] ?? typeButton ?? (p.pathField.isHidden ? p.crumbs : p.pathField)
            // The path: the free space after the last folder, where a click opens it for typing.
            let point = view.convert(NSPoint(x: view === p.crumbs ? view.bounds.maxX - 2 : view.bounds.midX, y: view.bounds.midY), to: nil)
            Clipboard.board.clearContents()
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let up = mouse(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
            if let down = mouse(.leftMouseDown) { window.sendEvent(down) }
            record(step, ["clipboard": Clipboard.board.string(forType: .string) ?? ""])
            done()

        case "touch":
            // A file that appears in the folder from outside Filee (Dropbox, a script): FSEvents reloads the pane.
            let path = (step["path"] as? String ?? "").expandingHome
            let ok = FileManager.default.createFile(atPath: path, contents: Data())
            record(step, ok: ok)
            done()

        case "pastePath":
            // What ⌘V does in the open path field, without the real pasteboard.
            let editor = pane(step).pathField.currentEditor() as? NSTextView
            editor?.insertText(step["text"] as? String ?? "", replacementRange: editor?.selectedRange() ?? NSRange())
            record(step, ok: editor != nil)
            done()

        case "screenshot":
            screenshot(step["name"] as? String ?? "shot-\(index)")
            record(step)
            done()

        case "measure":
            let p = pane(step)
            let start = ProcessInfo.processInfo.systemUptime
            p.folderModel.load(sync: true)
            let listMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            // Filter: 1 keystroke over the folder's items.
            let fStart = ProcessInfo.processInfo.systemUptime
            p.folderModel.query = step["query"] as? String ?? "a"
            let filterMs = (ProcessInfo.processInfo.systemUptime - fStart) * 1000
            p.folderModel.query = ""
            let before = Double(AppDelegate.memoryFootprint()) / 1_048_576
            if step["relief"] as? Bool == true { malloc_zone_pressure_relief(nil, 0) }
            let mem = Double(AppDelegate.memoryFootprint()) / 1_048_576
            record(step, ["path": p.path, "items": p.folderModel.items.count, "list_ms": listMs.rounded(), "lister_ms": p.folderModel.loadMilliseconds, "filter_ms": filterMs.rounded(),
                          "memory_mb": mem.rounded(), "memory_before_relief_mb": before.rounded(), "launch_ms": AppDelegate.shared.launchMilliseconds])
            done()

        case "action":
            ActionRunner.shared.run(named: step["name"] as? String ?? "", in: wc)
            DispatchQueue.main.asyncAfter(deadline: .now() + ((step["wait"] as? Double) ?? 1500) / 1000) {
                self.record(step)
                done()
            }

        default:
            record(step, ok: false, ["error": "unknown op"])
            done()
        }
    }

    private func observed(_ step: [String: Any]) -> [String: Any] {
        let p = pane(step)
        var widths: [String: Double] = [:]
        if let list = p.fileView as? ListView {
            for c in list.outline.tableColumns { widths[c.identifier.rawValue] = Double(c.width) }
            widths["_room"] = Double(list.scroll.contentSize.width)
            widths["_longest"] = Double(p.folderModel.visible.map { textWidth($0.name, font: Theme.listFont(bold: $0.isFolder)) }.max() ?? 0)
        }
        return ["widths": widths, "path": p.path, "selected": names(p.selectedItems), "visible": p.folderModel.visible.count,
                "query": p.folderModel.query, "view": p.tab.view.rawValue, "activePane": wc.activePaneIndex,
                "dual": wc.dualPane, "tabs": p.tabs.count, "count": p.countLabel.stringValue, "status": wc.toast.text,
                "favourites": wc.sidebar.favouritesOutline]
    }

    private func check(_ step: [String: Any]) -> Bool {
        let p = pane(step)
        var ok = true
        if let e = step["exists"] as? String { ok = ok && FileManager.default.fileExists(atPath: e.expandingHome) }
        if let e = step["exists"] as? [String] { ok = ok && e.allSatisfy { FileManager.default.fileExists(atPath: $0.expandingHome) } }
        if let e = step["missing"] as? String { ok = ok && !FileManager.default.fileExists(atPath: e.expandingHome) }
        if let e = step["missing"] as? [String] { ok = ok && e.allSatisfy { !FileManager.default.fileExists(atPath: $0.expandingHome) } }
        if let s = step["selected"] as? [String] { ok = ok && names(p.selectedItems) == s }
        if let n = step["selectedCount"] as? Int { ok = ok && p.selectedItems.count == n }
        if step["selectedLast"] as? Bool == true { ok = ok && names(p.selectedItems) == [p.folderModel.visible.last?.name ?? "?"] }
        if let v = step["visible"] as? Int { ok = ok && p.folderModel.visible.count == v }
        if let s = step["sidebar"] as? Bool { ok = ok && wc.sidebarVisible == s && wc.sidebar.scroll.isHidden == !s }
        if let z = step["zoom"] as? Int {
            p.container.layoutSubtreeIfNeeded()
            ok = ok && Theme.zoomSteps == z && p.tabStrip.frame.height == Theme.tabHeight
                && p.tabStrip.titleFontSize == Theme.listSize && p.typeBar.buttonHeight == Theme.tabHeight - 4
                && p.crumbs.fontSize == Theme.listSize
        }
        if let c = step["corners"] as? String, let w = wc.window {
            // Square: the window answers with the 3 px mask. Rounded: with none, and AppKit draws its own shape.
            let mask = w.perform(WindowCorners.maskSelector)?.takeUnretainedValue() as? NSImage
            ok = ok && Theme.settings.windowCorners == c && (c == "square" ? mask?.size == NSSize(width: 3, height: 3) : mask == nil)
        }
        if let r = step["radius"] as? Double { ok = ok && Theme.radius() == CGFloat(r) && Theme.radius(12) == CGFloat(r * 3) }
        if let s = step["sidebarSelected"] as? String { ok = ok && wc.sidebar.selectedRow?.path == canonicalFolder(s.expandingHome) }
        if let t = step["types"] as? String { ok = ok && p.folderModel.types.rawValue == t && p.typeBar.selected.rawValue == t }
        if let r = step["renaming"] as? Bool { ok = ok && ((p.fileView as? ListView)?.isRenaming ?? false) == r }
        if let e = step["pathEditing"] as? Bool { ok = ok && p.pathField.isEditable == e && p.crumbs.isHidden == e }
        if let v = step["palette"] as? Bool { ok = ok && (wc.palette?.isVisible ?? false) == v }
        if let c = step["crumbs"] as? [String] { ok = ok && p.crumbs.titles == c }
        if let c = step["crumbsEnd"] as? [String] { ok = ok && Array(p.crumbs.titles.suffix(c.count)) == c }
        if let c = step["clipboard"] as? String { ok = ok && Clipboard.board.string(forType: .string) == c.expandingHome }
        if let n = step["rows"] as? Int { ok = ok && ((p.fileView as? ListView)?.outline.numberOfRows ?? -1) == n }
        if let path = step["path"] as? String { ok = ok && p.path == canonicalFolder(path.expandingHome) }
        if let v = step["view"] as? String { ok = ok && p.tab.view.rawValue == v }
        if let a = step["activePane"] as? Int { ok = ok && wc.activePaneIndex == a }
        if let d = step["dual"] as? Bool { ok = ok && wc.dualPane == d }
        if let t = step["tabs"] as? Int { ok = ok && p.tabs.count == t }
        if let q = step["query"] as? String { ok = ok && p.folderModel.query == q }
        if let c = step["contains"] as? [String: String] {
            for (file, text) in c {
                let s = (try? String(contentsOfFile: file.expandingHome, encoding: .utf8)) ?? ""
                ok = ok && s.contains(text)
            }
        }
        if step["nameFits"] as? Bool == true, let list = p.fileView as? ListView {
            // The name column is at least as wide as the longest visible name (decision 9).
            // Up to the space the other columns leave: either the longest name fits, or the name column
            // takes all the room and the last column got no slack.
            let cols = list.outline.tableColumns
            let name = cols.first { $0.identifier.rawValue == "name" }?.width ?? 0
            let total = cols.reduce(CGFloat(0)) { $0 + $1.width }
            let room = list.scroll.contentSize.width
            let longest = p.folderModel.visible.map { textWidth($0.name, font: Theme.listFont(bold: $0.isFolder)) }.max() ?? 0
            let fits = name >= longest + 20
            let tight = abs(total - room) <= 2 && (cols.last?.width ?? 0) < 260
            ok = ok && (fits || tight)
        }
        if let s = step["statusContains"] as? String { ok = ok && wc.toast.text.contains(s) }
        if let s = step["countContains"] as? [String] { ok = ok && s.allSatisfy { p.countLabel.stringValue.contains($0) } }
        if let s = step["stack"] as? Int { ok = ok && AppDelegate.shared.state.dropStack.count == s }
        if let n = step["transferRows"] as? Int { ok = ok && wc.transfers.rows.count == n && (n == 0 || wc.transfers.frame.height > 50) }
        if step["ejectButtons"] as? Bool == true {
            // Every volume under /Volumes has an eject button, the startup disk has none.
            let outline = wc.sidebar.outline
            var volumes = 0
            for r in 0..<outline.numberOfRows {
                guard let row = outline.item(atRow: r) as? SidebarController.Row, row.kind == .volume else { continue }
                volumes += 1
                let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: true)
                // The button must sit inside the visible sidebar, not past its right edge.
                outline.layoutSubtreeIfNeeded()
                let has = cell?.subviews.contains { b in
                    guard b.accessibilityIdentifier() == "eject:" + row.path else { return false }
                    let r = b.convert(b.bounds, to: outline)
                    return r.minX > 0 && r.maxX <= outline.visibleRect.maxX + 1 && r.width > 10
                } ?? false
                ok = ok && has == row.path.hasPrefix("/Volumes/")
            }
            ok = ok && volumes > 0
        }
        if let f = step["customIcon"] as? String {
            // A folder with its own Finder icon (the Dropbox folder) has it in the sidebar. Reads 1 extended attribute.
            ok = ok && Icons.customFolderIcon(f.expandingHome) != nil
        }
        if let f = step["volumeLogo"] as? String {
            // volumeIcons gives a volume (Philips) its logo; another volume keeps its symbol.
            let style = Icons.volumeStyle(path: "/Volumes/" + f, name: f, isLocal: true, isInternal: false, color: Theme.muted)
            let plain = Icons.volumeStyle(path: "/Volumes/QA", name: "QA", isLocal: true, isInternal: false, color: Theme.muted)
            ok = ok && style.logo != nil && plain.logo == nil
            if let row = wc.sidebar.volumeRows.first(where: { $0.name == f }) { ok = ok && row.volumeStyle?.logo != nil }
        }
        if let f = step["sidebarFocus"] as? String {
            // "": the keyboard is back in a pane. A path: the sidebar has the keyboard with that row selected.
            let inSidebar = wc.window?.firstResponder is SidebarOutline
            ok = ok && (f.isEmpty ? !inSidebar : inSidebar && wc.sidebar.selectedRow?.path == canonicalFolder(f.expandingHome))
        }
        if let f = step["favouritesContain"] as? String { ok = ok && wc.sidebar.favouritesOutline.contains(f) }
        if let f = step["favouritesLack"] as? String { ok = ok && !wc.sidebar.favouritesOutline.contains(f) }
        if step["titleBar"] as? Bool == true {
            // Logo, name and folder at the top; the panes and the sidebar start below it.
            let t = wc.titleBar
            ok = ok && !t.isHidden && t.frame.minY == 0 && t.frame.height >= 44 && t.logo.image != nil && t.name.stringValue == "Filee"
                && t.path.stringValue == wc.activePane.folderModel.displayPath && t.logo.frame.minX > 60
            ok = ok && wc.panes.allSatisfy { $0.container.isHidden || $0.container.frame.minY >= t.frame.maxY }
                && wc.sidebar.scroll.frame.minY >= t.frame.maxY
            ok = ok && wc.window?.titleVisibility == .hidden
        }
        if step["volumeIcons"] as? Bool == true {
            // Every volume has a symbol and a colour; 2 mounted volumes never share a colour.
            let rows = wc.sidebar.volumeRows.filter { $0.path.hasPrefix("/Volumes/") }
            let styles = rows.compactMap(\.volumeStyle)
            ok = ok && styles.count == rows.count && styles.allSatisfy { Icons.symbol($0.symbol) != nil }
            if rows.count <= Icons.volumePalette.count { ok = ok && Set(styles.map { $0.color.description }).count == rows.count }
        }
        if let f = step["sidebarFont"] as? Double {
            // Every row of the sidebar is sized from sidebarFontSize.
            let outline = wc.sidebar.outline
            ok = ok && Theme.settings.sidebarFontSize == f && outline.numberOfRows > 0
            for r in 0..<outline.numberOfRows where outline.item(atRow: r) is SidebarController.Row {
                let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: true) as? SidebarCell
                ok = ok && outline.rect(ofRow: r).height == SidebarMetrics.rowHeight && cell?.name.font?.pointSize == CGFloat(f)
            }
        }
        if let f = step["filterShows"] as? String {
            // The typed filter is on screen, at the top of the list, in full.
            let bar = p.filterBar, list = p.contentHost
            ok = ok && (f.isEmpty ? bar.isHidden : (!bar.isHidden && p.filterLabel.stringValue == f
                && bar.frame.maxY <= list.frame.minY + 0.5 && bar.frame.height >= 30))
        }
        if let t = step["theme"] as? String {
            // The stored theme, the app's appearance and the pane's layer colour all agree.
            let app = AppDelegate.shared!
            ok = ok && app.state.theme == t
            if t != "system" { ok = ok && app.isDark == (t == "dark") }
            var expected: CGColor?
            p.container.effectiveAppearance.performAsCurrentDrawingAppearance { expected = Theme.bg.cgColor }
            ok = ok && p.container.layer?.backgroundColor == expected
            if t != "system", p.isActivePane {
                // The bar over the active pane: white in dark, red in light.
                var bar: NSColor?
                p.container.effectiveAppearance.performAsCurrentDrawingAppearance { bar = p.accentBar.color.usingColorSpace(.sRGB) }
                let white = (bar?.redComponent ?? 0) > 0.99 && (bar?.greenComponent ?? 0) > 0.99 && (bar?.blueComponent ?? 0) > 0.99
                ok = ok && white == (t == "dark")
                // The title bar's theme button shows the other theme.
                let icon = wc.titleBar.themeButton.image?.accessibilityDescription ?? ""
                ok = ok && wc.titleBar.isDark == (t == "dark") && icon.contains(t == "dark" ? "light" : "dark")
            }
        }
        if let m = step["memoryBelowMB"] as? Double { ok = ok && Double(AppDelegate.memoryFootprint()) / 1_048_576 < m }
        return ok
    }

    // MARK: Keys

    private func sendKey(_ spec: String) {
        guard let window = wc.window, let ev = keyEvent(spec, window: window) else { return }
        if Keymap.shared.handle(ev) { return }
        window.sendEvent(ev)
    }

    private func keyEvent(_ spec: String, window: NSWindow) -> NSEvent? {
        guard let chord = KeyChord(spec) ?? (spec.count == 1 ? KeyChord(key: spec.lowercased(), shift: spec != spec.lowercased()) : nil) else { return nil }
        let codes: [String: UInt16] = [
            "enter": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f5": 96, "f6": 97, "home": 115, "end": 119,
        ]
        var flags: NSEvent.ModifierFlags = []
        if chord.cmd { flags.insert(.command) }
        if chord.shift { flags.insert(.shift) }
        if chord.alt { flags.insert(.option) }
        if chord.ctrl { flags.insert(.control) }
        var chars = chord.key
        if let code = codes[chord.key] {
            switch code {
            case 36: chars = "\r"
            case 48: chars = "\t"
            case 49: chars = " "
            case 51: chars = "\u{7f}"
            case 53: chars = "\u{1b}"
            case 123: chars = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
            case 124: chars = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            case 125: chars = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
            case 126: chars = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
            case 96: chars = String(Character(UnicodeScalar(NSF5FunctionKey)!))
            case 97: chars = String(Character(UnicodeScalar(NSF6FunctionKey)!))
            default: break
            }
            if (123...126).contains(code) { flags.insert(.numericPad); flags.insert(.function) }
        }
        let typed = chord.shift && chars.count == 1 ? chars.uppercased() : chars
        let keyCode = codes[chord.key] ?? Self.keyCode(for: chord.key)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, characters: typed,
                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)
    }

    private static func keyCode(for key: String) -> UInt16 {
        let map: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
            "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        ]
        return map[key] ?? 0
    }

    private func screenshot(_ name: String, of target: NSView? = nil) {
        guard let view = target ?? wc.window?.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out.appendingPathComponent("\(name).png"))
        }
    }
}
