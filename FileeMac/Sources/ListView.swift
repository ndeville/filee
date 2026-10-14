import AppKit
import FileeCore

/// 1 row of the tree list. Children load when the row expands.
final class ListNode {
    var item: FileItem
    var children: [ListNode]?
    weak var parent: ListNode?
    var watchID: UUID?

    init(_ item: FileItem, parent: ListNode?) {
        self.item = item
        self.parent = parent
    }
}

/// The outline view: key handling goes to the pane first.
final class FileOutlineView: NSOutlineView {
    weak var fileDelegate: FileViewDelegate?
    var activePane = true

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isDisjoint(with: [.command, .control]) {
            switch Int(event.keyCode) {
            case 53: if fileDelegate?.fileViewEscape() == true { return }
            case 51: if fileDelegate?.fileViewBackspace() == true { return }
            case 123, 124, 125, 126, 115, 119, 116, 121: break
            default:
                if let chars = event.characters, let c = chars.unicodeScalars.first,
                   !CharacterSet.controlCharacters.contains(c), c.value < 0xF700,
                   fileDelegate?.fileView(typed: chars) == true { return }
            }
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { fileDelegate?.fileViewBecameFocused() }
        return ok
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let items = selectedRowIndexes.compactMap { (item(atRow: $0) as? ListNode)?.item }
        return fileDelegate?.fileViewMenu(for: row >= 0 ? items : [])
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    // Never start an edit on its own (Return opens, ⌘R renames).
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSTextField, event?.type == .leftMouseDown { return false }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

/// The tree list (⌘5): columns size themselves to their content on every load.
final class ListView: NSObject, FileView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    let scroll = NSScrollView()
    let outline = FileOutlineView()
    weak var delegate: FileViewDelegate?
    private var roots: [ListNode] = []
    private var columns: [ListColumn] = []
    private var dayStart = startOfDay()
    private var editingNode: ListNode?
    /// A reload that came during an inline rename: it runs when the rename ends.
    private var deferredReload = false
    private var restoringExpansion = false
    private var expandedPaths = Set<String>()

    init(delegate: FileViewDelegate) {
        self.delegate = delegate
        super.init()
        outline.fileDelegate = delegate
        outline.dataSource = self
        outline.delegate = self
        outline.headerView = NSTableHeaderView()
        outline.allowsMultipleSelection = true
        outline.allowsTypeSelect = false
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = Theme.bg
        outline.gridStyleMask = []
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.bg
        scroll.borderType = .noBorder
        buildColumns()
        styleChanged()
        // Pane resized: the columns fit again.
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
            guard let self, abs(self.scroll.frame.width - self.lastWidth) > 1 else { return }
            self.lastWidth = self.scroll.frame.width
            self.autosize()
        }
    }

    private var lastWidth: CGFloat = 0

    var root: NSView { scroll }
    var focusTarget: NSView { outline }
    var model: FolderModel? { delegate?.folderModel }

    func buildColumns() {
        var ids = Theme.settings.columns.compactMap { ListColumn(rawValue: $0) }
        if !ids.contains(.name) { ids.insert(.name, at: 0) }
        if ids == columns, !outline.tableColumns.isEmpty { return }
        // The outline column can't be removed: the new ones go in first, then the old ones out.
        let old = outline.tableColumns
        columns = ids
        for c in ids {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.rawValue))
            col.title = c.title
            col.minWidth = 40
            col.maxWidth = 4000
            col.resizingMask = .userResizingMask
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.rawValue, ascending: c == .name)
            if c.alignRight { col.headerCell.alignment = .right }
            outline.addTableColumn(col)
            if c == .name { outline.outlineTableColumn = col }
        }
        for c in old { outline.removeTableColumn(c) }
        outline.headerView?.menu = headerMenu()
    }

    private func headerMenu() -> NSMenu {
        let m = NSMenu()
        for c in ListColumn.allCases where c != .name {
            let it = NSMenuItem(title: c.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.rawValue
            it.state = columns.contains(c) ? .on : .off
            m.addItem(it)
        }
        return m
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var cols = Theme.settings.columns
        if cols.contains(id) { cols.removeAll { $0 == id } } else { cols.append(id) }
        Theme.settings.columns = cols
        AppDelegate.shared.saveColumns(cols)
    }

    func styleChanged() {
        outline.rowHeight = Theme.rowHeight
        outline.backgroundColor = Theme.bg
        buildColumns()
        outline.reloadData()
        autosize()
    }

    func activeChanged(_ active: Bool) {
        outline.activePane = active
        outline.enumerateAvailableRowViews { rv, _ in
            (rv as? FileRowView)?.activePane = active
            rv.needsDisplay = true
            for i in 0..<rv.numberOfColumns { (rv.view(atColumn: i) as? NSTableCellView)?.backgroundStyle = rv.interiorBackgroundStyle }
        }
    }

    // MARK: Model

    /// Nodes by path, kept across filter keystrokes so a filter never rebuilds 10,000 nodes.
    private var nodeCache: [String: ListNode] = [:]
    private var cachedFolder = ""

    func modelChanged(reloaded: Bool) {
        guard let model else { return }
        // A reload removes the row views, and the rename field with them: AppKit ended the edit inside reloadData,
        // the rename reloaded the list again inside that update, and AppKit threw (crash of 13th October 2026).
        // Same folder: the reload waits for the rename. Another folder: the rename is cancelled.
        if editingNode != nil {
            if model.path == cachedFolder {
                deferredReload = true
                return
            }
            cancelInlineRename()
        }
        deferredReload = false
        var t0 = Profile.now
        let selected = selectedItems.map(\.path)
        if model.path != cachedFolder {
            for n in nodeCache.values { unwatch(n) }
            nodeCache = [:]
            expandedPaths = []
            cachedFolder = model.path
        }
        if reloaded { dayStart = startOfDay() }
        roots = model.visible.map { item in
            if let old = nodeCache[item.path], old.item.kind == item.kind {
                if reloaded { old.item = item }
                return old
            }
            let n = ListNode(item, parent: nil)
            nodeCache[item.path] = n
            return n
        }
        if reloaded {
            // Expanded rows keep their children, refreshed from disk. Items gone from disk leave the cache.
            for node in roots where node.children != nil { node.children = loadChildren(of: node) }
            if model.query.isEmpty {
                let present = Set(model.visible.map(\.path))
                for (path, node) in nodeCache where !present.contains(path) {
                    unwatch(node)
                    expandedPaths.remove(path)
                    nodeCache.removeValue(forKey: path)
                }
            }
        }
        var t = Profile.mark("nodes", t0)
        outline.reloadData()
        t = Profile.mark("reloadData", t)
        restoringExpansion = true
        restoreExpansion(roots)
        restoringExpansion = false
        // Columns fit when the folder loads or changes on disk; a filter keystroke keeps them.
        if reloaded || model.query.isEmpty { autosize() }
        t = Profile.mark("autosize", t)
        t0 = t
        if !model.query.isEmpty, let best = model.bestMatch {
            selectVisible(best)
        } else if !selected.isEmpty {
            select(paths: selected, scroll: false)
        }
        Profile.mark("select", t0)
    }

    private func restoreExpansion(_ nodes: [ListNode]) {
        for n in nodes where expandedPaths.contains(n.item.path) {
            outline.expandItem(n)
            if let c = n.children { restoreExpansion(c) }
        }
    }

    private func loadChildren(of node: ListNode) -> [ListNode] {
        guard let delegate, let model else { return [] }
        var items = delegate.listing(of: node.item.path)
        if !model.showHidden { items.removeAll { $0.isHidden } }
        if model.types != .all { items.removeAll { !model.types.matches($0) } }
        items = FolderModel.sortItems(items, key: model.sortKey, ascending: model.ascending, sizes: model.folderSizes)
        let old = Dictionary((node.children ?? []).map { ($0.item.path, $0) }, uniquingKeysWith: { a, _ in a })
        return items.map { item in
            if let o = old[item.path] {
                o.item = item
                if o.children != nil { o.children = loadChildren(of: o) }
                return o
            }
            return ListNode(item, parent: node)
        }
    }

    private func unwatch(_ node: ListNode) {
        FolderWatch.shared.unsubscribe(node.watchID)
        node.watchID = nil
        for c in node.children ?? [] { unwatch(c) }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ListNode else { return roots.count }
        if node.children == nil { node.children = loadChildren(of: node) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? ListNode else { return roots[index] }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ListNode)?.item.isFolder ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rv = FileRowView()
        rv.activePane = outline.activePane
        return rv
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ListNode, let id = tableColumn?.identifier, let col = ListColumn(rawValue: id.rawValue) else { return nil }
        let it = node.item
        if col == .name {
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NameCellView) ?? {
                let c = NameCellView()
                c.identifier = id
                return c
            }()
            cell.name.stringValue = it.name
            cell.name.font = Theme.listFont(bold: it.isFolder, italic: it.kind == .symlink)
            cell.name.textColor = Theme.fg
            cell.name.isEditable = false
            cell.name.delegate = self
            cell.icon.image = Icons.icon(for: it)
            cell.icon.alphaValue = it.isHidden ? 0.5 : 1
            cell.dot.isHidden = !(Theme.settings.newTodayMarker && it.isNew(since: dayStart))
            return cell
        }
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? TextCellView) ?? {
            let c = TextCellView()
            c.identifier = id
            return c
        }()
        cell.alignRight = col.alignRight
        cell.text.font = Theme.listFont(size: max(9, Theme.listSize - 1))
        cell.text.textColor = Theme.muted
        cell.text.stringValue = col.text(it, size: model?.size(of: it) ?? -1)
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ListNode else { return }
        expandedPaths.insert(node.item.path)
        if node.watchID == nil {
            node.watchID = FolderWatch.shared.subscribe(node.item.path) { [weak self, weak node] in
                guard let self, let node, node.children != nil else { return }
                guard self.editingNode == nil else {
                    self.deferredReload = true
                    return
                }
                node.children = self.loadChildren(of: node)
                let selected = Set(self.selectedItems.map(\.path))
                self.outline.reloadItem(node, reloadChildren: true)
                self.select(paths: Array(selected), scroll: false)
            }
        }
        if !restoringExpansion { autosize() }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ListNode else { return }
        expandedPaths.remove(node.item.path)
        unwatch(node)
        node.children = nil
        autosize()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        delegate?.fileViewSelectionChanged()
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sd = outlineView.sortDescriptors.first, let key = sd.key, let model else { return }
        model.sortKey = SortKey(rawValue: key) ?? .name
        model.ascending = sd.ascending
        AppDelegate.shared.rememberSort(for: model.path, key: model.sortKey, ascending: model.ascending)
        model.resort()
    }

    // MARK: Auto-size (SPEC 3.3)

    /// Every column fits its content. The name column takes the longest name, up to what the others leave.
    func autosize() {
        guard let model else { return }
        let small = Theme.listFont(size: max(9, Theme.listSize - 1))
        let bold = Theme.listFont(bold: true)
        let regular = Theme.listFont()
        // Rows with their depth. Big folders: the top level only (children rarely hold the longest name).
        var rows: [(FileItem, Int)] = []
        if outline.numberOfRows <= 3000 {
            for r in 0..<outline.numberOfRows {
                if let n = outline.item(atRow: r) as? ListNode { rows.append((n.item, outline.level(forRow: r))) }
            }
        } else {
            rows = roots.map { ($0.item, 0) }
        }
        // Dates, sizes and kinds have few distinct widths: a sample of 300 rows, plus every kind, is enough.
        let stride = max(1, rows.count / 300)
        let sample = Swift.stride(from: 0, to: rows.count, by: stride).map { rows[$0].0 }
        var widths: [ListColumn: CGFloat] = [:]
        let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        for c in columns {
            var w = textWidth(c.title, font: headerFont) + 24
            switch c {
            case .name:
                let iconSpace = 11 + min(18, (Theme.listSize * 1.3).rounded()) + 6 + 10
                // Measure the longest names only: the 150 longest by character count.
                let candidates = rows.map { ($0, $0.0.name.utf16.count + $0.1 * 3) }.sorted { $0.1 > $1.1 }.prefix(150)
                for ((it, level), _) in candidates {
                    w = max(w, textWidth(it.name, font: it.isFolder ? bold : regular) + iconSpace + CGFloat(level) * outline.indentationPerLevel + 16)
                }
            case .kind:
                var kinds = Set<String>()
                var exts = Set<String>()
                for (it, _) in rows where exts.insert(it.isFolder ? "/" : it.ext).inserted { kinds.insert(Format.kind(it)) }
                for k in kinds { w = max(w, textWidth(k, font: small) + 14) }
            default:
                var seen = Set<String>()
                for it in sample {
                    let t = c.text(it, size: model.size(of: it))
                    if seen.insert(t).inserted { w = max(w, textWidth(t, font: small) + 14) }
                }
                if c == .size, let big = rows.max(by: { model.size(of: $0.0) < model.size(of: $1.0) }) {
                    w = max(w, textWidth(c.text(big.0, size: model.size(of: big.0)), font: small) + 14)
                }
            }
            widths[c] = ceil(w)
        }
        let available = scroll.contentSize.width
        let others = columns.filter { $0 != .name }.reduce(CGFloat(0)) { $0 + (widths[$1] ?? 60) }
        if var nameW = widths[.name] {
            nameW = max(160, min(nameW, available - others))
            widths[.name] = nameW
        }
        for col in outline.tableColumns {
            if let c = ListColumn(rawValue: col.identifier.rawValue), let w = widths[c] { col.width = w }
        }
        // The last column takes any space left, so the header line runs to the edge.
        let total = outline.tableColumns.reduce(CGFloat(0)) { $0 + $1.width }
        if total < available, let last = outline.tableColumns.last { last.width += available - total }
    }

    // MARK: Selection

    var selectedItems: [FileItem] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? ListNode)?.item }
    }

    func select(paths: [String], scroll doScroll: Bool) {
        var rows = IndexSet()
        var missing: Set<String> = []
        for p in paths {
            if let n = nodeCache[p], outline.row(forItem: n) >= 0 { rows.insert(outline.row(forItem: n)) } else { missing.insert(p) }
        }
        // Children of expanded folders aren't in the cache: scan the rows only for those.
        if !missing.isEmpty {
            for r in 0..<outline.numberOfRows {
                if let n = outline.item(atRow: r) as? ListNode, missing.contains(n.item.path) { rows.insert(r) }
            }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if doScroll, let first = rows.first { outline.scrollRowToVisible(first) }
    }

    func selectVisible(_ index: Int) {
        guard index >= 0, index < roots.count else { return }
        let row = outline.row(forItem: roots[index])
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    func selectLast() {
        let row = outline.numberOfRows - 1
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    var targetFolder: String {
        model?.path ?? NSHomeDirectory()
    }

    func expandSelected(_ expand: Bool) -> Bool {
        let nodes = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? ListNode }
        guard !nodes.isEmpty else { return false }
        for n in nodes where n.item.isFolder {
            if expand { outline.expandItem(n) } else { outline.collapseItem(n) }
        }
        return true
    }

    func expandAll(_ expand: Bool) -> Bool {
        let nodes = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? ListNode }
        let selected = selectedItems.map(\.path)
        if expand {
            // 1 level per call: a whole tree at once can mean 1,000s of folders, each with its own watch.
            let closed = nodes.filter { $0.item.isFolder && !outline.isItemExpanded($0) }
            guard !closed.isEmpty else { return false }
            restoringExpansion = true
            for n in closed { outline.expandItem(n) }
            restoringExpansion = false
            autosize()
        } else {
            let open = roots.filter { outline.isItemExpanded($0) }
            guard !open.isEmpty else { return false }
            for n in open { outline.collapseItem(n) }
            expandedPaths = []
            // A selected row inside a closed folder selects its top folder instead.
            let rootPaths = Set(roots.map(\.item.path))
            let tops = selected.map { path in rootPaths.first { path == $0 || path.hasPrefix($0 + "/") } ?? path }
            select(paths: Array(Set(tops)), scroll: true)
            return true
        }
        select(paths: selected, scroll: false)
        return true
    }

    func screenFrame(of path: String) -> NSRect? {
        for r in 0..<outline.numberOfRows {
            guard let n = outline.item(atRow: r) as? ListNode, n.item.path == path else { continue }
            guard let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: false) as? NameCellView,
                  let window = outline.window else { return nil }
            let rect = cell.convert(cell.icon.frame, to: nil)
            return window.convertToScreen(rect)
        }
        return nil
    }

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? ListNode else { return }
        delegate?.fileView(open: n.item)
    }

    // MARK: Inline rename

    var isRenaming: Bool { editingNode != nil }

    func beginInlineRename() -> Bool {
        let rows = outline.selectedRowIndexes
        guard rows.count == 1, let row = rows.first, let node = outline.item(atRow: row) as? ListNode,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCellView else { return false }
        outline.scrollRowToVisible(row)
        editingNode = node
        cell.name.isEditable = true
        cell.name.isSelectable = true
        cell.name.textColor = Theme.fg
        outline.window?.makeFirstResponder(cell.name)
        if let editor = cell.name.currentEditor() {
            let stem = node.item.isFolder ? node.item.name : node.item.stem
            editor.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        }
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if let node = editingNode { (control as? NSTextField)?.stringValue = node.item.name }
            editingNode = nil
            endEditing(control)
            runDeferredReload()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let node = editingNode
        editingNode = nil
        endEditing(field)
        guard let node else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newName.isEmpty || newName == node.item.name {
            field.stringValue = node.item.name
            runDeferredReload()
            return
        }
        // The rename reloads the list: never inside an AppKit table update that ended this edit.
        DispatchQueue.main.async { [weak self] in self?.delegate?.fileView(rename: node.item, to: newName) }
        runDeferredReload()
    }

    /// After the rename: the reload it held back, unless the rename's own reload already ran.
    private func runDeferredReload() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.deferredReload, self.editingNode == nil else { return }
            self.modelChanged(reloaded: true)
        }
    }

    private func cancelInlineRename() {
        guard let node = editingNode else { return }
        editingNode = nil
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCellView else { return }
        cell.name.abortEditing()
        cell.name.stringValue = node.item.name
        endEditing(cell.name)
    }

    private func endEditing(_ control: NSControl) {
        guard let field = control as? NSTextField else { return }
        field.isEditable = false
        field.isSelectable = false
        outline.window?.makeFirstResponder(outline)
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? ListNode)?.item.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        var target = item as? ListNode
        if let t = target, !t.item.isFolder { target = t.parent }
        // Dropping between rows or on a file: the folder that holds them.
        if target == nil {
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else if index != NSOutlineViewDropOnItemIndex || target !== (item as? ListNode) {
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        let folder = target?.item.path ?? targetFolder
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        if urls.contains(where: { $0.path == folder || ($0.deletingLastPathComponent().path == folder && info.draggingSource as AnyObject? === outlineView) }) { return [] }
        return dragOperation(info, into: folder, urls: urls)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let folder = (item as? ListNode)?.item.path ?? targetFolder
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        let op = dragOperation(info, into: folder, urls: urls)
        return delegate?.fileView(drop: urls, into: folder, copy: op == .copy) ?? false
    }
}

/// Copy across volumes, move on the same volume. ⌥ forces a copy, ⌘ a move (Finder's rules).
func dragOperation(_ info: NSDraggingInfo, into folder: String, urls: [URL]) -> NSDragOperation {
    guard !urls.isEmpty else { return [] }
    let mask = info.draggingSourceOperationMask
    let flags = NSEvent.modifierFlags
    if flags.contains(.option), mask.contains(.copy) { return .copy }
    if flags.contains(.command), mask.contains(.move) { return .move }
    let same = urls.allSatisfy { FileOps.sameVolume($0.path, folder) }
    if same, mask.contains(.move) || mask.contains(.generic) { return .move }
    return mask.contains(.copy) ? .copy : []
}
