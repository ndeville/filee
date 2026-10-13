import AppKit
import FileeCore

/// The path field: shows the folder; a click, ⌘L or ⌃G makes it editable, Tab completes, Enter goes.
final class PathField: NSTextField {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onClick: (() -> Void)?

    override var isEditable: Bool {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // The first click opens the path for editing with all of it selected, ready for a paste.
        if !isEditable {
            onClick?()
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        if isEditable { super.resetCursorRects() } else { addCursorRect(bounds, cursor: .iBeam) }
    }
}

/// The strip of tabs above a pane.
final class TabStrip: FlippedView {
    var titles: [String] = [] { didSet { rebuild() } }
    var active = 0 { didSet { rebuild() } }
    var activePane = true { didSet { rebuild() } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    private var buttons: [NSButton] = []
    private let plus = iconButton("plus", tip: "New Tab (⌘T)", target: nil, action: #selector(newTab))

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus.target = self
        addSubview(plus)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func newTab() { onNew?() }

    /// The tab names' font size, for QA.
    var titleFontSize: CGFloat? {
        (buttons.first?.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
    }

    @objc private func clicked(_ b: NSButton) {
        if NSEvent.modifierFlags.contains(.option) || NSApp.currentEvent?.buttonNumber == 2 { onClose?(b.tag) } else { onSelect?(b.tag) }
    }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = titles.enumerated().map { i, t in
            let b = NSButton(title: t, target: self, action: #selector(clicked(_:)))
            b.tag = i
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 4
            let isActive = i == active
            b.layer?.backgroundColor = (isActive ? Theme.surface2 : NSColor.clear).cgColor
            b.attributedTitle = NSAttributedString(string: t, attributes: [
                .font: Theme.listFont(bold: isActive),
                .foregroundColor: isActive ? Theme.fg : Theme.muted,
            ])
            b.toolTip = "Click: show. ⌥-click: close."
            addSubview(b)
            return b
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // A margin around each tab and its name: 8 px from the pane's edge, 4 px above and below, 14 px each side of the name.
        var x: CGFloat = 8
        let h = bounds.height
        let maxW = max(60, min(Theme.listSize * 15, (bounds.width - 48) / CGFloat(max(1, buttons.count))))
        for b in buttons {
            let w = min(maxW, b.intrinsicContentSize.width + 28)
            b.frame = NSRect(x: x, y: 4, width: w, height: h - 8)
            x += w + 4
        }
        let p = (h * 0.7).rounded()
        plus.frame = NSRect(x: min(x + 4, bounds.width - p - 4), y: ((h - p) / 2).rounded(), width: p, height: p)
    }
}

/// 1 pane: tabs, path, the file view, the filter line. Each pane has its own tabs, history and view.
final class PaneController: NSObject, FileViewDelegate, NSTextFieldDelegate {
    let container = FlippedView()
    let accentBar = ColorView(Theme.activeBar)
    let tabStrip = TabStrip()
    let typeBar = TypeFilterBar()
    let pathField = PathField()
    let countLabel = label("", size: 11, color: Theme.muted)
    // Type-to-filter shows what you type at the top of the pane: the query, a blinking caret, the count.
    let filterBar = ColorView(Theme.accentSoft)
    private let filterStripe = ColorView(Theme.accent)
    private let filterIcon = NSImageView()
    let filterLabel = label("", size: 15, weight: .bold, color: Theme.fg)
    private let filterCaret = ColorView(Theme.accent)
    private let filterHint = label("", size: 11.5, color: Theme.muted)
    private var caretTimer: Timer?
    let messageLabel = label("", size: 13, color: Theme.muted)
    let contentHost = FlippedView()

    unowned let window: BrowserWindowController
    let index: Int
    private(set) var tabs: [TabModel] = []
    private(set) var activeTab = 0
    private(set) var fileView: FileView!
    private var views: [ViewMode: FileView] = [:]

    var isActivePane: Bool { window.activePaneIndex == index }
    var tab: TabModel { tabs[activeTab] }
    var folderModel: FolderModel { tab.folder }
    var path: String { tab.path }

    init(window: BrowserWindowController, index: Int, state: PaneState?) {
        self.window = window
        self.index = index
        super.init()
        let startTabs = state?.tabs.filter { FileManager.default.fileExists(atPath: $0.path.expandingHome) } ?? []
        let paths = startTabs.isEmpty ? [index == 0 ? Theme.settings.newTabPath.expandingHome : NSHomeDirectory()] : startTabs.map { $0.path.expandingHome }
        for p in paths { tabs.append(TabModel(path: canonicalFolder(p), view: AppDelegate.shared.view(for: p))) }
        activeTab = min(max(0, state?.activeTab ?? 0), tabs.count - 1)
        buildUI()
        showTab(activeTab)
    }

    private func buildUI() {
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.bg.cgColor
        pathField.isBordered = false
        pathField.drawsBackground = false
        pathField.isEditable = false
        pathField.isSelectable = false
        pathField.focusRingType = .none
        pathField.lineBreakMode = .byTruncatingHead
        pathField.cell?.usesSingleLineMode = true
        pathField.delegate = self
        pathField.onClick = { [weak self] in self?.editPath() }
        tabStrip.onSelect = { [weak self] i in self?.showTab(i) }
        tabStrip.onClose = { [weak self] i in self?.closeTab(i) }
        tabStrip.onNew = { [weak self] in self?.newTab() }
        typeBar.onSelect = { [weak self] f in self?.setTypeFilter(f) }
        filterLabel.lineBreakMode = .byTruncatingHead
        filterHint.alignment = .right
        filterHint.lineBreakMode = .byTruncatingHead
        filterIcon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "Filter")
        filterIcon.contentTintColor = Theme.accent
        filterIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        for v in [filterStripe, filterIcon, filterLabel, filterCaret, filterHint] as [NSView] { filterBar.addSubview(v) }
        filterBar.isHidden = true
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.isHidden = true
        for v in [accentBar, tabStrip, typeBar, pathField, countLabel, contentHost, filterBar, messageLabel] as [NSView] { container.addSubview(v) }
        let click = NSClickGestureRecognizer(target: self, action: #selector(headerClicked))
        tabStrip.addGestureRecognizer(click)
        click.delaysPrimaryMouseButtonEvents = false
    }

    @objc private func headerClicked() { window.activate(pane: index) }

    func layout() {
        let b = container.bounds
        let tabH = Theme.tabHeight, pathH: CGFloat = 26, accentH: CGFloat = 3
        accentBar.frame = NSRect(x: 0, y: 0, width: b.width, height: accentH)
        // The type filter sits right of the tabs; a narrow pane keeps the room for its tabs.
        typeBar.isHidden = b.width < 420
        let typeW = typeBar.isHidden ? 0 : typeBar.width + 10
        typeBar.frame = NSRect(x: b.width - typeW, y: accentH, width: typeBar.width, height: tabH)
        tabStrip.frame = NSRect(x: 0, y: accentH, width: b.width - typeW, height: tabH)
        let countW = min(160, textWidth(countLabel.stringValue, font: countLabel.font!) + 12)
        pathField.frame = NSRect(x: 10, y: accentH + tabH + 3, width: b.width - countW - 20, height: pathH - 6)
        countLabel.frame = NSRect(x: b.width - countW - 6, y: accentH + tabH + 5, width: countW, height: pathH - 8)
        countLabel.alignment = .right
        let top = accentH + tabH + pathH
        let filterH: CGFloat = filterBar.isHidden ? 0 : 34
        filterBar.frame = NSRect(x: 0, y: top, width: b.width, height: filterH)
        contentHost.frame = NSRect(x: 0, y: top + filterH, width: b.width, height: max(0, b.height - top - filterH))
        layoutFilterBar()
        fileView?.root.frame = contentHost.bounds
        messageLabel.frame = NSRect(x: 30, y: top + filterH + 60, width: max(0, b.width - 60), height: 60)
    }

    // MARK: Active state

    /// Theme switch: layer colours are fixed CGColors, set them again.
    func appearanceChanged() {
        container.layer?.backgroundColor = Theme.bg.cgColor
        tabStrip.active = tabStrip.active
        typeBar.refresh()
        activeChanged()
    }

    func activeChanged() {
        let active = isActivePane
        accentBar.color = active ? Theme.activeBar : Theme.line
        container.alphaValue = active || !window.dualPane ? 1 : 0.85
        tabStrip.activePane = active
        updatePathLabel()
        fileView?.activeChanged(active)
    }

    private func updatePathLabel() {
        guard !pathField.isEditable else { return }
        let active = isActivePane
        pathField.attributedStringValue = NSAttributedString(string: folderModel.displayPath, attributes: [
            .font: Theme.ui(13, weight: active ? .bold : .regular),
            .foregroundColor: active ? Theme.fg : Theme.muted,
        ])
        pathField.toolTip = "\(folderModel.path)\nClick to type or paste a path to go to."
    }

    private func updateCount() {
        let m = folderModel
        let selected = fileView?.selectedItems.count ?? 0
        var text = m.query.isEmpty ? Format.items(m.unfilteredCount) : "\(m.visible.count) of \(m.unfilteredCount)"
        if selected > 0 { text = "\(selected) selected · " + text }
        if m.types != .all { text = "\(m.types.title) · " + text }
        countLabel.stringValue = text
        layout()
    }

    /// Shows only 1 family of files in this tab (folders stay), or everything again.
    func setTypeFilter(_ f: FileTypeFilter) {
        window.activate(pane: index)
        tab.types = f
        typeBar.selected = f
        folderModel.types = f
        window.showMessage(f == .all ? "Showing all files" : "Showing only \(f.title) files")
    }

    // MARK: Tabs

    func showTab(_ i: Int) {
        guard i >= 0, i < tabs.count else { return }
        if tabs.indices.contains(activeTab), i != activeTab || fileView == nil {
            if fileView != nil { tab.savedSelection = fileView.selectedItems.map(\.path) }
            folderModel.stopWatching()
        }
        activeTab = i
        tabStrip.titles = tabs.map { $0.folder.name }
        tabStrip.active = i
        typeBar.selected = tab.types
        attach(folderModel)
        setView(tab.view, focus: false)
        loadCurrent(select: tab.savedSelection)
    }

    func newTab(path: String? = nil) {
        let p = canonicalFolder(path ?? Theme.settings.newTabPath.expandingHome)
        if fileView != nil { tab.savedSelection = fileView.selectedItems.map(\.path) }
        tabs.insert(TabModel(path: p, view: AppDelegate.shared.view(for: p)), at: activeTab + 1)
        showTab(activeTab + 1)
        window.stateChanged()
    }

    func closeTab(_ i: Int? = nil) {
        let idx = i ?? activeTab
        guard tabs.count > 1 else {
            NSSound.beep()
            return
        }
        tabs[idx].folder.stopWatching()
        tabs.remove(at: idx)
        let next = min(idx == activeTab ? idx : (idx < activeTab ? activeTab - 1 : activeTab), tabs.count - 1)
        activeTab = -1
        showTab(next)
        window.stateChanged()
    }

    func cycleTab(_ step: Int) {
        guard tabs.count > 1 else { return }
        showTab((activeTab + step + tabs.count) % tabs.count)
    }

    var state: PaneState {
        PaneState(tabs: tabs.map { TabState(path: $0.path.abbreviatingHome) }, activeTab: activeTab)
    }

    // MARK: Navigation

    private func attach(_ model: FolderModel) {
        let saved = AppDelegate.shared.folderView(for: model.path)
        model.sortKey = saved?.sort ?? .name
        model.ascending = saved?.ascending ?? true
        model.showHidden = window.showHidden
        model.types = tab.types
        model.onChange = { [weak self, weak model] reloaded in
            guard let self, let model, model === self.folderModel else { return }
            self.modelChanged(reloaded: reloaded)
        }
    }

    private func loadCurrent(select: [String] = []) {
        let model = folderModel
        pendingSelection = select
        model.load(sync: !model.loaded)
        model.startWatching()
        updatePathLabel()
        tabStrip.titles = tabs.map { $0.folder.name }
        updateCount()
    }

    private var pendingSelection: [String] = []

    private func modelChanged(reloaded: Bool) {
        let m = folderModel
        var t = Profile.now
        fileView.modelChanged(reloaded: reloaded)
        t = Profile.mark("view.modelChanged", t)
        if !pendingSelection.isEmpty {
            fileView.select(paths: pendingSelection, scroll: true)
            pendingSelection = []
        }
        if fileView.selectedItems.isEmpty, reloaded, !m.visible.isEmpty, m.query.isEmpty {
            fileView.selectVisible(0)
        }
        if reloaded { autoThumbnails(m) }
        if let err = m.error {
            messageLabel.stringValue = err
            messageLabel.isHidden = false
        } else if m.visible.isEmpty {
            messageLabel.stringValue = m.query.isEmpty ? "Empty folder" : "No match for “\(m.query)”"
            messageLabel.isHidden = false
        } else {
            messageLabel.isHidden = true
        }
        updateFilterBar()
        updateCount()
        window.paneContentChanged(self)
        Profile.mark("pane rest", t)
    }

    private var autoChecked = Set<String>()

    /// Image folders open as thumbnails on the first visit when no view was saved (SPEC 3.1).
    private func autoThumbnails(_ m: FolderModel) {
        guard autoChecked.insert(m.path).inserted, tab.view == .list, AppDelegate.shared.folderView(for: m.path)?.view == nil,
              m.visible.count >= 4 else { return }
        let images: Set<String> = ["jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff", "bmp", "svg", "avif"]
        let count = m.visible.filter { images.contains($0.ext) }.count
        if count * 2 > m.visible.count { setView(.thumbnails, focus: container.window?.firstResponder === fileView.focusTarget) }
    }

    /// Goes to a folder in this tab. `select`: paths to select once listed (the folder we came from, on ⌘↑).
    func navigate(to rawPath: String, select: [String] = [], record: Bool = true) {
        let p = canonicalFolder(rawPath.expandingHome)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else {
            window.showMessage("Not a folder: \(rawPath)", error: true)
            return
        }
        if p == path, select.isEmpty {
            reload()
            return
        }
        folderModel.query = ""
        let model = tab.go(to: p, record: record)
        tab.view = AppDelegate.shared.view(for: p) ?? tab.view
        attach(model)
        setView(tab.view, focus: false)
        loadCurrent(select: select)
        AppDelegate.shared.addRecent(p)
        AppDelegate.shared.scheduleMemoryRelief()
        window.stateChanged()
    }

    func goUp() {
        let current = path
        guard current != "/" else { return }
        navigate(to: (current as NSString).deletingLastPathComponent, select: [current])
    }

    func goBack() {
        guard let p = tab.back.popLast() else {
            NSSound.beep()
            return
        }
        tab.forward.append(path)
        let from = path
        navigate(to: p, select: [from].filter { ($0 as NSString).deletingLastPathComponent == p }, record: false)
    }

    func goForward() {
        guard let p = tab.forward.popLast() else {
            NSSound.beep()
            return
        }
        tab.back.append(path)
        navigate(to: p, record: false)
    }

    func reload() {
        folderModel.load()
    }

    /// Enter, ⌘O, double-click.
    func open(_ item: FileItem) {
        if item.isFolder {
            navigate(to: item.path)
            return
        }
        let url = item.url
        if let v = try? url.resourceValues(forKeys: [.isAliasFileKey]), v.isAliasFile == true,
           let target = try? URL(resolvingAliasFileAt: url), (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            navigate(to: target.path)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openSelection() {
        let items = selectedItems
        if items.count == 1 {
            open(items[0])
        } else {
            for it in items where !it.isFolder { NSWorkspace.shared.open(it.url) }
        }
    }

    // MARK: Views

    func setView(_ mode: ViewMode, focus: Bool = true) {
        let had = fileView != nil && tab.view == mode && views[mode] === fileView
        tab.view = mode
        if !had {
            let selection = fileView?.selectedItems.map(\.path) ?? []
            fileView?.root.removeFromSuperview()
            // Only the view on screen is kept: a hidden view's layers cost memory for nothing.
            views = views.filter { $0.key == mode }
            let v: FileView
            if let existing = views[mode] {
                v = existing
            } else {
                switch mode {
                case .list: v = ListView(delegate: self)
                case .columns: v = ColumnsView(delegate: self)
                case .thumbnails: v = ThumbnailsView(delegate: self)
                }
                views[mode] = v
            }
            fileView = v
            contentHost.addSubview(v.root)
            v.root.frame = contentHost.bounds
            v.root.autoresizingMask = [.width, .height]
            v.activeChanged(isActivePane)
            if folderModel.loaded {
                v.modelChanged(reloaded: true)
                v.select(paths: selection, scroll: true)
            }
        }
        if focus { focusContent() }
        layout()
    }

    func changeView(_ mode: ViewMode) {
        setView(mode)
        AppDelegate.shared.rememberView(for: path, mode)
        window.stateChanged()
    }

    func focusContent() {
        container.window?.makeFirstResponder(fileView.focusTarget)
    }

    func styleChanged() {
        for v in views.values { v.styleChanged() }
        fileView.modelChanged(reloaded: false)
        updatePathLabel()
        // The tab names and the type filter follow the file list's size.
        tabStrip.active = tabStrip.active
        typeBar.styleChanged()
        layout()
    }

    var selectedItems: [FileItem] { fileView.selectedItems }
    var targetFolder: String { fileView.targetFolder }

    // MARK: Filter (decision 17)

    func fileView(typed text: String) -> Bool {
        if text == " " && folderModel.query.isEmpty { return false }
        // Vim keys (settings.json "vimKeys"): h j k l move while no filter is typed.
        if Theme.settings.vimKeys, folderModel.query.isEmpty, let code = ["h": 123, "j": 125, "k": 126, "l": 124][text],
           let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
                                     windowNumber: container.window?.windowNumber ?? 0, context: nil,
                                     characters: String(Character(UnicodeScalar([123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey][code]!)!)),
                                     charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)) {
            fileView.focusTarget.keyDown(with: ev)
            return true
        }
        folderModel.query += text
        return true
    }

    func fileViewEscape() -> Bool {
        guard !folderModel.query.isEmpty else { return false }
        clearFilter()
        return true
    }

    func fileViewBackspace() -> Bool {
        guard !folderModel.query.isEmpty else { return false }
        folderModel.query.removeLast()
        return true
    }

    func clearFilter() {
        let selection = selectedItems.map(\.path)
        folderModel.query = ""
        fileView.select(paths: selection, scroll: true)
    }

    private func updateFilterBar() {
        let q = folderModel.query
        let hidden = q.isEmpty
        // Spaces would be invisible: show them as a middle dot.
        filterLabel.stringValue = q.replacingOccurrences(of: " ", with: "·")
        filterHint.stringValue = hidden ? "" : "\(folderModel.visible.count) of \(folderModel.unfilteredCount)   ·   Esc clears   ·   ⌫ deletes"
        if filterBar.isHidden != hidden {
            filterBar.isHidden = hidden
            layout()
        } else {
            layoutFilterBar()
        }
        hidden ? stopCaret() : startCaret()
    }

    private func layoutFilterBar() {
        guard !filterBar.isHidden else { return }
        let w = filterBar.bounds.width, h = filterBar.bounds.height
        filterStripe.frame = NSRect(x: 0, y: 0, width: 3, height: h)
        filterIcon.frame = NSRect(x: 12, y: (h - 18) / 2, width: 18, height: 18)
        let hintW = min(w * 0.45, textWidth(filterHint.stringValue, font: filterHint.font!) + 8)
        filterHint.frame = NSRect(x: w - hintW - 12, y: (h - 15) / 2, width: hintW, height: 15)
        let maxQ = max(20, w - hintW - 36 - 30)
        let qW = min(maxQ, textWidth(filterLabel.stringValue, font: filterLabel.font!) + 6)
        filterLabel.frame = NSRect(x: 36, y: (h - 20) / 2, width: qW, height: 20)
        filterCaret.frame = NSRect(x: 36 + qW, y: (h - 18) / 2, width: 2, height: 18)
    }

    private func startCaret() {
        filterCaret.isHidden = false
        guard caretTimer == nil else { return }
        let t = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.filterCaret.isHidden.toggle()
        }
        RunLoop.main.add(t, forMode: .common)
        caretTimer = t
    }

    private func stopCaret() {
        caretTimer?.invalidate()
        caretTimer = nil
    }

    // MARK: Path field (decision 13)

    func editPath() {
        window.activate(pane: index)
        pathField.isEditable = true
        pathField.isSelectable = true
        pathField.font = Theme.ui(13)
        pathField.textColor = Theme.fg
        pathField.stringValue = path.abbreviatingHome + (path == "/" ? "" : "/")
        container.window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectedRange = NSRange(location: 0, length: (pathField.stringValue as NSString).length)
    }

    private func endPathEdit() {
        pathField.isEditable = false
        pathField.isSelectable = false
        updatePathLabel()
        focusContent()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === pathField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = Self.pastedPath(pathField.stringValue)
            endPathEdit()
            let full = text.expandingHome
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                // A file path: go to its folder and select it.
                navigate(to: (full as NSString).deletingLastPathComponent, select: [full])
            } else {
                navigate(to: full)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endPathEdit()
            return true
        case #selector(NSResponder.insertTab(_:)):
            completePath(textView)
            return true
        default:
            return false
        }
    }

    /// A path pasted from elsewhere: quotes, a file:// URL, shell escapes or a trailing newline still go there.
    static func pastedPath(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count >= 2, let q = t.first, q == t.last, q == "\"" || q == "'" { t = String(t.dropFirst().dropLast()) }
        if t.hasPrefix("file://"), let url = URL(string: t) { return url.path }
        return t.replacingOccurrences(of: "\\ ", with: " ")
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === pathField, pathField.isEditable { endPathEdit() }
    }

    /// Tab completion: the longest common start of the folders that match what is typed.
    private func completePath(_ editor: NSTextView) {
        let text = editor.string
        let full = text.expandingHome
        let folder = full.hasSuffix("/") ? full : (full as NSString).deletingLastPathComponent
        let prefix = full.hasSuffix("/") ? "" : (full as NSString).lastPathComponent
        guard let items = try? DirectoryLister.list(folder) else {
            NSSound.beep()
            return
        }
        let matches = items.filter { $0.isFolder && !$0.isHidden || ($0.isFolder && prefix.hasPrefix(".")) }
            .map(\.name).filter { $0.lowercased().hasPrefix(prefix.lowercased()) }.sorted()
        guard let first = matches.first else {
            NSSound.beep()
            return
        }
        var common = first
        for m in matches.dropFirst() {
            while !m.lowercased().hasPrefix(common.lowercased()) { common.removeLast() }
        }
        var completed = (folder as NSString).appendingPathComponent(matches.count == 1 ? first : common)
        if matches.count == 1 { completed += "/" }
        let display = completed.abbreviatingHome + (completed.hasSuffix("/") && !completed.abbreviatingHome.hasSuffix("/") ? "/" : "")
        editor.string = display
        editor.selectedRange = NSRange(location: (display as NSString).length, length: 0)
        if matches.count > 1 { window.showMessage(matches.prefix(12).joined(separator: "   ")) }
    }

    // MARK: FileViewDelegate

    func fileView(open item: FileItem) { open(item) }

    func fileViewSelectionChanged() {
        updateCount()
        window.selectionChanged(in: self)
    }

    func fileViewMenu(for items: [FileItem]) -> NSMenu? {
        window.activate(pane: index)
        return window.contextMenu(for: items, in: self)
    }

    func fileView(drop urls: [URL], into folder: String, copy: Bool) -> Bool {
        window.activate(pane: index)
        return window.drop(urls: urls, into: folder, copy: copy)
    }

    func fileView(rename item: FileItem, to name: String) {
        window.rename(item, to: name, in: self)
    }

    func fileViewBecameFocused() {
        if !isActivePane { window.activate(pane: index) }
    }

    func listing(of folder: String) -> [FileItem] {
        (try? DirectoryLister.list(folder)) ?? []
    }
}

/// A folder path with symlinks in its parents kept (unlike realpath), without a trailing "/".
func canonicalFolder(_ path: String) -> String {
    var p = (path as NSString).standardizingPath
    while p.count > 1, p.hasSuffix("/") { p.removeLast() }
    return p.isEmpty ? "/" : p
}
