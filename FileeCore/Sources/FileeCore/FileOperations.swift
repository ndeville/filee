import Darwin
import Foundation

/// Progress of a running operation. Sent on the operation's queue; the app hops to main.
public struct OperationProgress: Sendable {
    public var title: String
    public var currentName: String
    public var itemsDone: Int
    public var itemsTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64

    public init(title: String, currentName: String, itemsDone: Int, itemsTotal: Int, bytesDone: Int64, bytesTotal: Int64) {
        self.title = title
        self.currentName = currentName
        self.itemsDone = itemsDone
        self.itemsTotal = itemsTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }

    public var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        return itemsTotal > 0 ? Double(itemsDone) / Double(itemsTotal) : 0
    }
}

/// What to do when the target name exists.
public enum ConflictChoice: Sendable {
    case replace, keepBoth, skip, stop
}

public enum OperationError: Error, LocalizedError {
    case cancelled
    case intoItself(String)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled"
        case .intoItself(let name): return "Can't copy \(name) into itself"
        case .failed(let name, let why): return "\(name): \(why)"
        }
    }
}

/// A token the UI flips to stop an operation between files (and inside a big copy).
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    public func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// File system changes, each returning what undo needs. Every function is synchronous: callers run them
/// off the main thread. Paths are absolute.
public enum FileOps {
    static let fm = FileManager.default

    // MARK: Names

    /// "name 2.ext", "name 3.ext"... the first one free in `folder`. Folders: "name 2".
    public static func uniqueName(_ name: String, in folder: String, taken: Set<String> = []) -> String {
        func exists(_ n: String) -> Bool { taken.contains(n) || fm.fileExists(atPath: (folder as NSString).appendingPathComponent(n)) }
        if !exists(name) { return name }
        let ns = name as NSString
        var ext = ns.pathExtension
        var stem = ns.deletingPathExtension
        if stem.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".") {
            stem = name
            ext = ""
        }
        // "report 2" -> "report 3", not "report 2 2".
        var n = 2
        if let space = stem.lastIndex(of: " "), let k = Int(stem[stem.index(after: space)...]), k >= 2 {
            stem = String(stem[..<space])
            n = k + 1
        }
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    public static func sameVolume(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        guard lstat(a, &sa) == 0 else { return false }
        // The destination may not exist yet: use its folder.
        var target = b
        while lstat(target, &sb) != 0 {
            let up = (target as NSString).deletingLastPathComponent
            if up == target { return false }
            target = up
        }
        return sa.st_dev == sb.st_dev
    }

    // MARK: Size

    /// Bytes and files under the given paths (folders walked). Used for progress totals.
    public static func measure(_ paths: [String], cancel: CancelToken? = nil) -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        for p in paths {
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                let t = DirectoryLister.totalSize(p) { cancel?.isCancelled ?? false }
                bytes += t.bytes
                files += t.files
            } else {
                bytes += Int64(st.st_size)
                files += 1
            }
        }
        return (bytes, files)
    }

    // MARK: Copy

    /// Copies 1 item (file or folder) to `destination` (full target path). Clones on APFS, else copies
    /// with progress. On failure or cancel, the partial target is removed.
    public static func copyItem(_ source: String, to destination: String, cancel: CancelToken? = nil,
                                progress: ((Int64) -> Void)? = nil) throws {
        if destination == source || destination.hasPrefix(source + "/") {
            throw OperationError.intoItself((source as NSString).lastPathComponent)
        }
        let box = CopyContext(cancel: cancel, progress: progress)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctx)
        let callback: copyfile_callback_t = { what, stage, state, _, _, ctx in
            guard let ctx else { return COPYFILE_CONTINUE }
            let box = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
            if box.cancel?.isCancelled == true { return COPYFILE_QUIT }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                box.report(file: Int64(copied))
            } else if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH {
                box.fileDone()
            } else if what == COPYFILE_RECURSE_ERROR || (stage == COPYFILE_ERR && what != COPYFILE_RECURSE_DIR_CLEANUP) {
                return COPYFILE_QUIT
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))

        var isDir: ObjCBool = false
        fm.fileExists(atPath: source, isDirectory: &isDir)
        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)
        if isDir.boolValue { flags |= copyfile_flags_t(COPYFILE_RECURSIVE) }
        // Same volume: try a clone first (instant on APFS). copyfile falls back to a copy when it can't.
        if sameVolume(source, (destination as NSString).deletingLastPathComponent) { flags |= copyfile_flags_t(COPYFILE_CLONE) }

        let rc = copyfile(source, destination, state, flags)
        let err = errno
        if rc != 0 || box.cancel?.isCancelled == true {
            try? fm.removeItem(atPath: destination)
            if box.cancel?.isCancelled == true { throw OperationError.cancelled }
            throw OperationError.failed((source as NSString).lastPathComponent, String(cString: strerror(err)))
        }
        box.finish()
    }

    private final class CopyContext {
        let cancel: CancelToken?
        let progress: ((Int64) -> Void)?
        private var finished: Int64 = 0
        private var current: Int64 = 0
        init(cancel: CancelToken?, progress: ((Int64) -> Void)?) {
            self.cancel = cancel
            self.progress = progress
        }

        func report(file copied: Int64) {
            current = copied
            progress?(finished + current)
        }

        func fileDone() {
            finished += current
            current = 0
        }

        func finish() { progress?(finished + current) }
    }

    // MARK: Move, rename, trash, create

    /// Moves 1 item to `destination` (full target path). Same volume: a rename. Else copy, then delete.
    public static func moveItem(_ source: String, to destination: String, cancel: CancelToken? = nil,
                                progress: ((Int64) -> Void)? = nil) throws {
        if destination == source { return }
        if destination.hasPrefix(source + "/") { throw OperationError.intoItself((source as NSString).lastPathComponent) }
        if sameVolume(source, (destination as NSString).deletingLastPathComponent) {
            do {
                try fm.moveItem(atPath: source, toPath: destination)
            } catch {
                throw OperationError.failed((source as NSString).lastPathComponent, error.localizedDescription)
            }
            return
        }
        try copyItem(source, to: destination, cancel: cancel, progress: progress)
        do {
            try fm.removeItem(atPath: source)
        } catch {
            throw OperationError.failed((source as NSString).lastPathComponent, "copied, but the original couldn't be removed: \(error.localizedDescription)")
        }
    }

    /// Renames in place. A change of case only ("abc" -> "ABC") works on case-insensitive volumes.
    public static func rename(_ path: String, to newName: String) throws -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let target = (folder as NSString).appendingPathComponent(newName)
        if target == path { return path }
        if fm.fileExists(atPath: target), target.lowercased() != path.lowercased() {
            throw OperationError.failed(newName, "an item with this name already exists")
        }
        if Darwin.rename(path, target) != 0 {
            throw OperationError.failed((path as NSString).lastPathComponent, String(cString: strerror(errno)))
        }
        return target
    }

    /// Moves to the Trash. Returns the item's path in the Trash, for undo.
    @discardableResult
    public static func trash(_ path: String) throws -> String {
        var result: NSURL?
        do {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
        } catch {
            throw OperationError.failed((path as NSString).lastPathComponent, error.localizedDescription)
        }
        return result?.path ?? ""
    }

    public static func newFolder(in folder: String, name: String = "untitled folder") throws -> String {
        let n = uniqueName(name, in: folder)
        let path = (folder as NSString).appendingPathComponent(n)
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
        } catch {
            throw OperationError.failed(n, error.localizedDescription)
        }
        return path
    }

    public static func newFile(in folder: String, name: String = "untitled.txt") throws -> String {
        let n = uniqueName(name, in: folder)
        let path = (folder as NSString).appendingPathComponent(n)
        guard fm.createFile(atPath: path, contents: Data()) else { throw OperationError.failed(n, "couldn't create the file") }
        return path
    }
}
