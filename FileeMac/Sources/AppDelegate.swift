import AppKit
import FileeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    let config = ConfigStore()
    private(set) var state = AppState()
    private(set) var windows: [BrowserWindowController] = []
    private weak var lastKey: BrowserWindowController?
    private var saveWork: DispatchWorkItem?
    private var configWatch: UUID?
    private var midnightTimer: Timer?
    private var pendingOpen: [URL] = []
    private var launched = false
    let launchStart = ProcessInfo.processInfo.systemUptime
    private(set) var launchMilliseconds = 0

    var activeWindow: BrowserWindowController? { lastKey ?? windows.first }

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        var t = Profile.mark("launch: main → willFinish", launchStart)
        config.ensureDefaults(keybindingsText: CommandCatalog.defaultFileText)
        loadConfig(initial: true)
        state = config.loadState()
        Theme.zoomSteps = min(max(state.zoomSteps, Theme.zoomRange.lowerBound), Theme.zoomRange.upperBound)
        applyTheme()
        t = Profile.mark("launch: config", t)
        buildMenus()
        Profile.mark("launch: menus", t)
        // "Reveal in Finder" from other apps, once Filee is the default file viewer (SPEC 11, item 3).
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleReveal(_:reply:)),
                                                     forEventClass: AEEventClass(kAEMiscStandards), andEventID: AEEventID(kAEMakeObjectsVisible))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var t = Profile.mark("launch: willFinish → didFinish", launchStart)
        let w = BrowserWindowController(state: state)
        t = Profile.mark("launch: window", t)
        windows.append(w)
        let qa = ProcessInfo.processInfo.environment["FILEE_QA"] != nil
        if qa {
            // QA runs behind Nic's work: never take the keyboard.
            w.window?.orderBack(nil)
        } else {
            w.showWindow(nil)
            w.window?.makeKeyAndOrderFront(nil)
        }
        w.activePane.focusContent()
        lastKey = w
        launchMilliseconds = Int((ProcessInfo.processInfo.systemUptime - launchStart) * 1000)
        launched = true
        for url in pendingOpen { reveal(url) }
        pendingOpen = []
        configWatch = FolderWatch.shared.subscribe(config.home.path) { [weak self] in self?.loadConfig(initial: false) }
        GlobalHotKey.shared.action = { [weak self] in self?.summon() }
        GlobalHotKey.shared.register()
        scheduleMidnight()
        if !qa { NSApp.activate(ignoringOtherApps: true) }
        QAHarness.startIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow() }
        return true
    }

    func applicationWillResignActive(_ notification: Notification) {
        malloc_zone_pressure_relief(nil, 0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveState()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            pendingOpen += urls
            return
        }
        for u in urls { reveal(u) }
    }

    @objc private func handleReveal(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        var urls: [URL] = []
        let count = list.numberOfItems
        if count == 0, let u = list.fileURLValue { urls.append(u) }
        if count > 0 {
            for i in 1...count { if let u = list.atIndex(i)?.coerce(toDescriptorType: typeFileURL)?.fileURLValue { urls.append(u) } }
        }
        for u in urls { reveal(u) }
        summon()
    }

    /// A folder opens in the active pane; a file opens its folder with the file selected.
    func reveal(_ url: URL) {
        guard let w = activeWindow else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue, !DirectoryLister.packageExtensions.contains(url.pathExtension.lowercased()) {
            w.activePane.navigate(to: url.path)
        } else {
            w.activePane.navigate(to: url.deletingLastPathComponent().path, select: [url.path])
        }
        w.window?.makeKeyAndOrderFront(nil)
    }

    func summon() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = activeWindow {
            w.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow()
        }
    }

    func newWindow() {
        var s = state
        s.frame = nil
        let w = BrowserWindowController(state: s)
        windows.append(w)
        w.showWindow(nil)
        w.activePane.focusContent()
    }

    func windowBecameKey(_ w: BrowserWindowController) { lastKey = w }

    func windowClosed(_ w: BrowserWindowController) {
        windows.removeAll { $0 === w }
        if lastKey === w { lastKey = windows.first }
    }

    // MARK: Config

    private func loadConfig(initial: Bool) {
        let (settings, err) = config.loadSettings()
        let changed = settings != Theme.settings
        Theme.settings = settings
        Keymap.shared.load(config.keybindingsURL)
        let (actions, aerr) = config.loadActions()
        ActionRunner.shared.load(actions)
        guard !initial else { return }
        let problems = [err, aerr].compactMap { $0 } + Keymap.shared.errors
        if let p = problems.first { activeWindow?.showMessage("❌ \(p)", error: true) }
        if changed {
            WindowCorners.refresh()
            for w in windows {
                for p in w.panes { p.styleChanged() }
                w.sidebar.reload()
            }
        }
    }

    func openConfig(_ url: URL) {
        let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.coteditor.CotEditor")
        if let editor {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Writes 1 key of settings.json without touching the rest of the file's text more than needed.
    private func updateSettings(_ change: (inout Settings) -> Void) {
        var s = Theme.settings
        change(&s)
        Theme.settings = s
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(s) else { return }
        let text = (try? String(contentsOf: config.settingsURL, encoding: .utf8)) ?? ""
        let comments = text.split(separator: "\n", omittingEmptySubsequences: false).prefix { $0.hasPrefix("//") }.joined(separator: "\n")
        config.write((comments.isEmpty ? "" : comments + "\n\n") + String(decoding: data, as: UTF8.self) + "\n", to: config.settingsURL)
    }

    func saveColumns(_ cols: [String]) {
        updateSettings { $0.columns = cols }
        for w in windows { for p in w.panes { p.styleChanged() } }
    }

    func addFavourites(_ paths: [String]) {
        updateSettings { s in
            for p in paths where !s.favourites.contains(where: { $0.path.expandingHome == p }) {
                s.favourites.append(.init((p as NSString).lastPathComponent, p.abbreviatingHome))
            }
        }
        for w in windows { w.sidebar.reload() }
    }

    /// Remembers a favourite folded in the sidebar tree.
    func setFavouriteFolded(_ path: String, _ folded: Bool) {
        state.collapsedFavourites.removeAll { $0 == path }
        if folded { state.collapsedFavourites.append(path) }
        scheduleSave()
    }

    /// Unfolds every favourite above `path`. True when one was folded.
    func unfoldFavourites(above path: String) -> Bool {
        let before = state.collapsedFavourites.count
        state.collapsedFavourites.removeAll { FavouriteTree.contains($0, path) }
        guard state.collapsedFavourites.count != before else { return false }
        scheduleSave()
        return true
    }

    func removeFavourite(_ path: String) {
        updateSettings { $0.favourites.removeAll { $0.path.expandingHome == path } }
        for w in windows { w.sidebar.reload() }
    }

    // MARK: State

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveState() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func saveState() {
        if let w = activeWindow ?? windows.first {
            state.frame = w.window.map { NSStringFromRect($0.frame) }
            state.panes = w.paneStates
            state.activePane = w.activePaneIndex
            state.dualPane = w.dualPane
            state.sidebarVisible = w.sidebarVisible
            state.sidebarWidth = Double(w.sidebarWidth)
        }
        state.zoomSteps = Theme.zoomSteps
        config.saveState(state)
    }

    func addRecent(_ path: String) {
        let p = path.abbreviatingHome
        state.recent.removeAll { $0 == p }
        state.recent.insert(p, at: 0)
        if state.recent.count > 30 { state.recent.removeLast(state.recent.count - 30) }
        for w in windows { w.sidebar.reload() }
        scheduleSave()
    }

    func addToStack(_ paths: [String]) {
        for p in paths where !state.dropStack.contains(p) { state.dropStack.append(p) }
        for w in windows { w.sidebar.reload() }
        scheduleSave()
    }

    func removeFromStack(_ paths: [String]) {
        state.dropStack.removeAll { paths.contains($0) }
        for w in windows { w.sidebar.reload() }
        scheduleSave()
    }

    func clearStack() {
        state.dropStack = []
        for w in windows { w.sidebar.reload() }
        scheduleSave()
    }

    // Per-folder view memory

    func folderView(for path: String) -> FolderView? { state.folders[path.abbreviatingHome] }

    /// The saved view of a folder, else the default.
    func view(for path: String) -> ViewMode {
        folderView(for: path)?.view ?? Theme.settings.defaultView
    }

    func rememberView(for path: String, _ mode: ViewMode) {
        var f = state.folders[path.abbreviatingHome] ?? FolderView()
        f.view = mode
        state.folders[path.abbreviatingHome] = f
        scheduleSave()
    }

    func rememberSort(for path: String, key: SortKey, ascending: Bool) {
        var f = state.folders[path.abbreviatingHome] ?? FolderView()
        f.sort = key
        f.ascending = ascending
        state.folders[path.abbreviatingHome] = f
        scheduleSave()
    }

    func rememberThumbnailSize(for path: String, _ size: Double) {
        var f = state.folders[path.abbreviatingHome] ?? FolderView()
        f.thumbnailSize = size
        state.folders[path.abbreviatingHome] = f
        scheduleSave()
    }

    // MARK: Zoom, midnight

    func zoom(by step: Int) {
        if let thumbs = activeWindow?.activePane.fileView as? ThumbnailsView {
            thumbs.resize(by: step)
            return
        }
        let next = step == 0 ? 0 : min(max(Theme.zoomSteps + step, Theme.zoomRange.lowerBound), Theme.zoomRange.upperBound)
        guard next != Theme.zoomSteps else { return }
        Theme.zoomSteps = next
        for w in windows {
            for p in w.panes { p.styleChanged() }
            w.showMessage("Zoom \(Int((Theme.zoom * 100).rounded()))%")
        }
        scheduleSave()
    }

    // MARK: Theme

    /// state.theme: "system" follows macOS, "light" and "dark" pin the app.
    func applyTheme() {
        switch state.theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// ⌃⌘L and the status bar button: light to dark and back.
    func toggleTheme() {
        setTheme(isDark ? "light" : "dark")
    }

    func setTheme(_ theme: String) {
        state.theme = theme
        applyTheme()
        let text = theme == "system" ? "Theme follows macOS" : (theme == "dark" ? "Dark theme" : "Light theme")
        for w in windows { w.showMessage(text) }
        scheduleSave()
    }

    /// "New today" markers reset at local midnight (decision 50).
    private func scheduleMidnight() {
        midnightTimer?.invalidate()
        let next = Date(timeIntervalSince1970: startOfDay() + 86400 + 1)
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            for w in self?.windows ?? [] { for p in w.panes { p.reload() } }
            self?.scheduleMidnight()
        }
        RunLoop.main.add(t, forMode: .common)
        midnightTimer = t
    }

    // MARK: Memory

    private var reliefWork: DispatchWorkItem?

    /// After a big folder is left, malloc keeps its freed pages: hand them back to macOS (2 s after the last load).
    func scheduleMemoryRelief() {
        reliefWork?.cancel()
        let work = DispatchWorkItem { malloc_zone_pressure_relief(nil, 0) }
        reliefWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            for i in items { m.addItem(i) }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
        }
        func cmd(_ title: String, _ id: String, args: String? = nil) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = [id] + (args.map { [$0] } ?? [])
            // The key shows in the menu, but the key map runs it (menus see keys after the key map).
            if let b = Keymap.shared.binding(for: id, args: args) { Self.showKey(b, on: it) }
            return it
        }
        let sep = { NSMenuItem.separator() }

        menu("Filee", [
            NSMenuItem(title: "About Filee", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            sep(),
            cmd("Settings…", "openSettings"),
            cmd("Keyboard Shortcuts…", "openKeybindings"),
            cmd("Custom Actions…", "openActions"),
            sep(),
            // ⌘H goes to the home folder (key map).
            NSMenuItem(title: "Hide Filee", action: #selector(NSApplication.hide(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Quit Filee", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        menu("File", [
            cmd("New Window", "newWindow"), cmd("New Tab", "newTab"), cmd("New Folder", "newFolder"),
            cmd("New Folder with Selection", "newFolderWithSelection"), cmd("New Text File", "newFile"), sep(),
            cmd("Open", "open"), cmd("Open With…", "openWith"), cmd("Quick Look", "quickLook"), cmd("Get Info", "info"), sep(),
            cmd("Rename…", "rename"), cmd("Batch Rename…", "batchRename"), cmd("Duplicate", "duplicate"), cmd("Make Symbolic Link", "makeSymlink"),
            cmd("Compress to Zip", "compress"), cmd("Extract Zip Here", "extract"), sep(),
            cmd("Move to Trash", "trash"), cmd("Empty Trash…", "emptyTrash"), cmd("Eject", "eject"), sep(),
            cmd("Close Tab", "closeTab"),
        ])
        // Edit: Copy and Paste keep these exact titles, so the global App Shortcuts (⌘D, ⌘F) apply.
        let undo = NSMenuItem(title: "Undo", action: #selector(BrowserWindowController.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(BrowserWindowController.redo(_:)), keyEquivalent: "Z")
        menu("Edit", [
            undo, redo, sep(),
            NSMenuItem(title: "Cut", action: #selector(BrowserWindowController.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(BrowserWindowController.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(BrowserWindowController.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"),
            sep(),
            cmd("Copy Path", "copyPath"), cmd("Copy Path with ~", "copyTildePath"), cmd("Copy Name", "copyName"),
            cmd("Copy as Markdown Link", "copyMarkdownLink"), sep(),
            cmd("Copy to Other Pane", "copyToOther"), cmd("Move to Other Pane", "moveToOther"), sep(),
            cmd("Add to Drop Stack", "stackAdd"), cmd("Copy Drop Stack Here", "stackCopyHere"),
            cmd("Move Drop Stack Here", "stackMoveHere"), cmd("Clear Drop Stack", "stackClear"),
        ])
        menu("View", [
            cmd("Single Pane", "singlePane"), cmd("Dual Pane", "dualPane"), cmd("Toggle Single or Dual Pane", "toggleDualPane"), sep(),
            cmd("as Thumbnails", "viewThumbnails"), cmd("as Columns", "viewColumns"), cmd("as List", "viewList"), sep(),
            cmd("Show or Hide Sidebar", "toggleSidebar"), cmd("Show or Hide Invisible Files", "toggleHidden"),
            cmd("Switch Light or Dark Theme", "toggleTheme"), cmd("Use System Theme", "systemTheme"),
            cmd("Calculate Folder Sizes", "folderSizes"), cmd("Filter This Folder", "focusFilter"), cmd("Reload", "reload"), sep(),
            cmd("Expand All", "expandAll"), cmd("Collapse All", "collapseAll"), sep(),
            cmd("Show All Files", "typeFilter", args: "all"), cmd("Show Only PDF Files", "typeFilter", args: "pdf"),
            cmd("Show Only PowerPoint Files", "typeFilter", args: "powerpoint"), cmd("Show Only Word Files", "typeFilter", args: "word"),
            cmd("Show Only Excel Files", "typeFilter", args: "excel"), cmd("Show Only Markdown Files", "typeFilter", args: "markdown"),
            cmd("Show Only Video Files", "typeFilter", args: "video"), cmd("Show Only Images", "typeFilter", args: "images"), sep(),
            cmd("Zoom In", "zoomIn"), cmd("Zoom Out", "zoomOut"), cmd("Reset Zoom", "zoomReset"), sep(),
            cmd("Next Tab", "nextTab"), cmd("Previous Tab", "previousTab"),
        ])
        menu("Go", [
            cmd("Command Palette…", "palette"), cmd("Go to Folder…", "editPath"), sep(),
            cmd("Back", "back"), cmd("Forward", "forward"), cmd("Enclosing Folder", "up"), sep(),
            cmd("Add or Remove Folder in Favourites", "toggleFavourite"), cmd("Go to Favourites in the Sidebar", "focusFavourites"),
            cmd("Go to Volumes in the Sidebar", "focusVolumes"), sep(),
            cmd("Home", "go", args: "~"), cmd("Downloads", "go", args: "~/Downloads"),
            cmd("Applications", "go", args: "/Applications"), sep(),
            cmd("Switch Active Pane", "switchPane"), cmd("Show This Folder in the Other Pane", "syncPanes"),
            cmd("Show Enclosing Folder in the Other Pane", "parentInOtherPane"), cmd("Swap Panes", "swapPanes"), sep(),
            cmd("Send to Dialog", "sendToDialog"), sep(),
            cmd("Open Ghostty Here", "terminalHere"), cmd("Reveal in Finder", "revealInFinder"),
        ])
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        let wTop = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        wTop.submenu = windowMenu
        main.addItem(wTop)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    /// Shows a binding's key on a menu item (1-chord bindings only).
    static func showKey(_ b: KeyBinding, on it: NSMenuItem) {
        guard b.chords.count == 1, let key = keyEquivalent(b.chords[0].key) else { return }
        let c = b.chords[0]
        it.keyEquivalent = key
        var mods: NSEvent.ModifierFlags = []
        if c.cmd { mods.insert(.command) }
        if c.shift { mods.insert(.shift) }
        if c.alt { mods.insert(.option) }
        if c.ctrl { mods.insert(.control) }
        it.keyEquivalentModifierMask = mods
    }

    private static func keyEquivalent(_ key: String) -> String? {
        switch key {
        case "enter": return "\r"
        case "backspace": return "\u{8}"
        case "up": return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case "down": return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case "tab", "space", "escape": return nil
        case "f1": return String(Character(UnicodeScalar(NSF1FunctionKey)!))
        case "f5": return String(Character(UnicodeScalar(NSF5FunctionKey)!))
        case "f6": return String(Character(UnicodeScalar(NSF6FunctionKey)!))
        default: return key.count == 1 ? key : nil
        }
    }

    /// While text is edited (path field, rename), menu keys must not act on files: ⌘⌫ deletes text there.
    static let commandsWhileEditing: Set<String> = ["palette", "editPath", "openSettings", "openKeybindings", "openActions", "newWindow", "switchPane"]

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(menuCommand(_:)), let info = item.representedObject as? [String] else { return true }
        if NSApp.keyWindow?.firstResponder is NSTextView, NSApp.keyWindow?.windowController is BrowserWindowController {
            return Self.commandsWhileEditing.contains(info[0])
        }
        return activeWindow != nil
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String], let w = activeWindow else { return }
        w.perform(info[0], args: info.count > 1 ? info[1] : nil)
    }
}
