import AppKit
import FileeCore

/// The folder path above a pane's files, from the home folder (or the volume) down. A click on a folder goes there,
/// a drop on it copies or moves into it (Finder's rules), a click on the current folder or the free space opens the path
/// for typing. 1 view that draws its own text: no subviews, no disk access, a new layout only when the path or the
/// width changes.
final class PathCrumbs: NSView {
    struct Crumb {
        let title: String
        /// Nil for "…": the folders that don't fit.
        let path: String?
        var symbol: String? = nil
        var rect = NSRect.zero
    }

    var onGo: ((String) -> Void)?
    var onEdit: (() -> Void)?
    var onDrop: ((_ urls: [URL], _ folder: String, _ copy: Bool) -> Bool)?

    private(set) var path = ""
    private var all: [Crumb] = []
    private(set) var shown: [Crumb] = []
    /// The folders behind "…".
    private var folded: [Crumb] = []
    private var active = true
    private var arrangedWidth: CGFloat = -1
    private var hover: Int?
    private var dropIndex: Int?
    private var dragged: [URL] = []

    private let font = Theme.ui(13)
    private let currentFont = Theme.ui(13, weight: .bold)
    private let pad: CGFloat = 5
    private let separatorWidth: CGFloat = 14
    private let iconWidth: CGFloat = 15
    private var icons: [String: NSImage] = [:]

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(path: String, active: Bool) {
        if path != self.path {
            self.path = path
            all = Self.crumbs(for: path)
            arrangedWidth = -1
            hover = nil
            needsLayout = true
        }
        self.active = active
        needsDisplay = true
    }

    /// Root first: the home folder, a volume under /Volumes, or the startup disk.
    static func crumbs(for path: String) -> [Crumb] {
        let home = NSHomeDirectory()
        var out: [Crumb]
        var base: String
        if path == home || path.hasPrefix(home + "/") {
            out = [Crumb(title: (home as NSString).lastPathComponent, path: home, symbol: "house")]
            base = home
        } else if path.hasPrefix("/Volumes/"), let name = path.dropFirst(9).split(separator: "/").first {
            base = "/Volumes/" + name
            out = [Crumb(title: String(name), path: base, symbol: "externaldrive")]
        } else {
            out = [Crumb(title: "Macintosh HD", path: "/", symbol: "internaldrive")]
            base = "/"
        }
        for name in path.dropFirst(base.count).split(separator: "/") {
            base = (base as NSString).appendingPathComponent(String(name))
            out.append(Crumb(title: String(name), path: base))
        }
        return out
    }

    // MARK: Layout and drawing

    override func layout() {
        super.layout()
        guard bounds.width != arrangedWidth else { return }
        arrange()
    }

    private func width(_ c: Crumb, current: Bool) -> CGFloat {
        textWidth(c.title, font: current ? currentFont : font) + 2 * pad + (c.symbol == nil ? 0 : iconWidth + 3)
    }

    /// Folds the folders after the root into "…", from the top down, until the rest fits.
    private func arrange() {
        let t = Profile.now
        arrangedWidth = bounds.width
        let widths = all.enumerated().map { width($0.element, current: $0.offset == all.count - 1) }
        let ellipsis = Crumb(title: "…", path: nil)
        let ellipsisW = width(ellipsis, current: false)
        func total(_ fold: Int) -> CGFloat {
            let kept = widths.enumerated().filter { $0.offset == 0 || $0.offset > fold }.map(\.element)
            return kept.reduce(0, +) + (fold > 0 ? ellipsisW : 0) + separatorWidth * CGFloat(kept.count - (fold > 0 ? 0 : 1))
        }
        var fold = 0
        while fold < all.count - 2, total(fold) > bounds.width { fold += 1 }
        folded = fold > 0 ? Array(all[1...fold]) : []
        shown = fold > 0 ? [all[0], ellipsis] + all[(fold + 1)...] : all
        var x: CGFloat = 0
        for i in shown.indices {
            let current = i == shown.count - 1
            let w = current ? max(30, min(width(shown[i], current: true), bounds.width - x)) : width(shown[i], current: false)
            shown[i].rect = NSRect(x: x, y: 0, width: w, height: bounds.height)
            x += w + separatorWidth
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        Profile.mark("path crumbs", t)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        icons = [:]
        needsDisplay = true
    }

    private func icon(_ name: String) -> NSImage? {
        if let i = icons[name] { return i }
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [Theme.muted]))
        let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        icons[name] = i
        return i
    }

    override func draw(_ dirtyRect: NSRect) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let lineH = ceil(font.ascender - font.descender)
        for (i, c) in shown.enumerated() {
            let current = i == shown.count - 1
            let box = c.rect.insetBy(dx: 0, dy: 1)
            if i == dropIndex {
                Theme.accentSoft.setFill()
                Theme.accent.setStroke()
                let p = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
                p.fill()
                p.stroke()
            } else if i == hover, !current {
                Theme.surface2.setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
            var x = c.rect.minX + pad
            if let s = c.symbol, let img = icon(s) {
                let size = img.size
                img.draw(in: NSRect(x: x + (iconWidth - size.width) / 2, y: ((bounds.height - size.height) / 2).rounded(),
                                    width: size.width, height: size.height))
                x += iconWidth + 3
            }
            let color = current ? (active ? Theme.fg : Theme.muted) : (i == hover || i == dropIndex ? Theme.fg : Theme.muted)
            let text = NSAttributedString(string: c.title, attributes: [.font: current ? currentFont : font, .foregroundColor: color, .paragraphStyle: para])
            text.draw(with: NSRect(x: x, y: ((bounds.height - lineH) / 2).rounded(), width: max(0, c.rect.maxX - pad - x), height: lineH),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if !current {
                let sep = NSAttributedString(string: "›", attributes: [.font: font, .foregroundColor: Theme.muted])
                let sw = sep.size().width
                sep.draw(at: NSPoint(x: c.rect.maxX + (separatorWidth - sw) / 2, y: ((bounds.height - lineH) / 2).rounded()))
            }
        }
    }

    // MARK: Mouse

    private func index(at point: NSPoint) -> Int? {
        shown.firstIndex { $0.rect.contains(point) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        guard i != hover else { return }
        hover = i
        if let i, let p = shown[i].path {
            toolTip = i == shown.count - 1 ? "\(p)\nClick to type or paste a path to go to." : "\(p)\nClick to go there. Drop files here to move or copy them (⌥ copies)."
        } else {
            toolTip = i == nil ? "Click to type or paste a path to go to." : folded.compactMap(\.path).last
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        click(at: convert(event.locationInWindow, from: nil))
    }

    private func click(at point: NSPoint) {
        guard let i = index(at: point), i < shown.count - 1 else {
            onEdit?()
            return
        }
        guard let p = shown[i].path else {
            showFolded(below: shown[i].rect)
            return
        }
        onGo?(p)
    }

    private func showFolded(below rect: NSRect) {
        let menu = NSMenu()
        for c in folded {
            let item = NSMenuItem(title: c.title, action: #selector(goFolded(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.path
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: self)
    }

    @objc private func goFolded(_ item: NSMenuItem) {
        if let p = item.representedObject as? String { onGo?(p) }
    }

    override func resetCursorRects() {
        guard let last = shown.last else { return }
        for c in shown.dropLast() { addCursorRect(c.rect, cursor: .pointingHand) }
        addCursorRect(NSRect(x: last.rect.minX, y: 0, width: max(0, bounds.width - last.rect.minX), height: bounds.height), cursor: .iBeam)
    }

    // MARK: Drop

    /// False for a drop that would do nothing or harm: onto an item itself, into the folder that holds it, into its own subfolder.
    static func canDrop(_ urls: [URL], into folder: String) -> Bool {
        !urls.isEmpty && !urls.contains { u in
            let p = u.path
            return p == folder || (p as NSString).deletingLastPathComponent == folder || folder.hasPrefix(p + "/")
        }
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        dragged = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return draggingUpdated(info)
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        var op: NSDragOperation = []
        let i = index(at: convert(info.draggingLocation, from: nil))
        if let i, let folder = shown[i].path, Self.canDrop(dragged, into: folder) { op = dragOperation(info, into: folder, urls: dragged) }
        let target = op.isEmpty ? nil : i
        if target != dropIndex {
            dropIndex = target
            needsDisplay = true
        }
        return op
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndex = nil
        needsDisplay = true
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        defer {
            dropIndex = nil
            dragged = []
            needsDisplay = true
        }
        guard let i = dropIndex, let folder = shown[i].path else { return false }
        return onDrop?(dragged, folder, dragOperation(info, into: folder, urls: dragged) == .copy) ?? false
    }

    // MARK: QA

    var titles: [String] { shown.map(\.title) }

    /// A click on the crumb with this title, or on the free space after the last one ("").
    func qaClick(_ title: String) -> Bool {
        layoutSubtreeIfNeeded()
        if title.isEmpty {
            click(at: NSPoint(x: bounds.maxX - 2, y: bounds.midY))
            return true
        }
        guard let c = shown.first(where: { $0.title == title }) else { return false }
        click(at: NSPoint(x: c.rect.midX, y: c.rect.midY))
        return true
    }

    /// What a drop of these files on the crumb with this title does, without a drag session.
    func qaDrop(_ paths: [String], on title: String, copy: Bool) -> Bool {
        layoutSubtreeIfNeeded()
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard let folder = shown.first(where: { $0.title == title })?.path, Self.canDrop(urls, into: folder) else { return false }
        return onDrop?(urls, folder, copy) ?? false
    }
}
