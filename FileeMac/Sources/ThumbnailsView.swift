import AppKit
import FileeCore
import QuickLookThumbnailing

/// Thumbnails, made on demand for visible items only, cached up to 64 MB.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private var inFlight = Set<String>()

    init() {
        cache.totalCostLimit = 40 * 1024 * 1024
    }

    func image(for item: FileItem, size: CGFloat, scale: CGFloat, done: @escaping (NSImage) -> Void) -> NSImage? {
        let key = "\(item.path)|\(Int(size))|\(Int(item.modified))" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard !inFlight.contains(key as String) else { return nil }
        inFlight.insert(key as String)
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            DispatchQueue.main.async {
                self?.inFlight.remove(key as String)
                guard let cg = rep?.cgImage else { return }
                let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
                self?.cache.setObject(img, forKey: key, cost: cg.bytesPerRow * cg.height)
                done(img)
            }
        }
        return nil
    }

    func clear() { cache.removeAllObjects() }
}

final class ThumbItem: NSCollectionViewItem {
    let thumb = NSImageView()
    let name = NSTextField(labelWithString: "")
    let dot = ColorView(Theme.accent)
    var path = ""
    var activePane = true

    override func loadView() {
        let v = FlippedView()
        v.wantsLayer = true
        v.layer?.cornerRadius = Theme.radius(6)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 2
        name.cell?.wraps = true
        name.font = Theme.listFont(size: max(10, Theme.listSize - 1))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        v.addSubview(thumb)
        v.addSubview(name)
        v.addSubview(dot)
        view = v
        imageView = thumb
        textField = name
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        let labelH: CGFloat = 34
        thumb.frame = NSRect(x: 6, y: 6, width: b.width - 12, height: b.height - labelH - 10)
        name.frame = NSRect(x: 4, y: b.height - labelH, width: b.width - 8, height: labelH - 2)
        dot.frame = NSRect(x: 8, y: 8, width: 8, height: 8)
    }

    override var isSelected: Bool { didSet { updateSelection() } }

    func updateSelection() {
        view.layer?.cornerRadius = Theme.radius(6)
        view.layer?.backgroundColor = isSelected ? (activePane ? Theme.accentFill : Theme.selectionInactive).cgColor : NSColor.clear.cgColor
        name.textColor = isSelected && activePane ? .white : Theme.fg
    }
}

final class ThumbCollectionView: NSCollectionView {
    weak var fileDelegate: FileViewDelegate?
    weak var owner: ThumbnailsView?

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
        if let ip = indexPathForItem(at: p), !selectionIndexPaths.contains(ip) {
            selectionIndexPaths = [ip]
            owner?.selectionChanged()
        }
        window?.makeFirstResponder(self)
        return fileDelegate?.fileViewMenu(for: indexPathForItem(at: p) == nil ? [] : owner?.selectedItems ?? [])
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)), let it = owner?.item(at: ip.item) {
            fileDelegate?.fileView(open: it)
        }
    }
}

/// The thumbnail grid (⌘3). ⌘+ and ⌘- change the size, per folder.
final class ThumbnailsView: NSObject, FileView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let scroll = NSScrollView()
    let grid = ThumbCollectionView()
    let layout = NSCollectionViewFlowLayout()
    weak var delegate: FileViewDelegate?
    private var items: [FileItem] = []
    private var dayStart = startOfDay()
    private var activePane = true
    private let itemID = NSUserInterfaceItemIdentifier("thumb")

    init(delegate: FileViewDelegate) {
        self.delegate = delegate
        super.init()
        grid.fileDelegate = delegate
        grid.owner = self
        grid.collectionViewLayout = layout
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [Theme.bg]
        grid.register(ThumbItem.self, forItemWithIdentifier: itemID)
        grid.registerForDraggedTypes([.fileURL])
        grid.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        updateSize()
    }

    var root: NSView { scroll }
    var focusTarget: NSView { grid }

    private var thumbSize: CGFloat {
        let path = delegate?.folderModel.path ?? ""
        return CGFloat(AppDelegate.shared.folderView(for: path)?.thumbnailSize ?? Theme.settings.thumbnailSize) * Theme.zoom
    }

    private func updateSize() {
        let s = thumbSize
        layout.itemSize = NSSize(width: s + 12, height: s + 44)
    }

    func item(at i: Int) -> FileItem? { i >= 0 && i < items.count ? items[i] : nil }

    private var shownFolder = ""

    func modelChanged(reloaded: Bool) {
        guard let model = delegate?.folderModel else { return }
        // Thumbnails of the folder we left are dropped: only the folder on screen keeps memory.
        if model.path != shownFolder {
            if !shownFolder.isEmpty { ThumbnailCache.shared.clear() }
            shownFolder = model.path
        }
        if reloaded { dayStart = startOfDay() }
        let keep = selectedItems.map(\.path)
        items = model.visible
        updateSize()
        grid.reloadData()
        if !model.query.isEmpty, let best = model.bestMatch {
            selectVisible(best)
        } else if !keep.isEmpty {
            select(paths: keep, scroll: false)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: itemID, for: indexPath) as! ThumbItem
        let it = items[indexPath.item]
        cell.path = it.path
        cell.name.stringValue = it.name
        cell.name.font = Theme.listFont(bold: it.isFolder, size: max(10, Theme.listSize - 1))
        cell.dot.isHidden = !(Theme.settings.newTodayMarker && it.isNew(since: dayStart))
        cell.activePane = activePane
        cell.updateSelection()
        let size = thumbSize
        if it.isFolder || it.kind == .other {
            cell.thumb.image = Icons.icon(for: it)
        } else {
            let scale = collectionView.window?.backingScaleFactor ?? 2
            if let img = ThumbnailCache.shared.image(for: it, size: size, scale: scale, done: { [weak cell] img in
                if cell?.path == it.path { cell?.thumb.image = img }
            }) {
                cell.thumb.image = img
            } else {
                cell.thumb.image = Icons.icon(for: it)
            }
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }

    func selectionChanged() { delegate?.fileViewSelectionChanged() }

    var selectedItems: [FileItem] {
        grid.selectionIndexPaths.map(\.item).sorted().compactMap { item(at: $0) }
    }

    func select(paths: [String], scroll doScroll: Bool) {
        let set = Set(paths)
        let ips = Set(items.indices.filter { set.contains(items[$0].path) }.map { IndexPath(item: $0, section: 0) })
        grid.selectionIndexPaths = ips
        if doScroll, let first = ips.min() { grid.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge) }
        selectionChanged()
    }

    func selectVisible(_ index: Int) {
        guard index >= 0, index < items.count else { return }
        let ip = IndexPath(item: index, section: 0)
        grid.selectionIndexPaths = [ip]
        grid.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        selectionChanged()
    }

    func selectLast() { selectVisible(items.count - 1) }

    var targetFolder: String { delegate?.folderModel.path ?? NSHomeDirectory() }
    func beginInlineRename() -> Bool { false }
    func expandSelected(_ expand: Bool) -> Bool { false }
    func expandAll(_ expand: Bool) -> Bool { false }

    func styleChanged() {
        updateSize()
        grid.reloadData()
    }

    func activeChanged(_ active: Bool) {
        activePane = active
        for case let cell as ThumbItem in grid.visibleItems() {
            cell.activePane = active
            cell.updateSelection()
        }
    }

    /// ⌘+ / ⌘- in this view: thumbnail size for this folder.
    func resize(by step: Int) {
        guard let path = delegate?.folderModel.path else { return }
        let current = AppDelegate.shared.folderView(for: path)?.thumbnailSize ?? Theme.settings.thumbnailSize
        let next = step == 0 ? Theme.settings.thumbnailSize : min(384, max(64, current * (step > 0 ? 1.25 : 0.8)))
        AppDelegate.shared.rememberThumbnailSize(for: path, next)
        styleChanged()
    }

    func screenFrame(of path: String) -> NSRect? {
        guard let i = items.firstIndex(where: { $0.path == path }), let cell = grid.item(at: IndexPath(item: i, section: 0)) as? ThumbItem,
              let window = grid.window else { return nil }
        return window.convertToScreen(cell.thumb.convert(cell.thumb.bounds, to: nil))
    }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        item(at: indexPath.item)?.url as NSURL?
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        let ip = proposedIndexPath.pointee as IndexPath
        var folder = targetFolder
        if dropOperation.pointee == .on, let it = item(at: ip.item), it.isFolder { folder = it.path } else { dropOperation.pointee = .before }
        if urls.contains(where: { $0.path == folder }) { return [] }
        if folder == targetFolder, urls.allSatisfy({ $0.deletingLastPathComponent().path == folder }) { return [] }
        return dragOperation(draggingInfo, into: folder, urls: urls)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        var folder = targetFolder
        if dropOperation == .on, let it = item(at: indexPath.item), it.isFolder { folder = it.path }
        return delegate?.fileView(drop: urls, into: folder, copy: dragOperation(draggingInfo, into: folder, urls: urls) == .copy) ?? false
    }
}
