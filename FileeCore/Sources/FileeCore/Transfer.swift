import Foundation

/// 1 step on the undo stack. Each case holds what its inverse needs.
public enum UndoRecord: Sendable, Equatable {
    /// Items moved or renamed: (from, to).
    case moved([Pair])
    /// Items created by a copy, a new folder or an extract: undo moves them to the Trash.
    case created([String])
    /// Items moved to the Trash: (original path, path in the Trash).
    case trashed([Pair])
    /// Several records undone as 1 step, last first.
    indirect case group([UndoRecord])

    public struct Pair: Sendable, Equatable {
        public var from: String
        public var to: String
        public init(_ from: String, _ to: String) {
            self.from = from
            self.to = to
        }
    }

    public var title: String {
        switch self {
        case .moved(let p): return p.count == 1 ? "Move" : "Move \(p.count) Items"
        case .created(let p): return p.count == 1 ? "Create" : "Create \(p.count) Items"
        case .trashed(let p): return p.count == 1 ? "Move to Trash" : "Move \(p.count) Items to Trash"
        case .group(let r): return r.first?.title ?? "Change"
        }
    }

    /// Runs the inverse. Returns the record that redoes it.
    public func revert() throws -> UndoRecord {
        switch self {
        case .moved(let pairs):
            var done: [Pair] = []
            for p in pairs.reversed() {
                try FileOps.moveItem(p.to, to: p.from)
                done.append(Pair(p.to, p.from))
            }
            return .moved(done)
        case .created(let paths):
            var done: [Pair] = []
            for p in paths {
                let t = try FileOps.trash(p)
                done.append(Pair(p, t))
            }
            return .trashed(done)
        case .trashed(let pairs):
            var done: [String] = []
            for p in pairs where !p.to.isEmpty {
                try FileOps.moveItem(p.to, to: p.from)
                done.append(p.from)
            }
            return .created(done)
        case .group(let records):
            var redo: [UndoRecord] = []
            for r in records.reversed() { redo.append(try r.revert()) }
            return .group(redo)
        }
    }

    /// The paths to select after the record ran (or after its inverse ran, for the redo record).
    public var resultPaths: [String] {
        switch self {
        case .moved(let p): return p.map(\.to)
        case .created(let p): return p
        case .trashed: return []
        case .group(let r): return r.last?.resultPaths ?? []
        }
    }
}

/// The session's undo and redo stacks, 50 steps.
public final class UndoStack: @unchecked Sendable {
    public private(set) var undo: [UndoRecord] = []
    public private(set) var redo: [UndoRecord] = []
    public let limit = 50
    public init() {}

    public func push(_ r: UndoRecord) {
        undo.append(r)
        if undo.count > limit { undo.removeFirst() }
        redo.removeAll()
    }

    public func popUndo() -> UndoRecord? { undo.popLast() }
    public func popRedo() -> UndoRecord? { redo.popLast() }
    public func pushRedo(_ r: UndoRecord) { redo.append(r) }
    public func pushUndoKeepingRedo(_ r: UndoRecord) { undo.append(r) }
}

/// Copies or moves several items into 1 folder: totals, conflicts, progress, cancel, undo record.
public final class Transfer: @unchecked Sendable {
    public enum Mode: Sendable { case copy, move }

    public let mode: Mode
    public let sources: [String]
    public let destinationFolder: String
    public let cancel = CancelToken()
    /// Called on the transfer's thread. Return the choice for 1 conflicting name. `applyToAll` is the user's tick.
    public var resolveConflict: ((String) -> (ConflictChoice, Bool))?
    public var onProgress: ((OperationProgress) -> Void)?

    public private(set) var errors: [String] = []
    public private(set) var results: [String] = []

    public init(mode: Mode, sources: [String], into folder: String) {
        self.mode = mode
        self.sources = sources
        destinationFolder = folder
    }

    /// Runs to the end, synchronously. Returns the undo record, or nil when nothing changed.
    public func run() -> UndoRecord? {
        let title = mode == .copy ? "Copying" : "Moving"
        var progress = OperationProgress(title: title, currentName: "", itemsDone: 0, itemsTotal: sources.count, bytesDone: 0, bytesTotal: 0)
        // Totals in bytes only when data really moves (copy, or move to another volume).
        let needsBytes = mode == .copy || sources.contains { !FileOps.sameVolume($0, destinationFolder) }
        var sizes: [Int64] = Array(repeating: 0, count: sources.count)
        if needsBytes {
            for (i, s) in sources.enumerated() { sizes[i] = FileOps.measure([s], cancel: cancel).bytes }
            progress.bytesTotal = sizes.reduce(0, +)
        }
        onProgress?(progress)

        var allChoice: ConflictChoice?
        var moved: [UndoRecord.Pair] = []
        var created: [String] = []
        var bytesBefore: Int64 = 0

        for (index, source) in sources.enumerated() {
            if cancel.isCancelled { break }
            let name = (source as NSString).lastPathComponent
            var target = (destinationFolder as NSString).appendingPathComponent(name)
            progress.currentName = name
            onProgress?(progress)

            if FileManager.default.fileExists(atPath: target) || (try? FileManager.default.destinationOfSymbolicLink(atPath: target)) != nil {
                if target == source, mode == .copy {
                    // Copy into its own folder: always a duplicate.
                    target = (destinationFolder as NSString).appendingPathComponent(FileOps.uniqueName(name, in: destinationFolder))
                } else if target == source {
                    progress.itemsDone += 1
                    continue
                } else {
                    var choice = allChoice
                    if choice == nil {
                        let (c, all) = resolveConflict?(name) ?? (.keepBoth, false)
                        choice = c
                        if all { allChoice = c }
                    }
                    switch choice! {
                    case .stop:
                        cancel.cancel()
                        continue
                    case .skip:
                        progress.itemsDone += 1
                        continue
                    case .keepBoth:
                        target = (destinationFolder as NSString).appendingPathComponent(FileOps.uniqueName(name, in: destinationFolder))
                    case .replace:
                        do {
                            try FileOps.trash(target)
                        } catch {
                            errors.append(error.localizedDescription)
                            continue
                        }
                    }
                }
            }

            let base = bytesBefore
            let report: (Int64) -> Void = { [weak self] done in
                var p = progress
                p.bytesDone = base + done
                self?.onProgress?(p)
            }
            do {
                if mode == .copy {
                    try FileOps.copyItem(source, to: target, cancel: cancel, progress: report)
                    created.append(target)
                } else {
                    try FileOps.moveItem(source, to: target, cancel: cancel, progress: report)
                    moved.append(.init(source, target))
                }
                results.append(target)
            } catch OperationError.cancelled {
                break
            } catch {
                errors.append(error.localizedDescription)
            }
            bytesBefore += sizes[index]
            progress.bytesDone = bytesBefore
            progress.itemsDone += 1
            onProgress?(progress)
        }
        if mode == .copy { return created.isEmpty ? nil : .created(created) }
        return moved.isEmpty ? nil : .moved(moved)
    }
}
