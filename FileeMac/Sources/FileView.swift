import AppKit
import FileeCore

/// What every view (list, columns, thumbnails) offers its pane.
protocol FileView: AnyObject {
    /// The view to place in the pane.
    var root: NSView { get }
    /// The view that takes keyboard focus.
    var focusTarget: NSView { get }
    /// Re-reads the pane's folder model. `reloaded`: the content came from disk (keep selection by path).
    func modelChanged(reloaded: Bool)
    var selectedItems: [FileItem] { get }
    func select(paths: [String], scroll: Bool)
    /// Selects the row at `index` of the visible list (the filter's best match).
    func selectVisible(_ index: Int)
    /// Selects the last row on screen (⌘↓), inside open folders too.
    func selectLast()
    /// The folder new items, pastes and drops go to. Columns: the deepest folder in focus.
    var targetFolder: String { get }
    /// Inline rename of the single selected item. False when the view has no inline editor.
    func beginInlineRename() -> Bool
    /// Fonts or zoom changed.
    func styleChanged()
    /// The pane became active or inactive: selection colour.
    func activeChanged(_ active: Bool)
    /// Frame of an item on screen, for Quick Look's zoom.
    func screenFrame(of path: String) -> NSRect?
    func expandSelected(_ expand: Bool) -> Bool
    /// Expand: every closed folder in view opens, 1 level per call. Collapse: every folder closes.
    /// False when the view has no tree or nothing changed.
    func expandAll(_ expand: Bool) -> Bool
}

/// Events from a view to its pane.
protocol FileViewDelegate: AnyObject {
    func fileView(open item: FileItem)
    func fileViewSelectionChanged()
    /// A printable key without ⌘/⌃: starts or extends the filter. Returns true when used.
    func fileView(typed text: String) -> Bool
    func fileViewEscape() -> Bool
    func fileViewBackspace() -> Bool
    func fileViewMenu(for items: [FileItem]) -> NSMenu?
    func fileView(drop urls: [URL], into folder: String, copy: Bool) -> Bool
    func fileView(rename item: FileItem, to name: String)
    func fileViewBecameFocused()
    var isActivePane: Bool { get }
    var folderModel: FolderModel { get }
    /// Folder model for a sub-folder (tree list children, column view columns).
    func listing(of folder: String) -> [FileItem]
}

/// Draws the selection in red when the pane is active, grey when not. NicAI accent.
final class FileRowView: NSTableRowView {
    var activePane = true

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let color = activePane ? Theme.accentFill : Theme.selectionInactive
        color.setFill()
        let r = bounds.insetBy(dx: 4, dy: 1)
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
    }

    override var isEmphasized: Bool {
        get { activePane }
        set {}
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && activePane ? .emphasized : .normal
    }
}

/// The name cell: new-today dot, icon, name. Text colour follows the row's selection.
final class NameCellView: NSTableCellView {
    let dot = ColorView(Theme.accent)
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    var indent: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.usesSingleLineMode = true
        addSubview(dot)
        addSubview(icon)
        addSubview(name)
        imageView = icon
        textField = name
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        let iconSize = min(18, (Theme.listSize * 1.3).rounded())
        dot.frame = NSRect(x: 2, y: (h - 6) / 2, width: 6, height: 6)
        icon.frame = NSRect(x: 11, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
        let x = icon.frame.maxX + 6
        let fh = name.intrinsicContentSize.height
        name.frame = NSRect(x: x, y: (h - fh) / 2, width: max(0, bounds.width - x - 2), height: fh)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { name.textColor = backgroundStyle == .emphasized ? .white : Theme.fg }
    }
}

/// A plain text cell for size, dates and kind.
final class TextCellView: NSTableCellView {
    let text = NSTextField(labelWithString: "")
    var alignRight = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.lineBreakMode = .byTruncatingTail
        text.cell?.usesSingleLineMode = true
        addSubview(text)
        textField = text
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let fh = text.intrinsicContentSize.height
        text.frame = NSRect(x: 4, y: (bounds.height - fh) / 2, width: max(0, bounds.width - 8), height: fh)
        text.alignment = alignRight ? .right : .left
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { text.textColor = backgroundStyle == .emphasized ? NSColor.white.withAlphaComponent(0.85) : Theme.muted }
    }
}

/// Column ids and how each one renders an item.
enum ListColumn: String, CaseIterable {
    case name, size, modified, kind, added, created, ext, items

    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Modified"
        case .kind: return "Kind"
        case .added: return "Date Added"
        case .created: return "Created"
        case .ext: return "Extension"
        case .items: return "Items"
        }
    }

    var sortKey: SortKey { SortKey(rawValue: rawValue) ?? .name }
    var alignRight: Bool { self == .size || self == .items }

    func text(_ item: FileItem, size: Int64) -> String {
        switch self {
        case .name: return item.name
        case .size: return item.isFolder || item.kind == .directory ? (size >= 0 ? Format.size(size) : "--") : Format.size(item.size)
        case .modified: return Format.date(item.modified)
        case .kind: return Format.kind(item)
        case .added: return Format.date(item.addedOrCreated)
        case .created: return Format.date(item.created)
        case .ext: return item.ext
        case .items: return item.entryCount >= 0 ? item.entryCount.formatted() : ""
        }
    }
}

/// Text width with the list font, cached per string length bucket is not worth it: NSString sizing is ~1 µs.
func textWidth(_ s: String, font: NSFont) -> CGFloat {
    ceil((s as NSString).size(withAttributes: [.font: font]).width)
}
