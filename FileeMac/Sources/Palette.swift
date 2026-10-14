import AppKit
import FileeCore

/// ⌘K: 1 box for commands, actions, favourites, recent folders and the current folder's items (SPEC 4.3).
final class PaletteController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode {
        case commands
        /// Pick a folder for a copy or move (F5/F6 with 1 pane shown).
        case folderTarget(Transfer.Mode, [String])
    }

    struct Entry {
        enum Kind { case command, action, folder, item }
        let kind: Kind
        let title: String
        let detail: String
        let id: String
        let args: String?
        let path: String?
    }

    unowned let window: BrowserWindowController
    private let panel: NSPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var entries: [Entry] = []
    private var shown: [Entry] = []
    private var mode: Mode = .commands

    init(window: BrowserWindowController) {
        self.window = window
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.backgroundColor = Theme.surface
        let content = FlippedView()
        panel.contentView = content
        let background = ColorView(Theme.surface)
        background.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        content.addSubview(background)
        field.placeholderString = "Type a command, folder or file…"
        field.font = Theme.ui(16)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        let col = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        col.resizingMask = .autoresizingMask
        table.backgroundColor = Theme.surface
        table.style = .plain
        table.target = self
        table.doubleAction = #selector(runSelected)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let line = ColorView(Theme.line)
        content.addSubview(field)
        content.addSubview(line)
        content.addSubview(scroll)
        field.frame = NSRect(x: 16, y: 14, width: 608, height: 24)
        line.frame = NSRect(x: 0, y: 48, width: 640, height: 1)
        scroll.frame = NSRect(x: 0, y: 50, width: 640, height: 370)
        // The column takes the scroll view's width: the shortcuts sit flush right, inside the panel.
        table.sizeLastColumnToFit()
    }

    var isVisible: Bool { panel.isVisible }
    var contentView: NSView? { panel.contentView }

    /// For QA: every shown row's shortcut sits inside the panel's visible width.
    var shortcutsFit: Bool {
        table.layoutSubtreeIfNeeded()
        let visible = scroll.contentView.documentVisibleRect
        let rows = table.rows(in: visible)
        guard rows.length > 0 else { return false }
        for r in rows.location..<(rows.location + rows.length) {
            guard let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false),
                  let d = cell.subviews.compactMap({ $0 as? NSTextField }).last, !d.stringValue.isEmpty else { continue }
            let f = d.convert(d.bounds, to: scroll.contentView)
            if f.maxX > visible.maxX || textWidth(d.stringValue, font: d.font!) > f.width { return false }
        }
        return true
    }

    func show(mode: Mode) {
        self.mode = mode
        field.stringValue = ""
        switch mode {
        case .commands:
            field.placeholderString = "Type a command, folder or file…"
        case .folderTarget(let m, let paths):
            field.placeholderString = "\(m == .copy ? "Copy" : "Move") \(Format.items(paths.count)) to… (type a folder)"
        }
        entries = buildEntries()
        filter()
        guard let w = window.window else { return }
        let f = w.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - 320, y: f.maxY - 140 - 420))
        w.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        window.window?.makeKeyAndOrderFront(nil)
    }

    private func buildEntries() -> [Entry] {
        var out: [Entry] = []
        if case .commands = mode {
            var seen = Set<String>()
            for c in CommandCatalog.all {
                let key = c.id + (c.args ?? "")
                guard seen.insert(key).inserted else { continue }
                let b = Keymap.shared.binding(for: c.id, args: c.args)
                out.append(Entry(kind: .command, title: c.title, detail: b?.symbols ?? "", id: c.id, args: c.args, path: nil))
            }
            for a in ActionRunner.shared.actions(for: window.activePane.selectedItems) {
                out.append(Entry(kind: .action, title: a.name, detail: "action", id: "action:" + a.name, args: a.name, path: nil))
            }
        }
        var folders: [(String, String)] = Theme.settings.favourites.map { ($0.name, $0.path.expandingHome) }
        for (letter, p) in Theme.settings.jumps { folders.append(("Jump \(letter.uppercased())", p.expandingHome)) }
        for p in AppDelegate.shared.state.recent { folders.append(((p as NSString).lastPathComponent, p.expandingHome)) }
        var seenPaths = Set<String>()
        for (name, p) in folders where seenPaths.insert(p).inserted {
            out.append(Entry(kind: .folder, title: name, detail: p.abbreviatingHome, id: "go", args: p, path: p))
        }
        for it in window.activePane.folderModel.visible.prefix(5000) {
            if case .folderTarget = mode, !it.isFolder { continue }
            out.append(Entry(kind: .item, title: it.name, detail: it.isFolder ? "folder here" : "", id: it.isFolder ? "go" : "reveal", args: it.path, path: it.path))
        }
        return out
    }

    private func filter() {
        let q = field.stringValue
        if q.hasPrefix("/") || q.hasPrefix("~") {
            // A typed path: offer it directly.
            let full = q.expandingHome
            shown = [Entry(kind: .folder, title: q, detail: "go to this path", id: "go", args: full, path: full)]
        } else {
            let idx = Fuzzy.filter(entries, query: q) { $0.title }
            shown = idx.prefix(200).map { entries[$0] }
        }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    /// For QA: the panel's window, and a typed query without key presses.
    var qaPanel: NSWindow { panel }
    func qaType(_ text: String) {
        field.stringValue = text
        filter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            move(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            runSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func move(_ d: Int) {
        guard !shown.isEmpty else { return }
        let r = max(0, min(shown.count - 1, table.selectedRow + d))
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    @objc private func runSelected() {
        let r = table.selectedRow
        guard r >= 0, r < shown.count else { return }
        let e = shown[r]
        close()
        if case .folderTarget(let m, let paths) = mode {
            guard let target = e.path else { return }
            OperationCenter.shared.transfer(m, paths, into: target) { [weak window] res in window?.selectInPanes(res) }
            return
        }
        switch e.id {
        case "reveal":
            if let p = e.path { window.activePane.fileView.select(paths: [p], scroll: true) }
        default:
            window.perform(e.id, args: e.args)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = shown[row]
        let cell = tableView.makeView(withIdentifier: PaletteCell.id, owner: nil) as? PaletteCell ?? PaletteCell()
        let symbol: String
        switch e.kind {
        case .command: symbol = "command"
        case .action: symbol = "bolt"
        case .folder: symbol = "folder"
        case .item: symbol = e.detail.isEmpty ? "doc" : "folder"
        }
        cell.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cell.icon.contentTintColor = e.kind == .action ? Theme.accent : Theme.muted
        cell.title.stringValue = e.title
        cell.show(detail: e.detail, asKey: e.kind == .command)
        return cell
    }
}

/// A palette row: icon, title, and the shortcut (as a key cap) or the path flush right. Laid out from its own width,
/// so the shortcut never runs past the panel's edge.
private final class PaletteCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("paletteRow")
    let icon = NSImageView()
    let title = label("", size: 13.5, color: Theme.fg)
    let detail = label("", size: 12, color: Theme.muted)
    /// The key cap behind a shortcut.
    private let cap = NSView()
    private var isKey = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        title.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 4
        for v in [icon, title, cap, detail] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(detail text: String, asKey: Bool) {
        isKey = asKey && !text.isEmpty
        detail.stringValue = text
        detail.font = isKey ? Theme.ui(12, weight: .medium) : Theme.ui(12)
        detail.alignment = isKey ? .center : .right
        cap.isHidden = !isKey
        cap.layer?.backgroundColor = Theme.surface2.cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height, pad: CGFloat = 16
        icon.frame = NSRect(x: pad, y: ((h - 16) / 2).rounded(), width: 16, height: 16)
        var dw: CGFloat = 0
        if !detail.stringValue.isEmpty {
            dw = min(textWidth(detail.stringValue, font: detail.font!) + (isKey ? 14 : 8), (bounds.width * 0.45).rounded())
        }
        let dh = detail.intrinsicContentSize.height
        detail.frame = NSRect(x: bounds.width - pad - dw, y: ((h - dh) / 2).rounded(), width: dw, height: dh)
        cap.frame = NSRect(x: detail.frame.minX, y: ((h - 20) / 2).rounded(), width: dw, height: 20)
        let x = icon.frame.maxX + 10
        let th = title.intrinsicContentSize.height
        title.frame = NSRect(x: x, y: ((h - th) / 2).rounded(), width: max(0, detail.frame.minX - 12 - x), height: th)
    }
}
