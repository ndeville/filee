import AppKit
import FileeCore

/// 1 folder's listing: loads off the main thread, sorts, hides, filters, follows changes on disk.
final class FolderModel {
    private(set) var path: String
    private(set) var items: [FileItem] = []
    /// Sorted, hidden files removed (unless shown), filter applied. What the views draw.
    private(set) var visible: [FileItem] = []
    private(set) var error: String?
    private(set) var loaded = false
    private(set) var loadMilliseconds = 0
    /// Index in `visible` of the best filter match.
    private(set) var bestMatch: Int?

    var sortKey: SortKey = .name
    var ascending = true
    var showHidden = false
    /// The tab's file-type filter. Folders always pass.
    var types: FileTypeFilter = .all {
        didSet {
            guard types != oldValue else { return }
            resort(notify: false)
            onChange?(true)
        }
    }
    var query = "" { didSet { if query != oldValue { refilter() } } }
    /// Folder sizes calculated on request (⌃⌘S), by path.
    var folderSizes: [String: Int64] = [:]

    /// Called on main after every change of `visible`. `reloaded` is true when the content came from disk.
    var onChange: ((_ reloaded: Bool) -> Void)?

    private var watchID: UUID?
    private var generation = 0
    private var reloadWork: DispatchWorkItem?
    static let queue = DispatchQueue(label: "filee.list", qos: .userInitiated, attributes: .concurrent)

    init(path: String) {
        self.path = path
    }

    deinit { FolderWatch.shared.unsubscribe(watchID) }

    var displayPath: String { path.abbreviatingHome }
    var name: String { path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent }

    func startWatching() {
        guard watchID == nil else { return }
        watchID = FolderWatch.shared.subscribe(path) { [weak self] in self?.scheduleReload() }
    }

    func stopWatching() {
        FolderWatch.shared.unsubscribe(watchID)
        watchID = nil
    }

    /// Bursts of disk events (a copy of 1,000 files) reload once.
    func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.load() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Lists the folder in the background. `sync` lists on the calling thread (first paint, QA).
    func load(sync: Bool = false) {
        generation += 1
        let gen = generation
        let p = path
        let work = { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            var result: [FileItem] = []
            var err: String?
            do {
                result = try DirectoryLister.list(p)
            } catch let e as POSIXError {
                err = e.code == .EPERM || e.code == .EACCES
                    ? "Filee has no access to this folder. Grant it in System Settings > Privacy & Security > Files and Folders, or Full Disk Access."
                    : (e.code == .ENOENT ? "This folder no longer exists." : e.localizedDescription)
            } catch {
                err = error.localizedDescription
            }
            let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let apply = {
                guard let self, gen == self.generation else { return }
                self.items = result
                self.error = err
                self.loaded = true
                self.loadMilliseconds = ms
                self.folderSizes = self.folderSizes.filter { k, _ in result.contains { $0.path == k } }
                self.resort(notify: false)
                self.onChange?(true)
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        }
        if sync { work() } else { Self.queue.async(execute: work) }
    }

    func resort(notify: Bool = true) {
        let t = Profile.now
        let shown = showHidden && types == .all ? items : items.filter { (showHidden || !$0.isHidden) && types.matches($0) }
        let r = Self.sortItemsWithKeys(shown, key: sortKey, ascending: ascending, sizes: folderSizes)
        let list = r.items
        sorted = list
        sortedKeys = r.keys
        sortedNames = list.map(\.name)
        Profile.mark("sort \(list.count)", t)
        refilter(notify: notify)
    }

    private var sorted: [FileItem] = []
    private var sortedKeys: [[UInt8]] = []
    private var sortedNames: [String] = []

    private func refilter(notify: Bool = true) {
        let t = Profile.now
        let m = Fuzzy.matches(keys: sortedKeys, names: sortedNames, query: query)
        Profile.mark("fuzzy \(sortedKeys.count)", t)
        visible = m.indices.count == sorted.count ? sorted : m.indices.map { sorted[$0] }
        if let b = m.best, let i = m.indices.firstIndex(of: b) { bestMatch = i } else { bestMatch = nil }
        if notify { onChange?(false) }
    }

    /// Total count before the filter.
    var unfilteredCount: Int { sorted.count }

    func size(of item: FileItem) -> Int64 {
        item.isFolder || item.kind == .directory ? (folderSizes[item.path] ?? -1) : item.size
    }

    /// Sorts with folders first. Name keys are built once (NaturalOrder), never per comparison.
    static func sortItems(_ items: [FileItem], key: SortKey, ascending: Bool, sizes: [String: Int64]) -> [FileItem] {
        sortItemsWithKeys(items, key: key, ascending: ascending, sizes: sizes).items
    }

    /// The sorted items and their name keys (reused by the filter).
    static func sortItemsWithKeys(_ items: [FileItem], key: SortKey, ascending: Bool, sizes: [String: Int64]) -> (items: [FileItem], keys: [[UInt8]]) {
        let keys = items.map { NaturalOrder.key($0.name) }
        let kinds: [String] = key == .kind ? items.map { Format.kind($0) } : []
        var idx = Array(items.indices)
        idx.sort { x, y in
            let a = items[x], b = items[y]
            if a.isFolder != b.isFolder { return a.isFolder }
            var r = 0
            switch key {
            case .name: r = NaturalOrder.compare(keys[x], keys[y])
            case .size:
                let sa = a.isFolder ? (sizes[a.path] ?? -1) : a.size, sb = b.isFolder ? (sizes[b.path] ?? -1) : b.size
                r = sa == sb ? 0 : (sa < sb ? -1 : 1)
            case .modified: r = a.modified == b.modified ? 0 : (a.modified < b.modified ? -1 : 1)
            case .created: r = a.created == b.created ? 0 : (a.created < b.created ? -1 : 1)
            case .added: r = a.addedOrCreated == b.addedOrCreated ? 0 : (a.addedOrCreated < b.addedOrCreated ? -1 : 1)
            case .kind: r = kinds[x] == kinds[y] ? 0 : (kinds[x] < kinds[y] ? -1 : 1)
            case .ext: r = a.ext == b.ext ? 0 : (a.ext < b.ext ? -1 : 1)
            case .items: r = a.entryCount == b.entryCount ? 0 : (a.entryCount < b.entryCount ? -1 : 1)
            }
            if r == 0 { return NaturalOrder.compare(keys[x], keys[y]) < 0 }
            return ascending ? r < 0 : r > 0
        }
        return (idx.map { items[$0] }, idx.map { keys[$0] })
    }
}

/// 1 tab: a folder, its history and its view.
final class TabModel {
    private(set) var folder: FolderModel
    var back: [String] = []
    var forward: [String] = []
    var view: ViewMode
    /// The file-type filter: it stays with the tab from folder to folder.
    var types: FileTypeFilter = .all
    /// Paths selected when the tab was left, restored on return.
    var savedSelection: [String] = []

    init(path: String, view: ViewMode) {
        folder = FolderModel(path: path)
        self.view = view
    }

    var path: String { folder.path }

    /// Replaces the folder. `record` pushes the old one on the back stack.
    func go(to path: String, record: Bool = true) -> FolderModel {
        if record, path != folder.path {
            back.append(folder.path)
            if back.count > 100 { back.removeFirst() }
            forward.removeAll()
        }
        folder.stopWatching()
        folder = FolderModel(path: path)
        return folder
    }
}
