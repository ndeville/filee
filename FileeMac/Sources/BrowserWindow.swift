import AppKit
import FileeCore
import Quartz

/// Lays out the window by hand (Notee's lesson: no auto layout at the top level).
final class RootView: FlippedView {
    var onLayout: (() -> Void)?
    var onAppearance: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }

    // Layer colours are fixed CGColors: they don't follow a theme switch by themselves.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { self.onAppearance?() }
    }
}

/// The status bar: the selection. Each pane shows its free space under its tabs. Messages are in Toast, copy and move progress in TransferPanel.
final class StatusBar: FlippedView {
    let left = label("", size: 11.5, color: Theme.muted)
    let themeButton = iconButton("circle.lefthalf.filled", tip: "Switch light or dark theme (⌃⌘L)", target: nil, action: #selector(BrowserWindowController.toggleThemeClicked(_:)))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        left.lineBreakMode = .byTruncatingTail
        for v in [left, themeButton] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func appearanceChanged() {
        layer?.backgroundColor = Theme.surface.cgColor
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        left.frame = NSRect(x: 10, y: (h - 15) / 2, width: w - 46, height: 15)
        themeButton.frame = NSRect(x: w - 26, y: (h - 16) / 2, width: 16, height: 16)
    }
}

/// A thin strip over the sidebar's right edge: drag it to change the sidebar's width.
final class ResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

/// 1 Filee window: title bar, sidebar, 2 panes, status bar. Every command arrives here (Keymap, menus, palette).
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let root = RootView()
    private(set) var panes: [PaneController] = []
    private(set) var activePaneIndex = 0
    private(set) var dualPane = true
    private(set) var sidebarVisible = true
    private(set) var showHidden = false
    var sidebar: SidebarController!
    let titleBar = TitleBar()
    let statusBar = StatusBar()
    let transfers = TransferPanel()
    let toast = Toast()
    private let sidebarDivider = ColorView(Theme.line)
    private let paneDivider = ColorView(Theme.line)
    private let sidebarHandle = ResizeHandle()
    private(set) var sidebarWidth: CGFloat = 260
    static let sidebarWidths: ClosedRange<CGFloat> = 160...480
    var palette: PaletteController?

    var activePane: PaneController { panes[activePaneIndex] }
    var otherPane: PaneController { panes[activePaneIndex == 0 ? 1 : 0] }

    init(state: AppState) {
        let frame = state.frame.map { NSRectFromString($0) } ?? NSRect(x: 0, y: 0, width: 1500, height: 1000)
        var t0 = Profile.now
        let window = FileeWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 360)
        window.title = "Filee"
        // TitleBar draws the logo, the name and the folder under the transparent title bar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar makes the title bar tall (52 px) and centres the traffic lights in it.
        let toolbar = NSToolbar(identifier: "filee")
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.backgroundColor = Theme.bg
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        if state.frame == nil { window.center() }
        dualPane = state.dualPane
        sidebarVisible = state.sidebarVisible
        sidebarWidth = min(Self.sidebarWidths.upperBound, max(Self.sidebarWidths.lowerBound, CGFloat(state.sidebarWidth)))
        showHidden = Theme.settings.showHidden
        activePaneIndex = min(max(0, state.activePane), 1)

        t0 = Profile.mark("launch: NSWindow", t0)
        window.contentView = root
        root.onLayout = { [weak self] in self?.layoutAll() }
        root.onAppearance = { [weak self] in self?.appearanceChanged() }
        statusBar.themeButton.target = self
        var t = Profile.now
        sidebar = SidebarController(window: self)
        t = Profile.mark("launch: sidebar", t)
        for i in 0..<2 {
            let p = PaneController(window: self, index: i, state: i < state.panes.count ? state.panes[i] : nil)
            panes.append(p)
            t = Profile.mark("launch: pane \(i)", t)
        }
        transfers.onHeightChange = { [weak self] in self?.layoutAll() }
        sidebarHandle.onDrag = { [weak self] x in
            guard let self else { return }
            self.sidebarWidth = min(Self.sidebarWidths.upperBound, max(Self.sidebarWidths.lowerBound, x.rounded()))
            self.layoutAll()
        }
        sidebarHandle.onEnd = { [weak self] in self?.stateChanged() }
        titleBar.themeButton.onClick = { [weak self] in self?.perform("toggleTheme") }
        titleBar.copyButton.onClick = { [weak self] in
            guard let self else { return }
            self.copyFolderPath(of: self.activePane)
        }
        for v in [titleBar, sidebar.scroll, sidebarDivider, panes[0].container, paneDivider, panes[1].container, sidebarHandle,
                  transfers, statusBar, toast] as [NSView] {
            root.addSubview(v)
        }
        layoutAll()
        t = Profile.mark("launch: layout", t)
        for p in panes { p.activeChanged() }
        t = Profile.mark("launch: activeChanged", t)
        updateTitle()
        Profile.mark("launch: title", t)
    }

    required init?(coder: NSCoder) { fatalError() }

    func layoutAll() {
        let b = root.bounds
        let top = titleBarHeight
        let statusH: CGFloat = 24
        let transferH = transfers.height
        let h = b.height - top - statusH - transferH
        titleBar.frame = NSRect(x: 0, y: 0, width: b.width, height: top)
        titleBar.leading = titleBarLeading
        let sideW: CGFloat = sidebarVisible ? sidebarWidth : 0
        sidebar.scroll.isHidden = !sidebarVisible
        sidebarDivider.isHidden = !sidebarVisible
        sidebarHandle.isHidden = !sidebarVisible
        sidebar.scroll.frame = NSRect(x: 0, y: top, width: sideW, height: h)
        sidebarDivider.frame = NSRect(x: sideW, y: top, width: sidebarVisible ? 1 : 0, height: h)
        sidebarHandle.frame = NSRect(x: sideW - 3, y: top, width: 7, height: h)
        let x0 = sideW + (sidebarVisible ? 1 : 0)
        let w = b.width - x0
        if dualPane {
            let half = floor((w - 1) / 2)
            panes[0].container.isHidden = false
            panes[1].container.isHidden = false
            paneDivider.isHidden = false
            panes[0].container.frame = NSRect(x: x0, y: top, width: half, height: h)
            paneDivider.frame = NSRect(x: x0 + half, y: top, width: 1, height: h)
            panes[1].container.frame = NSRect(x: x0 + half + 1, y: top, width: w - half - 1, height: h)
        } else {
            paneDivider.isHidden = true
            for (i, p) in panes.enumerated() {
                p.container.isHidden = i != activePaneIndex
                p.container.frame = NSRect(x: x0, y: top, width: w, height: h)
            }
        }
        transfers.isHidden = transferH == 0
        transfers.frame = NSRect(x: 0, y: top + h, width: b.width, height: transferH)
        statusBar.frame = NSRect(x: 0, y: b.height - statusH, width: b.width, height: statusH)
        toast.anchor = (x: b.midX, bottom: top + h - 24, maxWidth: max(200, b.width * 0.7))
        if !toast.isHidden { toast.place() }
        for p in panes { p.layout() }
    }

    /// The title bar's height: the content runs under it (full-size content view). At least 32 in full screen.
    private var titleBarHeight: CGFloat {
        guard let window else { return 32 }
        return max(32, (window.frame.height - window.contentLayoutRect.height).rounded())
    }

    /// Right of the traffic lights; at the left edge in full screen, where they're hidden.
    private var titleBarLeading: CGFloat {
        guard let window, !window.styleMask.contains(.fullScreen), let zoom = window.standardWindowButton(.zoomButton) else { return 14 }
        return zoom.frame.maxX + 18
    }

    func windowDidEnterFullScreen(_ notification: Notification) { layoutAll() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutAll() }

    // MARK: Active pane

    func activate(pane index: Int) {
        guard index != activePaneIndex else { return }
        activePaneIndex = index
        if !dualPane { layoutAll() }
        for p in panes { p.activeChanged() }
        updateTitle()
        selectionChanged(in: activePane)
        stateChanged()
    }

    func switchPane() {
        guard dualPane else {
            NSSound.beep()
            return
        }
        activate(pane: activePaneIndex == 0 ? 1 : 0)
        activePane.focusContent()
    }

    func paneContentChanged(_ pane: PaneController) {
        guard panes.count == 2 else { return }
        if pane === activePane { updateTitle() }
    }

    func updateTitle() {
        window?.title = activePane.folderModel.displayPath
        titleBar.path.stringValue = activePane.folderModel.displayPath
        titleBar.needsLayout = true
        window?.representedURL = URL(fileURLWithPath: activePane.path)
    }

    func selectionChanged(in pane: PaneController) {
        guard panes.count == 2, pane === activePane else { return }
        let sel = pane.selectedItems
        if sel.isEmpty {
            statusBar.left.stringValue = Format.items(pane.folderModel.unfilteredCount)
        } else {
            let bytes = sel.reduce(Int64(0)) { $0 + max(0, pane.folderModel.size(of: $1)) }
            let folders = sel.filter(\.isFolder).count
            var text = sel.count == 1 ? sel[0].name : "\(sel.count) selected"
            if bytes > 0 { text += " · \(Format.size(bytes))" }
            if folders > 0, sel.count > 1 { text += " · \(folders) folder\(folders == 1 ? "" : "s")" }
            statusBar.left.stringValue = text
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    func showMessage(_ text: String, detail: String? = nil, error: Bool = false) {
        toast.show(text, detail: detail, error: error)
    }

    private func appearanceChanged() {
        titleBar.appearanceChanged()
        statusBar.appearanceChanged()
        transfers.appearanceChanged()
        toast.applyColours()
        for p in panes { p.appearanceChanged() }
    }

    func stateChanged() {
        AppDelegate.shared.scheduleSave()
    }

    var paneStates: [PaneState] { panes.map(\.state) }

    // MARK: Commands

    /// Runs a command by id. Returns false when the command doesn't apply (the key then goes on).
    @discardableResult
    func perform(_ id: String, args: String? = nil) -> Bool {
        let pane = activePane
        let ops = OperationCenter.shared
        switch id {
        case "open": pane.openSelection()
        case "openWith": openWith()
        case "up": pane.goUp()
        case "selectLast":
            pane.fileView.selectLast()
            pane.focusContent()
        case "back": pane.goBack()
        case "forward": pane.goForward()
        case "switchPane": switchPane()
        case "editPath": pane.editPath()
        case "palette":
            // ⌘K again closes it.
            if palette?.isVisible == true { palette?.close() } else { showPalette() }
        case "go":
            guard let a = args else { return false }
            pane.navigate(to: a)
        case "syncPanes": otherPane.navigate(to: pane.path)
        case "parentInOtherPane":
            // The other pane shows the folder 1 level up, with this folder selected. The active pane keeps the keys.
            let current = pane.path
            guard current != "/" else { return beep() }
            if !dualPane { setDual(true) }
            otherPane.navigate(to: (current as NSString).deletingLastPathComponent, select: [current])
        case "toggleFavourite":
            // The folder that holds the selection (a tree list can select inside an expanded folder).
            toggleFavourite(pane.selectedItems.first?.parent ?? pane.path)
        case "focusFavourites": focusSidebar(section: 0)
        case "sendToDialog":
            // Foldee moves the open Open or Save dialog to the selected file, else to this folder. Delivered at once,
            // because Foldee is never the active app.
            let sel = pane.selectedItems
            let path = sel.count == 1 && !sel[0].isFolder ? sel[0].path : pane.path
            DistributedNotificationCenter.default().postNotificationName(.init("com.nicolasdeville.foldee.goto"), object: nil,
                                                                         userInfo: ["path": path, "source": "filee"], deliverImmediately: true)
        case "focusVolumes": focusSidebar(section: 1)
        case "swapPanes":
            let a = pane.path, b = otherPane.path
            pane.navigate(to: b)
            otherPane.navigate(to: a)
        case "singlePane": setDual(false)
        case "toggleDualPane": setDual(!dualPane)
        case "dualPane": setDual(true)
        case "viewThumbnails": pane.changeView(.thumbnails)
        case "viewColumns": pane.changeView(.columns)
        case "viewList": pane.changeView(.list)
        case "toggleTheme": AppDelegate.shared.toggleTheme()
        case "systemTheme": AppDelegate.shared.setTheme("system")
        case "typeFilter":
            guard let f = FileTypeFilter(rawValue: args ?? "") else { return false }
            pane.setTypeFilter(f)
        case "toggleSidebar":
            sidebarVisible.toggle()
            layoutAll()
            stateChanged()
        case "newTab": pane.newTab()
        case "openInNewTab":
            guard let f = pane.selectedItems.first(where: \.isFolder) else { return beep() }
            pane.newTab(path: f.path)
        case "pasteHere": paste(nil)
        case "openInOtherPane":
            guard let f = pane.selectedItems.first(where: \.isFolder) else { return beep() }
            otherPane.navigate(to: f.path)
            if !dualPane { setDual(true) }
        case "closeTab": pane.closeTab()
        case "nextTab": pane.cycleTab(1)
        case "previousTab": pane.cycleTab(-1)
        case "toggleHidden":
            showHidden.toggle()
            for p in panes {
                p.folderModel.showHidden = showHidden
                p.folderModel.resort()
            }
            showMessage(showHidden ? "Showing invisible files" : "Hiding invisible files")
        case "reload":
            for p in panes { p.reload() }
            sidebar.reload()
        case "focusFilter":
            pane.focusContent()
            showMessage("Type to filter this folder · Esc clears")
        case "zoomIn": AppDelegate.shared.zoom(by: 1)
        case "zoomOut": AppDelegate.shared.zoom(by: -1)
        case "zoomReset": AppDelegate.shared.zoom(by: 0)
        case "quickLook": toggleQuickLook()
        case "info": InfoPanel.shared.show(pane.selectedItems.isEmpty ? [FileItem(name: (pane.path as NSString).lastPathComponent, parent: (pane.path as NSString).deletingLastPathComponent, kind: .directory)] : pane.selectedItems)
        case "folderSizes": calculateFolderSizes(pane)
        case "copyToOther", "moveToOther":
            let sel = pane.selectedItems.map(\.path)
            guard !sel.isEmpty else { return beep() }
            let mode: Transfer.Mode = id == "copyToOther" ? .copy : .move
            if dualPane {
                let target = otherPane.targetFolder
                ops.transfer(mode, sel, into: target) { [weak self] results in self?.selectInPanes(results) }
            } else {
                showPalette(mode: .folderTarget(mode, sel))
            }
        case "rename":
            let sel = pane.selectedItems
            guard !sel.isEmpty else { return beep() }
            if sel.count == 1 {
                if !pane.fileView.beginInlineRename() { renamePrompt(sel[0], pane: pane) }
            } else {
                RenameSheet.show(for: sel.map(\.path), in: self)
            }
        case "batchRename":
            let sel = pane.selectedItems
            guard !sel.isEmpty else { return beep() }
            RenameSheet.show(for: sel.map(\.path), in: self)
        case "newFolder":
            // Next to the selected item: in a tree list, that can be inside an expanded folder.
            if let p = ops.newFolder(in: pane.selectedItems.first?.parent ?? pane.targetFolder) { selectAndRename(p, in: pane) }
        case "newFolderWithSelection":
            let sel = pane.selectedItems
            guard let first = sel.first else { return beep() }
            if let p = ops.newFolder(in: first.parent, moving: sel.map(\.path)) { selectAndRename(p, in: pane) }
        case "newFile":
            if let p = ops.newFile(in: pane.targetFolder) { selectAndRename(p, in: pane) }
        case "duplicate":
            let sel = pane.selectedItems.map(\.path)
            guard !sel.isEmpty else { return beep() }
            ops.transfer(.copy, sel, into: (sel[0] as NSString).deletingLastPathComponent) { [weak self] r in self?.selectInPanes(r) }
        case "trash":
            let sel = pane.selectedItems
            guard !sel.isEmpty else { return beep() }
            let next = nextSelection(after: sel, in: pane)
            if ops.trash(sel.map(\.path)), let next { pane.fileView.select(paths: [next], scroll: true) }
        case "emptyTrash": emptyTrash()
        case "undo":
            if let paths = ops.undo() { selectInPanes(paths) }
        case "redo":
            if let paths = ops.redo() { selectInPanes(paths) }
        case "eject":
            let sel = pane.selectedItems.first?.path ?? pane.path
            eject(sel)
        case "compress":
            let sel = pane.selectedItems.map(\.path)
            guard !sel.isEmpty else { return beep() }
            ops.compress(sel) { [weak self] zip in if let zip { self?.selectInPanes([zip]) } }
        case "extract":
            let zips = pane.selectedItems.filter { $0.ext == "zip" }.map(\.path)
            guard !zips.isEmpty else { return beep() }
            ops.extract(zips) { [weak self] out in self?.selectInPanes(out) }
        case "copyPath": copyText(pane.selectedOrFolder.map(\.path).joined(separator: "\n"), what: "path")
        case "copyTildePath": copyText(pane.selectedOrFolder.map { $0.path.abbreviatingHome }.joined(separator: "\n"), what: "path")
        case "copyName": copyText(pane.selectedOrFolder.map(\.name).joined(separator: "\n"), what: "name")
        case "copyMarkdownLink":
            copyText(pane.selectedOrFolder.map { "[\($0.name)](\($0.url.absoluteString))" }.joined(separator: "\n"), what: "link")
        case "revealInFinder":
            let paths = pane.selectedItems.map(\.path)
            revealInFinder(paths.isEmpty ? [pane.path] : paths)
        case "terminalHere": openTerminal(at: pane.selectedItems.first(where: \.isFolder)?.path ?? pane.targetFolder)
        case "makeSymlink":
            let sel = pane.selectedItems.map(\.path)
            guard !sel.isEmpty else { return beep() }
            ops.makeSymlinks(sel, in: pane.targetFolder)
        case "selectAll":
            pane.focusContent()
            NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: pane.fileView.focusTarget, from: nil)
        case "stackAdd":
            let sel = pane.selectedItems.map(\.path)
            guard !sel.isEmpty else { return beep() }
            AppDelegate.shared.addToStack(sel)
            showMessage("Drop stack: \(Format.items(AppDelegate.shared.state.dropStack.count))")
        case "stackCopyHere", "stackMoveHere":
            let stack = AppDelegate.shared.state.dropStack.filter { FileManager.default.fileExists(atPath: $0) }
            guard !stack.isEmpty else { return beep() }
            let mode: Transfer.Mode = id == "stackCopyHere" ? .copy : .move
            ops.transfer(mode, stack, into: pane.targetFolder) { [weak self] r in
                if mode == .move { AppDelegate.shared.removeFromStack(stack) }
                self?.selectInPanes(r)
            }
        case "stackClear": AppDelegate.shared.clearStack()
        case "cancelOperation": ops.cancelAll()
        case "openSettings": AppDelegate.shared.openConfig(AppDelegate.shared.config.settingsURL)
        case "openKeybindings": AppDelegate.shared.openConfig(AppDelegate.shared.config.keybindingsURL)
        case "openActions": AppDelegate.shared.openConfig(AppDelegate.shared.config.actionsURL)
        case "showMemory": showMessage("Memory footprint: \(Format.size(Int64(AppDelegate.memoryFootprint())))")
        case "newWindow": AppDelegate.shared.newWindow()
        case "expand": return pane.fileView.expandSelected(true)
        case "collapse": return pane.fileView.expandSelected(false)
        case "expandAll": return pane.fileView.expandAll(true)
        case "collapseAll": return pane.fileView.expandAll(false)
        default:
            if id.hasPrefix("action:"), let name = args ?? Optional(String(id.dropFirst(7))) {
                ActionRunner.shared.run(named: name, in: self)
            } else {
                return false
            }
        }
        return true
    }

    @discardableResult
    private func beep() -> Bool {
        NSSound.beep()
        return true
    }

    func setDual(_ dual: Bool) {
        dualPane = dual
        layoutAll()
        for p in panes { p.activeChanged() }
        activePane.focusContent()
        stateChanged()
    }

    /// After an operation: select the results in every pane that shows their folder.
    func selectInPanes(_ paths: [String]) {
        guard let first = paths.first else { return }
        let folder = canonicalFolder((first as NSString).deletingLastPathComponent)
        for p in panes where p.path == folder || p.targetFolder == folder {
            p.folderModel.load(sync: true)
            p.fileView.select(paths: paths, scroll: true)
        }
    }

    private func nextSelection(after items: [FileItem], in pane: PaneController) -> String? {
        let visible = pane.folderModel.visible
        let gone = Set(items.map(\.path))
        guard let last = visible.lastIndex(where: { gone.contains($0.path) }) else { return nil }
        if let after = visible[(last + 1)...].first(where: { !gone.contains($0.path) }) { return after.path }
        return visible[..<last].last(where: { !gone.contains($0.path) })?.path
    }

    private func selectAndRename(_ path: String, in pane: PaneController) {
        pane.folderModel.load(sync: true)
        pane.fileView.select(paths: [path], scroll: true)
        pane.focusContent()
        DispatchQueue.main.async {
            if !pane.fileView.beginInlineRename(), let item = pane.selectedItems.first { self.renamePrompt(item, pane: pane) }
        }
    }

    func rename(_ item: FileItem, to name: String, in pane: PaneController) {
        if let target = OperationCenter.shared.rename(item.path, to: name) {
            pane.folderModel.load(sync: true)
            pane.fileView.select(paths: [target], scroll: true)
        }
    }

    /// Rename for views with no inline editor (columns, thumbnails).
    func renamePrompt(_ item: FileItem, pane: PaneController) {
        let alert = NSAlert()
        alert.messageText = "Rename “\(item.name)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = item.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async {
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: ((item.isFolder ? item.name : item.stem) as NSString).length)
        }
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name != item.name { self?.rename(item, to: name, in: pane) }
        }
    }

    /// The title bar's copy button: the active pane's full path.
    func copyFolderPath(of pane: PaneController) {
        copyText(pane.path, what: "path")
    }

    private func copyText(_ text: String, what: String) {
        guard !text.isEmpty else { return }
        Clipboard.board.clearContents()
        Clipboard.board.setString(text, forType: .string)
        let lines = text.split(separator: "\n").map(String.init)
        let more = lines.count > 1 ? "  (+\(lines.count - 1) more)" : ""
        showMessage("📋 Copied \(lines.count == 1 ? what : "\(lines.count) \(what)s")", detail: (lines.first ?? "") + more)
    }

    func openTerminal(at folder: String) {
        let app = Theme.settings.terminalApp
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app == "Ghostty" ? "com.mitchellh.ghostty" : app)
            ?? NSWorkspace.shared.fullPath(forApplication: app).map({ URL(fileURLWithPath: $0) }) else {
            showMessage("❌ \(app) not found", error: true)
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: url, configuration: cfg)
    }

    private func openWith() {
        let sel = activePane.selectedItems.filter { !$0.isFolder }
        guard let first = sel.first else { return }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: first.url)
        let menu = NSMenu()
        for app in apps.prefix(20) {
            let name = FileManager.default.displayName(atPath: app.path)
            menu.addItem(ClosureMenuItem(title: name) {
                NSWorkspace.shared.open(sel.map(\.url), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            })
        }
        if let frame = activePane.fileView.screenFrame(of: first.path), let window {
            let p = window.convertPoint(fromScreen: frame.origin)
            menu.popUp(positioning: nil, at: p, in: window.contentView)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 200, y: 200), in: window?.contentView)
        }
    }

    /// ⇧⌘F: adds the folder to Favourites, at its place in the tree, or removes it when it's there.
    func toggleFavourite(_ path: String) {
        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        if Theme.settings.favourites.contains(where: { $0.path.expandingHome == path }) {
            AppDelegate.shared.removeFavourite(path)
            showMessage("✖︎ Removed “\(name)” from Favourites", detail: path.abbreviatingHome)
        } else {
            AppDelegate.shared.addFavourites([path])
            showMessage("⭐ Added “\(name)” to Favourites", detail: path.abbreviatingHome)
            sidebar.reveal(path)
        }
    }

    /// ⌥⌘S (Favourites) and ⇧⌥⌘S (Volumes): the keyboard moves to the sidebar. ↑↓ move, ←→ fold, ↩ opens, Esc comes back.
    func focusSidebar(section: Int) {
        if !sidebarVisible {
            sidebarVisible = true
            layoutAll()
            stateChanged()
        }
        sidebar.focus(section: section, current: activePane.path)
    }

    func eject(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? url
        guard volume.path != "/" else {
            showMessage("The startup disk can't be ejected", error: true)
            return
        }
        // Panes on the volume move home first, so they don't hold it open.
        for p in panes where p.path.hasPrefix(volume.path) { p.navigate(to: NSHomeDirectory()) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var err: Error?
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) } catch { err = error }
            DispatchQueue.main.async {
                if let err { self?.showMessage("❌ Eject: \(err.localizedDescription)", error: true) } else { self?.showMessage("⏏ Ejected \(volume.lastPathComponent)") }
                self?.sidebar.reload()
            }
        }
    }

    private func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "The items in the Trash are deleted for good. This can't be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
            if let error { self?.showMessage("❌ Empty Trash: \(error[NSAppleScript.errorMessage] ?? "failed")", error: true) } else { self?.showMessage("🗑 Trash emptied") }
        }
    }

    /// Asks Finder itself: NSWorkspace's activateFileViewerSelecting goes to the file viewer set in NSFileViewer,
    /// which can be Filee (SPEC 5.5).
    func revealInFinder(_ paths: [String]) {
        let items = paths.map { "POSIX file \"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
        let source = "tell application \"Finder\"\nreveal {\(items.joined(separator: ", "))}\nactivate\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { showMessage("❌ Reveal in Finder: \(error[NSAppleScript.errorMessage] ?? "failed")", error: true) }
    }

    private func calculateFolderSizes(_ pane: PaneController) {
        let model = pane.folderModel
        let folders = (pane.selectedItems.filter(\.isFolder).isEmpty ? model.visible : pane.selectedItems).filter { $0.kind == .directory }
        guard !folders.isEmpty else { return beepVoid() }
        showMessage("Calculating \(Format.items(folders.count))…")
        let token = CancelToken()
        DispatchQueue.global(qos: .utility).async {
            for f in folders {
                if token.isCancelled { break }
                let size = DirectoryLister.totalSize(f.path).bytes
                DispatchQueue.main.async {
                    model.folderSizes[f.path] = size
                    model.resort()
                }
            }
            DispatchQueue.main.async { [weak self] in self?.showMessage("✅ Folder sizes calculated") }
        }
    }

    private func beepVoid() { NSSound.beep() }

    // MARK: Drops and the pasteboard

    func drop(urls: [URL], into folder: String, copy: Bool) -> Bool {
        let paths = urls.map(\.path).filter { $0 != folder }
        guard !paths.isEmpty else { return false }
        OperationCenter.shared.transfer(copy ? .copy : .move, paths, into: folder) { [weak self] r in self?.selectInPanes(r) }
        return true
    }

    private var cutPaths: [String] = []
    private var cutChangeCount = -1

    @objc func copy(_ sender: Any?) {
        let items = activePane.selectedItems
        guard !items.isEmpty else { return }
        writeToPasteboard(items)
        cutPaths = []
        showMessage("Copied \(Format.items(items.count)) · ⌘F pastes")
    }

    @objc func cut(_ sender: Any?) {
        let items = activePane.selectedItems
        guard !items.isEmpty else { return }
        writeToPasteboard(items)
        cutPaths = items.map(\.path)
        cutChangeCount = Clipboard.board.changeCount
        showMessage("Cut \(Format.items(items.count)) · ⌘F moves them here")
    }

    private func writeToPasteboard(_ items: [FileItem]) {
        let pb = Clipboard.board
        pb.clearContents()
        pb.writeObjects(items.map { $0.url as NSURL })
        // Paths as text too, for other apps (terminal, editors).
        pb.addTypes([.string], owner: nil)
        pb.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        let pb = Clipboard.board
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let target = activePane.targetFolder
        if !urls.isEmpty {
            let move = !cutPaths.isEmpty && pb.changeCount == cutChangeCount && Set(urls.map(\.path)) == Set(cutPaths)
            OperationCenter.shared.transfer(move ? .move : .copy, urls.map(\.path), into: target) { [weak self] r in self?.selectInPanes(r) }
            if move { cutPaths = [] }
            return
        }
        // Text that is a path: go there.
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("/") || s.hasPrefix("~") {
            let full = s.expandingHome
            if FileManager.default.fileExists(atPath: full) {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                if isDir.boolValue { activePane.navigate(to: full) } else { activePane.navigate(to: (full as NSString).deletingLastPathComponent, select: [full]) }
                return
            }
        }
        NSSound.beep()
    }

    @objc override func selectAll(_ sender: Any?) {
        perform("selectAll")
    }

    @objc func undo(_ sender: Any?) { perform("undo") }
    @objc func toggleThemeClicked(_ sender: Any?) { perform("toggleTheme") }
    @objc func redo(_ sender: Any?) { perform("redo") }

    @objc func runCommand(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String] else { return }
        perform(info[0], args: info.count > 1 ? info[1] : nil)
    }

    // MARK: Context menu

    func contextMenu(for items: [FileItem], in pane: PaneController) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ id: String, args: String? = nil) {
            let it = NSMenuItem(title: title, action: #selector(runCommand(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = [id] + (args.map { [$0] } ?? [])
            if let b = Keymap.shared.binding(for: id, args: args) { AppDelegate.showKey(b, on: it) }
            menu.addItem(it)
        }
        if items.isEmpty {
            add("New Folder", "newFolder")
            add("New Text File", "newFile")
            add("Paste", "pasteHere")
            menu.addItem(.separator())
            add("Open Ghostty Here", "terminalHere")
            add("Calculate Folder Sizes", "folderSizes")
            add("Reveal in Finder", "revealInFinder")
            appendActions(to: menu, items: [])
            return menu
        }
        add("Open", "open")
        if items.contains(where: { !$0.isFolder }) { add("Open With…", "openWith") }
        add("Quick Look", "quickLook")
        add("Get Info", "info")
        menu.addItem(.separator())
        add(items.count == 1 ? "Rename…" : "Batch Rename…", items.count == 1 ? "rename" : "batchRename")
        add("Duplicate", "duplicate")
        add("Copy to Other Pane", "copyToOther")
        add("Move to Other Pane", "moveToOther")
        add("Add to Drop Stack", "stackAdd")
        add("New Folder with Selection", "newFolderWithSelection")
        menu.addItem(.separator())
        add("Compress to Zip", "compress")
        if items.contains(where: { $0.ext == "zip" }) { add("Extract Here", "extract") }
        add("Copy Path", "copyPath")
        add("Copy Path with ~", "copyTildePath")
        add("Copy Name", "copyName")
        add("Make Symbolic Link", "makeSymlink")
        add("Reveal in Finder", "revealInFinder")
        if items.count == 1, items[0].isFolder { add("Open Ghostty Here", "terminalHere") }
        appendActions(to: menu, items: items)
        menu.addItem(.separator())
        add("Move to Trash", "trash")
        return menu
    }

    private func appendActions(to menu: NSMenu, items: [FileItem]) {
        let actions = ActionRunner.shared.actions(for: items)
        guard !actions.isEmpty else { return }
        menu.addItem(.separator())
        for a in actions {
            let it = NSMenuItem(title: a.name, action: #selector(runCommand(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = ["action:" + a.name, a.name]
            menu.addItem(it)
        }
    }

    // MARK: Palette

    func showPalette(mode: PaletteController.Mode = .commands) {
        if palette == nil { palette = PaletteController(window: self) }
        palette?.show(mode: mode)
    }

    // MARK: Window delegate

    func windowDidResize(_ notification: Notification) { stateChanged() }
    func windowDidMove(_ notification: Notification) { stateChanged() }
    func windowDidBecomeKey(_ notification: Notification) { AppDelegate.shared.windowBecameKey(self) }

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared.saveState()
        AppDelegate.shared.windowClosed(self)
    }
}

extension PaneController {
    /// The selection, or the folder itself when nothing is selected.
    var selectedOrFolder: [FileItem] {
        let sel = selectedItems
        if !sel.isEmpty { return sel }
        return [FileItem(name: (path as NSString).lastPathComponent, parent: (path as NSString).deletingLastPathComponent, kind: .directory)]
    }
}

/// The pasteboard Filee writes to. QA uses a private one, so a test run never replaces Nic's clipboard.
enum Clipboard {
    static var board: NSPasteboard {
        ProcessInfo.processInfo.environment["FILEE_QA"] != nil ? NSPasteboard(name: .init("com.nicolasdeville.filee.qa")) : .general
    }
}
