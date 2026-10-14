import AppKit
import FileeCore

/// 1 column's table: keys go to the columns view first.
final class ColumnTableView: NSTableView {
    weak var owner: ColumnsView?
    var column = 0
    var activePane = true

    override func keyDown(with event: NSEvent) {
        if owner?.handleKey(event, from: self) == true { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { owner?.focusChanged(to: column) }
        return ok
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        if r >= 0, !selectedRowIndexes.contains(r) { selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false) }
        window?.makeFirstResponder(self)
        return owner?.menu(column: column, clickedRow: r)
    }
}

/// Miller columns (⌘4). Column 0 shows the pane's folder; a selected folder opens the next column.
/// Every column is as wide as its longest name (SPEC 3.3).
final class ColumnsView: NSObject, FileView, NSTableViewDataSource, NSTableViewDelegate {
    final class Column {
        let folder: String
        var items: [FileItem]
        let scroll = NSScrollView()
        let table = ColumnTableView()
        var watchID: UUID?
        var width: CGFloat = 220
        init(folder: String, items: [FileItem]) {
            self.folder = folder
            self.items = items
        }
    }

    let scroll = NSScrollView()
    let strip = FlippedView()
    weak var delegate: FileViewDelegate?
    private var columns: [Column] = []
    private var focused = 0
    private var dayStart = startOfDay()
    private var activePane = true
    private var updating = false

    init(delegate: FileViewDelegate) {
        self.delegate = delegate
        super.init()
        scroll.documentView = strip
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.bg
        scroll.borderType = .noBorder
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
            self?.layoutColumns()
        }
    }

    var root: NSView { scroll }
    var focusTarget: NSView { columns.indices.contains(focused) ? columns[focused].table : scroll }

    // MARK: Model

    func modelChanged(reloaded: Bool) {
        guard let model = delegate?.folderModel else { return }
        if reloaded { dayStart = startOfDay() }
        let keepPath = selectedItems.map(\.path)
        if columns.first?.folder != model.path {
            clear()
            makeColumn(folder: model.path, items: model.visible)
            focused = 0
        } else {
            columns[0].items = model.visible
            columns[0].table.reloadData()
            // Deeper columns: their folders may be gone.
            refreshDeeper()
        }
        layoutColumns()
        if !model.query.isEmpty, let best = model.bestMatch {
            selectVisible(best)
        } else if !keepPath.isEmpty, focused == 0 {
            select(paths: keepPath, scroll: false)
        }
    }

    private func clear() {
        for c in columns {
            FolderWatch.shared.unsubscribe(c.watchID)
            c.scroll.removeFromSuperview()
        }
        columns = []
    }

    /// Builds a column and appends it (the data source finds it by index, so it must be in `columns` first).
    @discardableResult
    private func makeColumn(folder: String, items: [FileItem]) -> Column {
        let c = Column(folder: folder, items: items)
        let col = NSTableColumn(identifier: .init("name"))
        c.table.addTableColumn(col)
        c.table.headerView = nil
        c.table.owner = self
        c.table.column = columns.count
        c.table.dataSource = self
        c.table.delegate = self
        c.table.rowHeight = Theme.rowHeight
        c.table.intercellSpacing = .zero
        c.table.allowsMultipleSelection = true
        c.table.allowsTypeSelect = false
        c.table.backgroundColor = Theme.bg
        c.table.style = .plain
        c.table.target = self
        c.table.doubleAction = #selector(doubleClicked(_:))
        c.table.registerForDraggedTypes([.fileURL])
        c.table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        c.table.activePane = activePane
        c.scroll.documentView = c.table
        c.scroll.hasVerticalScroller = true
        c.scroll.autohidesScrollers = true
        c.scroll.borderType = .noBorder
        c.scroll.drawsBackground = true
        c.scroll.backgroundColor = Theme.bg
        strip.addSubview(c.scroll)
        if columns.count > 0 {
            // Column 0 follows the pane's model, which watches its folder already.
            c.watchID = FolderWatch.shared.subscribe(folder) { [weak self, weak c] in
                guard let self, let c else { return }
                self.reloadColumn(c)
            }
        }
        c.width = measure(c)
        columns.append(c)
        c.table.reloadData()
        return c
    }

    private func reloadColumn(_ c: Column) {
        guard let model = delegate?.folderModel, let i = columns.firstIndex(where: { $0 === c }) else { return }
        let selected = c.table.selectedRowIndexes.compactMap { $0 < c.items.count ? c.items[$0].path : nil }
        c.items = sorted(delegate?.listing(of: c.folder) ?? [], model: model)
        c.table.reloadData()
        reselect(c, selected)
        c.width = measure(c)
        if i == columns.count - 1 || true { layoutColumns() }
    }

    private func refreshDeeper() {
        for c in columns.dropFirst() { reloadColumn(c) }
        // A folder that vanished closes its column and those after it.
        for (i, c) in columns.enumerated() where i > 0 {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: c.folder, isDirectory: &isDir) || !isDir.boolValue {
                truncate(after: i - 1)
                break
            }
        }
    }

    private func sorted(_ items: [FileItem], model: FolderModel) -> [FileItem] {
        FolderModel.sortItems(items.filter { (model.showHidden || !$0.isHidden) && model.types.matches($0) }, key: model.sortKey, ascending: model.ascending, sizes: model.folderSizes)
    }

    private func reselect(_ c: Column, _ paths: [String]) {
        let set = Set(paths)
        let rows = IndexSet(c.items.indices.filter { set.contains(c.items[$0].path) })
        updating = true
        c.table.selectRowIndexes(rows, byExtendingSelection: false)
        updating = false
    }

    private func measure(_ c: Column) -> CGFloat {
        let bold = Theme.listFont(bold: true), regular = Theme.listFont()
        let longest = c.items.sorted { $0.name.count > $1.name.count }.prefix(120)
        var w: CGFloat = 140
        for it in longest { w = max(w, textWidth(it.name, font: it.isFolder ? bold : regular)) }
        let icon = min(18, (Theme.listSize * 1.3).rounded())
        return min(520, ceil(w + 11 + icon + 6 + 28))
    }

    private var separators: [ColorView] = []

    private func layoutColumns() {
        var x: CGFloat = 0
        let h = scroll.contentSize.height
        while separators.count < columns.count {
            let sep = ColorView(Theme.line)
            strip.addSubview(sep)
            separators.append(sep)
        }
        for (i, sep) in separators.enumerated() { sep.isHidden = i >= columns.count }
        for (i, c) in columns.enumerated() {
            c.table.column = i
            c.scroll.frame = NSRect(x: x, y: 0, width: c.width, height: h)
            c.table.tableColumns.first?.width = c.width - 2
            separators[i].frame = NSRect(x: x + c.width, y: 0, width: 1, height: h)
            x += c.width + 1
        }
        strip.frame = NSRect(x: 0, y: 0, width: max(x, scroll.contentSize.width), height: h)
        strip.needsDisplay = true
        if let last = columns.last {
            strip.scrollToVisible(last.scroll.frame)
        }
    }

    private func truncate(after index: Int) {
        while columns.count > index + 1 {
            let c = columns.removeLast()
            FolderWatch.shared.unsubscribe(c.watchID)
            c.scroll.removeFromSuperview()
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let t = tableView as? ColumnTableView, t.column < columns.count else { return 0 }
        return columns[t.column].items.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = FileRowView()
        rv.activePane = activePane && (tableView as? ColumnTableView)?.column == focused
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let t = tableView as? ColumnTableView, t.column < columns.count, row < columns[t.column].items.count else { return nil }
        let it = columns[t.column].items[row]
        let cell = (tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? NameCellView) ?? {
            let c = NameCellView()
            c.identifier = .init("cell")
            return c
        }()
        cell.name.stringValue = it.name
        cell.name.font = Theme.listFont(bold: it.isFolder, italic: it.kind == .symlink)
        cell.icon.image = Icons.icon(for: it)
        cell.icon.alphaValue = it.isHidden ? 0.5 : 1
        cell.dot.isHidden = !(Theme.settings.newTodayMarker && it.isNew(since: dayStart))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, let t = notification.object as? ColumnTableView, t.column < columns.count else { return }
        let c = columns[t.column]
        let rows = t.selectedRowIndexes
        truncate(after: t.column)
        if rows.count == 1, let r = rows.first, r < c.items.count, c.items[r].isFolder, let model = delegate?.folderModel {
            let folder = c.items[r].path
            makeColumn(folder: folder, items: sorted(delegate?.listing(of: folder) ?? [], model: model))
        }
        layoutColumns()
        delegate?.fileViewSelectionChanged()
    }

    @objc private func doubleClicked(_ sender: ColumnTableView) {
        let r = sender.clickedRow
        guard sender.column < columns.count, r >= 0, r < columns[sender.column].items.count else { return }
        let it = columns[sender.column].items[r]
        if !it.isFolder { delegate?.fileView(open: it) }
    }

    // MARK: Keys

    func handleKey(_ event: NSEvent, from table: ColumnTableView) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control]) else { return false }
        switch Int(event.keyCode) {
        case 123: // left
            guard table.column > 0 else { return true }
            let prev = columns[table.column - 1]
            focused = table.column - 1
            truncate(after: table.column)
            layoutColumns()
            table.window?.makeFirstResponder(prev.table)
            delegate?.fileViewSelectionChanged()
            return true
        case 124: // right
            return enterNext(from: table.column)
        case 53: return delegate?.fileViewEscape() ?? false
        case 51: return delegate?.fileViewBackspace() ?? false
        case 125, 126, 115, 119, 116, 121: return false
        default:
            // The filter acts on column 0 only.
            guard table.column == 0, let chars = event.characters, let c = chars.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(c), c.value < 0xF700 else { return false }
            return delegate?.fileView(typed: chars) ?? false
        }
    }

    @discardableResult
    private func enterNext(from column: Int) -> Bool {
        guard column + 1 < columns.count else { return true }
        let next = columns[column + 1]
        focused = column + 1
        next.table.window?.makeFirstResponder(next.table)
        if next.table.selectedRow < 0, !next.items.isEmpty {
            next.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        return true
    }

    func focusChanged(to column: Int) {
        focused = column
        refreshSelectionStyle()
        delegate?.fileViewBecameFocused()
        delegate?.fileViewSelectionChanged()
    }

    func menu(column: Int, clickedRow: Int) -> NSMenu? {
        focused = column
        return delegate?.fileViewMenu(for: clickedRow >= 0 ? selectedItems : [])
    }

    // MARK: FileView

    var selectedItems: [FileItem] {
        guard columns.indices.contains(focused) else { return [] }
        let c = columns[focused]
        return c.table.selectedRowIndexes.compactMap { $0 < c.items.count ? c.items[$0] : nil }
    }

    func select(paths: [String], scroll doScroll: Bool) {
        guard let first = paths.first else { return }
        let folder = (first as NSString).deletingLastPathComponent
        guard let i = columns.firstIndex(where: { $0.folder == folder }) else { return }
        let c = columns[i]
        focused = i
        reselect(c, paths)
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: c.table))
        if doScroll, let r = c.table.selectedRowIndexes.first { c.table.scrollRowToVisible(r) }
    }

    func selectVisible(_ index: Int) {
        guard let c = columns.first, index >= 0, index < c.items.count else { return }
        focused = 0
        c.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        c.table.scrollRowToVisible(index)
    }

    func selectLast() {
        guard columns.indices.contains(focused) else { return }
        let c = columns[focused]
        let row = c.items.count - 1
        guard row >= 0 else { return }
        c.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        c.table.scrollRowToVisible(row)
    }

    var targetFolder: String {
        guard columns.indices.contains(focused) else { return delegate?.folderModel.path ?? NSHomeDirectory() }
        return columns[focused].folder
    }

    func beginInlineRename() -> Bool { false }

    func styleChanged() {
        for c in columns {
            c.table.rowHeight = Theme.rowHeight
            c.width = measure(c)
            c.table.reloadData()
        }
        layoutColumns()
    }

    func activeChanged(_ active: Bool) {
        activePane = active
        refreshSelectionStyle()
    }

    /// Red selection in the focused column of the active pane, grey in the parent columns.
    private func refreshSelectionStyle() {
        for (i, c) in columns.enumerated() {
            let active = activePane && i == focused
            c.table.activePane = active
            c.table.enumerateAvailableRowViews { rv, _ in
                (rv as? FileRowView)?.activePane = active
                rv.needsDisplay = true
                for i in 0..<rv.numberOfColumns { (rv.view(atColumn: i) as? NSTableCellView)?.backgroundStyle = rv.interiorBackgroundStyle }
            }
        }
    }

    func screenFrame(of path: String) -> NSRect? {
        for c in columns {
            guard let r = c.items.firstIndex(where: { $0.path == path }),
                  let cell = c.table.view(atColumn: 0, row: r, makeIfNecessary: false) as? NameCellView,
                  let window = c.table.window else { continue }
            return window.convertToScreen(cell.convert(cell.icon.frame, to: nil))
        }
        return nil
    }

    func expandSelected(_ expand: Bool) -> Bool { false }
    func expandAll(_ expand: Bool) -> Bool { false }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let t = tableView as? ColumnTableView, t.column < columns.count, row < columns[t.column].items.count else { return nil }
        return columns[t.column].items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let t = tableView as? ColumnTableView, t.column < columns.count else { return [] }
        let c = columns[t.column]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        var folder = c.folder
        if op == .on, row < c.items.count, c.items[row].isFolder {
            folder = c.items[row].path
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        if urls.contains(where: { $0.path == folder }) { return [] }
        return dragOperation(info, into: folder, urls: urls)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let t = tableView as? ColumnTableView, t.column < columns.count else { return false }
        let c = columns[t.column]
        let folder = row >= 0 && row < c.items.count && c.items[row].isFolder ? c.items[row].path : c.folder
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return delegate?.fileView(drop: urls, into: folder, copy: dragOperation(info, into: folder, urls: urls) == .copy) ?? false
    }
}
