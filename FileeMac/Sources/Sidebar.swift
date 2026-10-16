import AppKit
import FileeCore

/// Sidebar sizes, from `sidebarFontSize` in settings.json.
enum SidebarMetrics {
    static var font: CGFloat { CGFloat(Theme.settings.sidebarFontSize) }
    static var rowHeight: CGFloat { (font * 2).rounded() }
    static var headerHeight: CGFloat { (font * 2.3).rounded() }
    static var icon: CGFloat { (font * 1.3).rounded() }
    static let indent: CGFloat = 16
}

/// Filee draws its own chevrons and indents: every row gets the full width.
/// Keys: ↑↓ move, ←→ fold and unfold (NSOutlineView), ↩ opens, Esc or Tab goes back to the pane.
final class SidebarOutline: NSOutlineView {
    var onOpen: (() -> Void)?
    var onLeave: (() -> Void)?

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 36, 76: onOpen?()
        case 53, 48: onLeave?()
        default: super.keyDown(with: event)
        }
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let cell = super.frameOfCell(atColumn: column, row: row)
        let full = rect(ofRow: row)
        return NSRect(x: full.minX, y: cell.minY, width: full.width, height: cell.height)
    }
}

/// Favourites (a tree from the root), volumes, recent folders and the drop stack (SPEC 6).
final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Section {
        let title: String
        var rows: [Row] = []
        init(_ title: String) { self.title = title }
    }

    final class Row {
        /// A branch is a folder that holds 2 or more favourites without being one.
        enum Kind { case favourite, branch, volume, recent, stack }
        let kind: Kind
        let name: String
        let path: String
        let detail: String
        var children: [Row] = []
        var level = 0
        var volumeStyle: VolumeStyle?
        init(_ kind: Kind, _ name: String, _ path: String, detail: String = "") {
            self.kind = kind
            self.name = name
            self.path = path
            self.detail = detail
        }
    }

    struct VolumeInfo: Equatable {
        var name: String
        var free: String
        var isLocal: Bool
        var isInternal: Bool
    }

    let scroll = NSScrollView()
    let outline = SidebarOutline()
    unowned let window: BrowserWindowController
    private let sections = [Section("Favourites"), Section("Volumes"), Section("Recent"), Section("Drop Stack")]
    private var volumeObservers: [NSObjectProtocol] = []
    /// True while reload() restores the folded state: the expand and collapse events aren't the user's.
    private var restoring = false

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.style = .sourceList
        outline.backgroundColor = Theme.surface
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .custom
        outline.indentationPerLevel = 0
        outline.target = self
        outline.action = #selector(clicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.onOpen = { [weak self] in
            guard let self, let row = self.outline.item(atRow: self.outline.selectedRow) as? Row else { return }
            self.open(row)
        }
        outline.onLeave = { [weak self] in self?.window.activePane.focusContent() }
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.surface
        scroll.borderType = .noBorder
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reload() })
        }
        reload()
    }

    private var volumeDetails: [String: VolumeInfo] = [:]
    /// README screenshots (screenshots.py): these volumes instead of the mounted ones, so no real volume shows.
    var demoVolumes: [(path: String, info: VolumeInfo)]? { didSet { reload() } }
    private var detailsLoading = false

    private func loadVolumeDetails(_ urls: [URL]) {
        guard !detailsLoading else { return }
        detailsLoading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var out: [String: VolumeInfo] = [:]
            let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey,
                                             .volumeIsLocalKey, .volumeIsInternalKey]
            for url in urls {
                let v = try? url.resourceValues(forKeys: keys)
                if v?.volumeIsBrowsable == false { continue }
                // Network shares report 0: show nothing rather than "0 B". The sidebar is narrow: "free" goes in the tooltip.
                let free = v?.volumeAvailableCapacityForImportantUsage ?? 0
                out[url.path] = VolumeInfo(name: v?.volumeName ?? url.lastPathComponent, free: free > 0 ? Format.size(free) : "",
                                           isLocal: v?.volumeIsLocal ?? true, isInternal: v?.volumeIsInternal ?? false)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.detailsLoading = false
                let changed = out != self.volumeDetails
                self.volumeDetails = out
                if changed { self.reload() }
            }
        }
    }

    deinit { volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    func reload() {
        let app = AppDelegate.shared!
        let kept = selectedRow.map { (kind: $0.kind, path: $0.path) }
        let favourites = Theme.settings.favourites.map { (name: $0.name, path: $0.path.expandingHome) }
        sections[0].rows = FavouriteTree.build(favourites, home: NSHomeDirectory()).map { row(for: $0, level: 0) }
        // Volume names and free space are slow on network shares (100+ ms): the list shows at once,
        // the details arrive from a background queue.
        let urls = demoVolumes == nil ? FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] : []
        if let demo = demoVolumes {
            for v in demo { volumeDetails[v.path] = v.info }
        }
        let paths = demoVolumes?.map { $0.path } ?? urls.map(\.path)
        let volumes = paths.map { path -> Row in
            let known = volumeDetails[path]
            return Row(.volume, known?.name ?? (path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent), path, detail: known?.free ?? "")
        }
        let colours = Icons.volumeColours(volumes.filter { $0.path != "/" }.map(\.name))
        for v in volumes {
            let info = volumeDetails[v.path]
            v.volumeStyle = Icons.volumeStyle(path: v.path, name: v.name, isLocal: info?.isLocal, isInternal: info?.isInternal,
                                              color: colours[v.name] ?? Theme.folderIcon)
        }
        sections[1].rows = volumes
        if demoVolumes == nil { loadVolumeDetails(urls) }
        sections[2].rows = app.state.recent.prefix(10).map { Row(.recent, ($0 as NSString).lastPathComponent, $0.expandingHome) }
        sections[3].rows = app.state.dropStack.map { Row(.stack, ($0 as NSString).lastPathComponent, $0) }
        // A favourite on a volume shows the volume's icon.
        let styles = Dictionary(volumes.map { ($0.path, $0.volumeStyle) }, uniquingKeysWith: { a, _ in a })
        func styleFavourites(_ rows: [Row]) {
            for r in rows {
                if let s = styles[r.path] { r.volumeStyle = s }
                styleFavourites(r.children)
            }
        }
        styleFavourites(sections[0].rows)
        restoring = true
        outline.reloadData()
        for s in sections { outline.expandItem(s) }
        expandFavourites(sections[0].rows, collapsed: Set(app.state.collapsedFavourites))
        restoring = false
        // A settings change or a new volume keeps the selected row.
        if let kept {
            for i in 0..<outline.numberOfRows {
                guard let r = outline.item(atRow: i) as? Row, r.kind == kept.kind, r.path == kept.path else { continue }
                outline.selectRowIndexes([i], byExtendingSelection: false)
                break
            }
        }
    }

    private func row(for node: FavouriteNode, level: Int) -> Row {
        let r = Row(node.isFavourite ? .favourite : .branch, node.name, node.path)
        r.level = level
        r.children = node.children.map { row(for: $0, level: level + 1) }
        return r
    }

    private func expandFavourites(_ rows: [Row], collapsed: Set<String>) {
        for r in rows where !r.children.isEmpty && !collapsed.contains(r.path) {
            outline.expandItem(r)
            expandFavourites(r.children, collapsed: collapsed)
        }
    }

    /// Selects the row of the active folder in a section (or its first row) and gives the sidebar the keyboard.
    func focus(section index: Int, current: String) {
        var rows: [Row] = []
        func walk(_ list: [Row]) {
            for r in list {
                rows.append(r)
                if outline.isItemExpanded(r) { walk(r.children) }
            }
        }
        walk(sections[index].rows)
        guard let target = rows.first(where: { $0.path == current }) ?? rows.first else { return NSSound.beep() }
        let i = outline.row(forItem: target)
        guard i >= 0 else { return }
        outline.selectRowIndexes([i], byExtendingSelection: false)
        outline.scrollRowToVisible(i)
        outline.window?.makeFirstResponder(outline)
    }

    /// The selected row, for QA.
    var selectedRow: Row? { outline.item(atRow: outline.selectedRow) as? Row }

    /// Unfolds the tree down to a favourite and scrolls to it.
    func reveal(_ path: String) {
        if AppDelegate.shared.unfoldFavourites(above: path) { reload() }
        func find(_ rows: [Row]) -> Row? {
            for r in rows {
                if r.path == path, r.kind == .favourite { return r }
                if let hit = find(r.children) { return hit }
            }
            return nil
        }
        guard let r = find(sections[0].rows) else { return }
        let i = outline.row(forItem: r)
        if i >= 0 { outline.scrollRowToVisible(i) }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let s = item as? Section { return s.rows.count }
        if let r = item as? Row { return r.children.count }
        return sections.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let s = item as? Section { return s.rows[index] }
        if let r = item as? Row { return r.children[index] }
        return sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Section || !((item as? Row)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Section }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Row }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is Section ? SidebarMetrics.headerHeight : SidebarMetrics.rowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let f = SidebarMetrics.font
        if let s = item as? Section {
            let l = label(s.title.uppercased(), size: (f * 0.78).rounded(), weight: .bold, color: Theme.muted)
            let v = NSTableCellView()
            v.addSubview(l)
            l.frame = NSRect(x: 10, y: 5, width: 400, height: (f * 1.1).rounded())
            return v
        }
        guard let row = item as? Row else { return nil }
        let v = SidebarCell()
        v.level = row.level
        if let style = row.volumeStyle {
            v.icon.image = style.logo ?? Icons.symbol(style.symbol)
            v.icon.contentTintColor = style.logo == nil ? style.color : nil
        } else {
            switch row.kind {
            case .stack: v.icon.image = NSWorkspace.shared.icon(forFile: row.path)
            case .recent: v.icon.image = Icons.symbol("clock")
            case .favourite: v.icon.image = Icons.symbol(row.path == NSHomeDirectory() ? "house" : "folder")
            case .branch, .volume: v.icon.image = Icons.symbol("folder")
            }
            v.icon.contentTintColor = Theme.folderIcon
            // A folder with its own icon (Dropbox) shows it.
            if row.kind == .favourite || row.kind == .branch, let own = Icons.customFolderIcon(row.path) {
                v.icon.image = own
                v.icon.contentTintColor = nil
            }
        }
        v.name.stringValue = row.name
        if row.kind == .branch {
            v.name.textColor = Theme.muted
            // A logo (Dropbox) stays in full colour.
            if v.icon.contentTintColor != nil { v.icon.alphaValue = 0.6 }
        }
        if row.kind == .favourite || row.kind == .branch {
            // Favourites keep a chevron column, so icons line up whether a row has children or not.
            v.chevronColumn = true
            if !row.children.isEmpty {
                let b = ClosureButton(symbol: "chevron.right", tip: "Show or hide the favourites inside") { [weak self] in self?.toggle(row) }
                b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: (f * 0.7).rounded(), weight: .semibold)
                b.setAccessibilityIdentifier("chevron:" + row.path)
                v.chevron = b
                v.setExpanded(outline.isItemExpanded(row))
            }
        }
        if !row.detail.isEmpty {
            let d = label(row.detail, size: (f * 0.78).rounded(), color: Theme.muted)
            d.alignment = .right
            v.detail = d
        }
        // Mounted drives, disk images and shares get an eject button; the startup disk doesn't.
        if Self.isEjectable(row) {
            let b = ClosureButton(symbol: "eject.fill", tip: "Eject \(row.name) (⌘E)") { [weak self] in self?.window.eject(row.path) }
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: (f * 0.8).rounded(), weight: .medium)
            b.setAccessibilityIdentifier("eject:" + row.path)
            v.eject = b
        }
        v.toolTip = row.path.abbreviatingHome + (row.detail.isEmpty ? "" : " · \(row.detail) free")
        return v
    }

    private func toggle(_ row: Row) {
        if outline.isItemExpanded(row) { outline.collapseItem(row) } else { outline.expandItem(row) }
    }

    /// Folds or unfolds the favourite at `path`. False when it has nothing inside.
    @discardableResult
    func toggle(path: String) -> Bool {
        func find(_ rows: [Row]) -> Row? {
            for r in rows {
                if r.path == path { return r }
                if let hit = find(r.children) { return hit }
            }
            return nil
        }
        guard let r = find(sections[0].rows), !r.children.isEmpty else { return false }
        toggle(r)
        return true
    }

    func outlineViewItemDidExpand(_ notification: Notification) { folded(notification, collapsed: false) }
    func outlineViewItemDidCollapse(_ notification: Notification) { folded(notification, collapsed: true) }

    private func folded(_ notification: Notification, collapsed: Bool) {
        guard let row = notification.userInfo?["NSObject"] as? Row else { return }
        let i = outline.row(forItem: row)
        (outline.view(atColumn: 0, row: i, makeIfNecessary: false) as? SidebarCell)?.setExpanded(!collapsed)
        guard !restoring else { return }
        AppDelegate.shared.setFavouriteFolded(row.path, collapsed)
    }

    static func isEjectable(_ row: Row) -> Bool {
        row.kind == .volume && row.path.hasPrefix("/Volumes/")
    }

    @objc private func clicked() {
        guard let row = outline.item(atRow: outline.clickedRow) as? Row else { return }
        open(row)
    }

    func open(_ row: Row) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: row.path, isDirectory: &isDir) else {
            window.showMessage("Not found: \(row.path.abbreviatingHome)", error: true)
            return
        }
        if isDir.boolValue, !DirectoryLister.packageExtensions.contains((row.path as NSString).pathExtension.lowercased()) {
            window.activePane.navigate(to: row.path)
        } else {
            window.activePane.navigate(to: (row.path as NSString).deletingLastPathComponent, select: [row.path])
        }
        window.activePane.focusContent()
    }

    /// The tree as text ("Home(Dropbox(Family Work))"), with folded rows marked "-", for QA.
    var favouritesOutline: String {
        func text(_ r: Row) -> String {
            let mark = (r.kind == .branch ? "+" : "") + (!r.children.isEmpty && !outline.isItemExpanded(r) ? "-" : "")
            return r.children.isEmpty ? mark + r.name : mark + r.name + "(" + r.children.map(text).joined(separator: " ") + ")"
        }
        return sections[0].rows.map(text).joined(separator: " ")
    }

    var volumeRows: [Row] { sections[1].rows }

    private func section(of item: Any?) -> Section? {
        var it = item
        while let current = it {
            if let s = current as? Section { return s }
            it = outline.parent(forItem: current)
        }
        return nil
    }

    // MARK: Drag: folders onto Favourites add them; anything onto the Drop Stack adds it.

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let row = item as? Row else { return nil }
        return URL(fileURLWithPath: row.path) as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let section = section(of: item), section === sections[0] || section === sections[3] else { return [] }
        if info.draggingSource as AnyObject? === outlineView { return [] }
        outlineView.setDropItem(section, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .link
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard let section = item as? Section, !urls.isEmpty else { return false }
        if section === sections[0] {
            AppDelegate.shared.addFavourites(urls.map(\.path).filter { p in
                var d: ObjCBool = false
                return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
            })
        } else {
            AppDelegate.shared.addToStack(urls.map(\.path))
        }
        return true
    }
}

extension SidebarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = outline.item(atRow: outline.clickedRow) as? Row else { return }
        func add(_ title: String, _ handler: @escaping () -> Void) {
            let it = ClosureMenuItem(title: title, handler: handler)
            menu.addItem(it)
        }
        add("Open") { [weak self] in self?.open(row) }
        add("Open in Other Pane") { [weak self] in
            guard let self else { return }
            self.window.otherPane.navigate(to: row.path)
        }
        add("Reveal in Finder") { [weak self] in self?.window.revealInFinder([row.path]) }
        switch row.kind {
        case .favourite:
            add("Remove from Favourites") { AppDelegate.shared.removeFavourite(row.path) }
        case .branch:
            add("Add to Favourites") { AppDelegate.shared.addFavourites([row.path]) }
        case .volume:
            add("Add to Favourites") { AppDelegate.shared.addFavourites([row.path]) }
            add("Eject") { [weak self] in self?.window.eject(row.path) }
        case .stack:
            add("Remove from Drop Stack") { AppDelegate.shared.removeFromStack([row.path]) }
        case .recent:
            add("Add to Favourites") { AppDelegate.shared.addFavourites([row.path]) }
        }
    }
}

/// A sidebar row: chevron, icon, name, then free space and an eject button at the right edge.
/// Laid out from its own bounds: the cell starts at width 0 and grows to the column.
/// The sidebar's selection, drawn like the file list's: red while the sidebar has the keyboard, grey when not.
/// Its corners follow settings.json "cornerRadius" (the system's source list selection is always rounded).
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        (isEmphasized ? Theme.accentFill : Theme.selectionInactive).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: Theme.radius(), yRadius: Theme.radius()).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }
}

final class SidebarCell: NSTableCellView {
    let icon = NSImageView()
    let name = label("", size: SidebarMetrics.font, color: Theme.fg)
    var level = 0
    /// Favourites reserve room for a chevron on every row.
    var chevronColumn = false
    var chevron: NSButton? { didSet { if let chevron { addSubview(chevron) } } }
    var detail: NSTextField? { didSet { if let detail { addSubview(detail) } } }
    var eject: NSButton? { didSet { if let eject { addSubview(eject) } } }

    init() {
        super.init(frame: .zero)
        name.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        addSubview(name)
        textField = name
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The colours set by the sidebar, kept while the row is selected in red.
    private var normal: (name: NSColor?, detail: NSColor?, tint: NSColor?)?

    /// White text and icon on the red selection.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            if backgroundStyle == .emphasized {
                if normal == nil { normal = (name.textColor, detail?.textColor, icon.contentTintColor) }
                name.textColor = .white
                detail?.textColor = .white
                if normal?.tint != nil { icon.contentTintColor = .white }
            } else if let n = normal {
                name.textColor = n.name
                detail?.textColor = n.detail
                icon.contentTintColor = n.tint
                normal = nil
            }
        }
    }

    func setExpanded(_ expanded: Bool) {
        chevron?.image = Icons.symbol(expanded ? "chevron.down" : "chevron.right")
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let s = SidebarMetrics.icon
        var right = w - 8
        if let eject {
            eject.frame = NSRect(x: right - 20, y: ((h - 20) / 2).rounded(), width: 20, height: 20)
            right -= 24
        }
        if let detail {
            let dw = textWidth(detail.stringValue, font: detail.font!) + 4
            let dh = ceil(detail.font!.boundingRectForFont.height)
            detail.frame = NSRect(x: right - dw, y: ((h - dh) / 2).rounded(), width: dw, height: dh)
            right -= dw + 6
        }
        var x = 10 + CGFloat(level) * SidebarMetrics.indent
        if chevronColumn {
            chevron?.frame = NSRect(x: x - 2, y: ((h - 16) / 2).rounded(), width: 16, height: 16)
            x += 16
        }
        icon.frame = NSRect(x: x, y: ((h - s) / 2).rounded(), width: s, height: s)
        x += s + 8
        let nh = ceil(name.font!.ascender - name.font!.descender) + 2
        name.frame = NSRect(x: x, y: ((h - nh) / 2).rounded(), width: max(20, right - x), height: nh)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
